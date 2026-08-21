import SwiftUI

/// C.A.L as a drawn orb — not the meditating bear.
///
/// Every place the character appears goes through this view, so replacing how he
/// looks is one edit. Voice screens pass `activity` so the ring follows listening
/// and speaking. Everywhere else stays idle.
///
/// ## Two things this exists to get right
///
/// **VoiceOver.** The bubble avatar repeats once per assistant message, so a
/// labelled one would have a screen reader announce the character forty times in
/// a scrolled thread. Decorative is therefore the *default*, and a label is
/// opt-in for the few places the picture is the content rather than the decoration.
///
/// **Dynamic Type.** A 44pt orb beside body text must grow with it or it turns
/// into a speck at AX5. A 180pt hero must *not*, or it pushes the screen it
/// introduces off the bottom. Scaling is a property of the size, not a blanket
/// rule — and the scaling sizes are capped.
public struct CalAvatar: View {

    /// The sizes actually used, rather than a free `CGFloat`.
    public enum Size: Sendable {
        /// Beside a chat message. Scales with text.
        case bubble
        /// A row or an inline mention. Scales with text.
        case inline
        /// The centrepiece of a card or an empty state. Fixed.
        case card
        /// The top of a screen. Fixed.
        case hero

        var points: CGFloat {
            switch self {
            case .bubble: 44
            case .inline: 44
            case .card: 120
            case .hero: 180
            }
        }

        var scales: Bool {
            switch self {
            case .bubble, .inline: true
            case .card, .hero: false
            }
        }

        /// Growth ceiling for the scaling sizes, as a multiple of the base.
        var scaleCeiling: CGFloat { 1.6 }

        /// Card and hero may bob. Bubble and inline stay planted so chat rows
        /// do not bounce.
        var floats: Bool {
            switch self {
            case .card, .hero: true
            case .bubble, .inline: false
            }
        }

        /// Padding around the drawn orb so halo, ring pulse, and bob are not
        /// clipped. Matches the frame inset applied in `body`.
        var layoutInset: CGFloat {
            points * 0.22 + Motion.bobAmplitude
        }
    }

    /// Decorative wash behind the orb. Gold is ring-only — it fails even the
    /// non-text contrast threshold, so it must never carry a shape that means
    /// something (`Brand.swift`).
    public enum Halo: Sendable, Equatable {
        case none
        case sage
        case sageAndGold
    }

    /// How the session sounds. Drives float, ring pulse, and speaking vibrate.
    /// Idle is the default so call sites that are not the live companion do not
    /// have to opt in.
    public enum Activity: Sendable, Equatable {
        case idle
        case listening
        case thinking
        case speaking
    }

    private let size: Size
    private let halo: Halo
    private let activity: Activity
    private let label: String?

    @ScaledMetric(wrappedValue: 0, relativeTo: .body) private var scaled: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// - Parameters:
    ///   - size: One of the four named sizes.
    ///   - halo: Decorative wash. Defaults to none.
    ///   - activity: Session tone. Defaults to idle.
    ///   - label: `nil` — the default — hides the orb from VoiceOver as decoration.
    public init(
        _ size: Size,
        halo: Halo = .none,
        activity: Activity = .idle,
        label: String? = nil
    ) {
        self.size = size
        self.halo = halo
        self.activity = activity
        self.label = label
        self._scaled = ScaledMetric(wrappedValue: size.points, relativeTo: .body)
    }

    private var side: CGFloat {
        guard size.scales else { return size.points }
        return min(scaled, size.points * size.scaleCeiling)
    }

    /// Extra room so halo, ring pulse, and bob are not clipped by the parent.
    private var layoutInset: CGFloat { size.layoutInset }

    public var body: some View {
        let paused = reduceMotion || !needsTimeline
        TimelineView(.animation(paused: paused)) { context in
            orb(at: context.date.timeIntervalSinceReferenceDate)
        }
        .frame(width: side, height: side)
        .frame(width: side + layoutInset * 2, height: side + layoutInset * 2)
        .accessibilityElement()
        .accessibilityLabel(label ?? "")
        .accessibilityHidden(label == nil)
        .accessibilityValue(activity.accessibilityValue)
    }

    private var needsTimeline: Bool {
        if size.floats { return true }
        switch activity {
        case .idle: return false
        case .listening, .thinking, .speaking: return true
        }
    }

    @ViewBuilder
    private func orb(at t: TimeInterval) -> some View {
        let motion = reduceMotion ? Motion.still : Motion.live(activity: activity, floats: size.floats, t: t)
        ZStack {
            if halo != .none {
                Circle()
                    .fill(Brand.sage.opacity(0.12))
                    .scaleEffect(1.12)
                if halo == .sageAndGold {
                    Circle()
                        .fill(Brand.gold.opacity(0.16))
                        .scaleEffect(1.22)
                }
            }

            if activity == .listening, !reduceMotion {
                Circle()
                    .strokeBorder(Brand.sageInk.opacity(0.35), lineWidth: ringWidth * 0.7)
                    .scaleEffect(motion.outerRingScale)
                    .opacity(motion.outerRingOpacity)
            }

            Circle()
                .strokeBorder(ringColor, lineWidth: ringWidth)
                .scaleEffect(motion.ringScale)
                .opacity(motion.ringOpacity)

            Circle()
                .fill(orbFill)
                .scaleEffect(motion.orbScale)
                .overlay {
                    Circle()
                        .fill(Color.white.opacity(0.22))
                        .frame(width: side * 0.22, height: side * 0.22)
                        .offset(x: -side * 0.12, y: -side * 0.14)
                        .blur(radius: max(0.5, side * 0.02))
                }
                .padding(side * 0.14)
        }
        .offset(x: motion.x, y: motion.y)
    }

    private var orbFill: RadialGradient {
        RadialGradient(
            colors: [
                Brand.gold.opacity(0.55),
                Brand.sage.opacity(0.92),
                Brand.orbCore,
            ],
            center: UnitPoint(x: 0.38, y: 0.32),
            startRadius: 0,
            endRadius: side * 0.42
        )
    }

    private var ringColor: Color {
        switch activity {
        case .speaking: Brand.gold
        case .listening, .thinking: Brand.gold.opacity(0.9)
        case .idle:
            switch halo {
            case .sageAndGold: Brand.gold
            case .sage: Brand.gold.opacity(0.85)
            case .none: Brand.gold.opacity(0.7)
            }
        }
    }

    private var ringWidth: CGFloat {
        max(1.5, side / 28)
    }
}

private struct Motion {
    var x: CGFloat
    var y: CGFloat
    var ringScale: CGFloat
    var ringOpacity: Double
    var orbScale: CGFloat
    var outerRingScale: CGFloat
    var outerRingOpacity: Double

    static let bobAmplitude: CGFloat = 7

    static let still = Motion(
        x: 0, y: 0,
        ringScale: 1, ringOpacity: 0.7,
        orbScale: 1,
        outerRingScale: 1, outerRingOpacity: 0
    )

    static func live(activity: CalAvatar.Activity, floats: Bool, t: TimeInterval) -> Motion {
        let bob: CGFloat = floats ? CGFloat(sin(t * 1.2)) * bobAmplitude : 0
        switch activity {
        case .idle:
            let breath = 1 + 0.045 * CGFloat(sin(t * 0.85))
            return Motion(
                x: 0, y: bob,
                ringScale: breath, ringOpacity: 0.5 + 0.12 * Double(sin(t * 0.85)),
                orbScale: breath,
                outerRingScale: 1, outerRingOpacity: 0
            )
        case .listening:
            let pulse = 1 + 0.12 * CGFloat(sin(t * 1.9))
            let outer = 1.08 + 0.18 * CGFloat((sin(t * 1.4) + 1) / 2)
            return Motion(
                x: 0, y: bob,
                ringScale: pulse, ringOpacity: 0.8,
                orbScale: 1 + 0.03 * CGFloat(sin(t * 1.9)),
                outerRingScale: outer,
                outerRingOpacity: 0.45 * (1 - Double((sin(t * 1.4) + 1) / 2))
            )
        case .thinking:
            let pulse = 1 + 0.05 * CGFloat(sin(t * 0.95))
            return Motion(
                x: 0, y: bob * 0.5,
                ringScale: pulse, ringOpacity: 0.55,
                orbScale: 1,
                outerRingScale: 1, outerRingOpacity: 0
            )
        case .speaking:
            let pulse = 1 + 0.16 * CGFloat(sin(t * 6.2))
            let vx = CGFloat(sin(t * 27)) * 2.2
            let vy = CGFloat(cos(t * 31)) * 1.8 + bob * 0.3
            return Motion(
                x: vx, y: vy,
                ringScale: pulse, ringOpacity: 0.95,
                orbScale: 1 + 0.04 * CGFloat(sin(t * 6.2)),
                outerRingScale: 1, outerRingOpacity: 0
            )
        }
    }
}

extension CalAvatar.Activity {
    var accessibilityValue: String {
        switch self {
        case .idle: ""
        case .listening: "Listening"
        case .thinking: "Thinking"
        case .speaking: "Speaking"
        }
    }
}

/// C.A.L as a background wash, rather than as an element.
///
/// Separate from `CalAvatar` because it is not an avatar: it has no size, no
/// activity, and nothing to announce. It is texture, and it is bound by one rule
/// — **text drawn over it must not get harder to read**. Opacity stays low so a
/// contrast pairing measured against the field still holds.
public struct CalWatermark: View {
    private let opacity: Double

    public init(opacity: Double = 0.06) {
        self.opacity = opacity
    }

    public var body: some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [
                        Brand.sage.opacity(opacity * 4),
                        Brand.sage.opacity(opacity),
                        Color.clear,
                    ],
                    center: .center,
                    startRadius: 0,
                    endRadius: 160
                )
            )
            .accessibilityHidden(true)
            .allowsHitTesting(false)
    }
}

#Preview("watermark behind text") {
    ZStack(alignment: .bottomTrailing) {
        CalWatermark()
            .frame(width: 320)
            .offset(x: 60, y: 40)
        VStack(alignment: .leading, spacing: 12) {
            Text("Good afternoon").font(.largeTitle.weight(.semibold))
            Text("Checked in today").foregroundStyle(Surface.inkSecondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
    }
}

#Preview("the four sizes") {
    VStack(spacing: 24) {
        HStack(alignment: .bottom, spacing: 16) {
            CalAvatar(.bubble)
            CalAvatar(.inline)
            CalAvatar(.card)
        }
        CalAvatar(.hero)
    }
    .padding()
}

#Preview("activity") {
    HStack(spacing: 24) {
        CalAvatar(.card, activity: .idle)
        CalAvatar(.card, activity: .listening)
        CalAvatar(.card, activity: .thinking)
        CalAvatar(.card, activity: .speaking)
    }
    .padding()
}

#Preview("reduce motion") {
    HStack(spacing: 24) {
        CalAvatar(.card, activity: .listening)
        CalAvatar(.card, activity: .speaking)
    }
    .padding()
}

#Preview("haloes") {
    HStack(spacing: 24) {
        CalAvatar(.card, halo: .none)
        CalAvatar(.card, halo: .sage)
        CalAvatar(.card, halo: .sageAndGold)
    }
    .padding()
}

#Preview("in a chat row") {
    HStack(alignment: .top, spacing: 10) {
        CalAvatar(.bubble)
        Text("Let's take one slow breath together before we look at the week.")
            .padding(12)
            .background(Surface.card, in: RoundedRectangle(cornerRadius: 16))
    }
    .padding()
}

#Preview("dark") {
    HStack(spacing: 24) {
        CalAvatar(.card, activity: .listening)
        CalAvatar(.card, activity: .speaking)
    }
    .padding()
    .preferredColorScheme(.dark)
}

#Preview("accessibility XXXL · the avatar grows, the hero does not") {
    VStack(spacing: 20) {
        HStack(spacing: 12) {
            CalAvatar(.bubble)
            Text("Scales with the text beside it.")
        }
        CalAvatar(.hero, activity: .listening)
    }
    .padding()
    .dynamicTypeSize(.accessibility3)
}
