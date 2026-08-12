import SwiftUI

/// Cal himself — the meditating bear.
///
/// Every place the character appears goes through this view, which is the point:
/// the artwork is still provisional (see `tools/make-cal-asset.py`), so replacing
/// it must be dropping in an asset rather than a hunt through feature code. The
/// same argument `CoherenceScale` makes about the band colours.
///
/// ## Two things this exists to get right
///
/// **VoiceOver.** The bubble avatar repeats once per assistant message, so a
/// labelled one would have a screen reader announce "Cal, a meditating bear"
/// forty times in a scrolled thread, between every reply and the next. Decorative
/// is therefore the *default*, and a label is opt-in for the few places the
/// picture is the content rather than the decoration.
///
/// **Dynamic Type.** A 28pt avatar sitting beside body text must grow with it or
/// it turns into a speck at AX5. A 180pt hero must *not*, or it pushes the screen
/// it introduces off the bottom. So scaling is a property of the size, not a
/// blanket rule — and the scaling sizes are capped, because `@ScaledMetric` at AX5
/// is roughly 2.4x and an avatar that big stops being an avatar.
public struct CalAvatar: View {

    /// The sizes actually used, rather than a free `CGFloat`.
    ///
    /// Named sizes because the alternative is a magic number at every call site
    /// and four subtly different avatars nobody intended.
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
            // Was 28, which read as a favicon beside a three-line reply. At 44
            // Cal is actually legible as a character — the face carries, rather
            // than being a brown smudge — and it still aligns with the first
            // line of the bubble rather than towering over it.
            case .bubble: 44
            case .inline: 44
            case .card: 120
            case .hero: 180
            }
        }

        /// Whether the size follows Dynamic Type. See the note above — this is
        /// the difference between an avatar that stays legible and a hero that
        /// evicts the content it sits above.
        var scales: Bool {
            switch self {
            case .bubble, .inline: true
            case .card, .hero: false
            }
        }

        /// Growth ceiling for the scaling sizes, as a multiple of the base.
        var scaleCeiling: CGFloat { 1.6 }
    }

    /// The ring behind Cal.
    ///
    /// This is `Brand.gold`'s documented job — a halo is decoration, which is the
    /// one thing gold is contrast-safe for (it measures 2.40:1 and fails even the
    /// non-text threshold, so it must never carry a shape that means something).
    public enum Halo: Sendable {
        case none
        /// A soft sage disc. Grounds Cal against a busy or a plain background.
        case sage
        /// The sage disc plus a gold hairline. For the moments that want ceremony
        /// — the empty chat state, the paywall.
        case sageAndGold
    }

    private let size: Size
    private let halo: Halo
    private let label: String?

    /// The declared `0` is never read — `init` replaces the whole wrapper with
    /// one seeded from the chosen size. The property wrapper attribute still has
    /// to name a value to be well-formed.
    @ScaledMetric(wrappedValue: 0, relativeTo: .body) private var scaled: CGFloat

    /// - Parameters:
    ///   - size: One of the four named sizes.
    ///   - halo: Defaults to none. See `Halo`.
    ///   - label: `nil` — the default — hides Cal from VoiceOver as decoration.
    ///     Pass a label only where the image is genuinely the content, such as an
    ///     empty state whose meaning is carried by the picture.
    public init(_ size: Size, halo: Halo = .none, label: String? = nil) {
        self.size = size
        self.halo = halo
        self.label = label
        self._scaled = ScaledMetric(wrappedValue: size.points, relativeTo: .body)
    }

    private var side: CGFloat {
        guard size.scales else { return size.points }
        return min(scaled, size.points * size.scaleCeiling)
    }

    public var body: some View {
        ZStack {
            switch halo {
            case .none:
                EmptyView()
            case .sage:
                Circle().fill(Brand.sage.opacity(0.16))
            case .sageAndGold:
                Circle().fill(Brand.sage.opacity(0.16))
                Circle().strokeBorder(Brand.gold, lineWidth: max(1, side / 90))
            }

            Image("Cal", bundle: .module)
                .resizable()
                // The source is a 600px illustration drawn down to as little as
                // 28pt. Without this the downscale is visibly gritty on the fur.
                .interpolation(.high)
                .scaledToFit()
                // Inset so the artwork sits *inside* the halo rather than
                // touching it. No inset when there is no halo — the asset already
                // carries its own small margin.
                .padding(halo == .none ? 0 : side * 0.08)
        }
        .frame(width: side, height: side)
        .accessibilityElement()
        .accessibilityLabel(label ?? "")
        .accessibilityHidden(label == nil)
    }
}

extension CalAvatar.Halo: Equatable {}

/// Cal as a background wash, rather than as an element.
///
/// Separate from `CalAvatar` because it is not an avatar: it has no size, no
/// halo, and nothing to announce. It is texture, and it is bound by one rule —
/// **text drawn over it must not get harder to read**. WCAG measures ink against
/// its background, and a background that varies is one you cannot measure once
/// and trust, which is why the opacity here is very low and not configurable.
///
/// Placed behind content, never between content and the reader.
public struct CalWatermark: View {
    private let opacity: Double

    /// - Parameter opacity: kept small deliberately. At 0.06 the darkest pixel of
    ///   the artwork shifts a white background by about four levels out of 255 —
    ///   far below anything that moves a contrast ratio. Raising it is a
    ///   legibility decision, not a taste one.
    public init(opacity: Double = 0.06) {
        self.opacity = opacity
    }

    public var body: some View {
        Image("Cal", bundle: .module)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .opacity(opacity)
            // Never announced, never focusable. It is wallpaper.
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
        CalAvatar(.card, halo: .sage)
        CalAvatar(.card, halo: .sageAndGold)
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
        CalAvatar(.hero, halo: .sage)
    }
    .padding()
    .dynamicTypeSize(.accessibility3)
}
