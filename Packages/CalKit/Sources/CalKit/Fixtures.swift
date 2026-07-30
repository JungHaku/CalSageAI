import Foundation

// Fixtures live in the shipping target, not the test target, on purpose: the same
// data drives `#Preview`s (§11.1), unit tests (§11.2), and the seeded XCUITest
// scenarios (§11.4). One definition, three consumers — so a preview and a test
// can never disagree about what "a low-coherence day" means.

/// A crisis-detector case. This array is the artifact Dr. Mia and a clinician
/// review and sign off on (§9.4) — and it is the regression suite, so adding a
/// reviewed case here is how the detector is allowed to change.
public struct CrisisFixture: Sendable, CustomStringConvertible {
    public let text: String
    public let expected: CrisisSeverity
    /// Why this case is in the suite — read by whoever reviews the list.
    public let rationale: String

    public var description: String { "\(expected): \"\(text)\"" }

    public init(_ text: String, _ expected: CrisisSeverity, _ rationale: String) {
        self.text = text
        self.expected = expected
        self.rationale = rationale
    }
}

extension CrisisFixture {
    public static let all: [CrisisFixture] = [
        // --- Acute: explicit and unambiguous ---
        .init("I want to kill myself", .acute, "explicit intent"),
        .init("I've been thinking about ending my life", .acute, "explicit intent, past-continuous"),
        .init("i dont want to be here anymore", .acute, "explicit, no apostrophe"),
        .init("I don't want to be here anymore.", .acute, "same phrase with apostrophe and punctuation"),
        .init("I feel suicidal", .acute, "clinical self-report"),
        .init("everyone would be better off dead without me", .acute, "indirect but explicit"),

        // --- Elevated: serious, but also used non-literally by students ---
        .init("this chemistry exam makes me want to die", .elevated, "hyperbole; must NOT suppress the reply"),
        .init("I've been hurting myself again", .elevated, "self-harm disclosure"),
        .init("I have no reason to live", .elevated, "hopelessness with explicit framing"),

        // --- None: benign references that must not fire ---
        .init("I saw a suicide prevention poster on Sproul", .none, "benign phrase stripped before matching"),
        .init("what's the number for the suicide crisis line?", .none, "help-seeking about the resource itself"),
        .init("this homework is killing me", .none, "common hyperbole, deliberately excluded"),
        .init("kill me now, three midterms in one week", .none, "\"kill me\" deliberately excluded — too common"),
        .init("I can't do this anymore", .none, "ordinary exam stress; Layer B's job, not Layer A's"),
        .init("I'm hopeless at organic chem", .none, "bare \"hopeless\" deliberately excluded"),
        .init("my therapist suggested I try breathing exercises", .none, "clinical context, no risk language"),
        .init("", .none, "empty input"),
        .init("   \n  ", .none, "whitespace only"),
    ]
}

// MARK: - Check-in fixtures

extension CheckIn {
    /// A completed premium check-in whose scores all sit in the given band, with
    /// regulation applied where the policy requires it.
    public static func fixture(
        kind: CheckInKind = .full,
        band: CoherenceBand,
        on day: LocalDate = LocalDate(year: 2026, month: 7, day: 29),
        regulated: Bool = true
    ) -> CheckIn {
        let before: Int = switch band {
        case .low: 3
        case .moderate: 6
        case .high: 9
        }
        let policy = kind.regulationPolicy
        let scores = kind.categories.map { category -> CategoryScore in
            let beforeScore = Score(clamping: before)
            let needsWork = policy.needsRegulation(beforeScore)
            return CategoryScore(
                category: category,
                before: beforeScore,
                after: (needsWork && regulated) ? Score(clamping: before + 3) : nil,
                exerciseSlug: needsWork ? "seed-placeholder" : nil
            )
        }
        return CheckIn(
            kind: kind,
            localDate: day,
            timeZoneIdentifier: "America/Los_Angeles",
            scores: scores,
            completedAt: Date(timeIntervalSince1970: 1_785_000_000)
        )
    }

    /// `count` consecutive days of completed check-ins ending on `endingOn`.
    ///
    /// Scores follow a deterministic pseudo-random walk — no `Date()`, no
    /// `random()` — so previews, snapshot tests, and `seed.sql` all render the
    /// exact same chart every run. A flaky fixture makes a flaky snapshot test.
    public static func syntheticHistory(
        days count: Int,
        endingOn endDay: LocalDate,
        calendar: Calendar,
        seed: UInt64 = 20_260_729
    ) -> [CheckIn] {
        var rng = SplitMix64(seed: seed)
        return (0..<count).reversed().map { offset in
            let day = endDay.adding(days: -offset, in: calendar)
            // Drifts gently upward over time so trend lines have something to show.
            let base = 4 + Int(Double(count - offset) / Double(max(count, 1)) * 3.0)
            let scores = CoherenceCategory.fullCheckIn.map { category -> CategoryScore in
                let before = Score(clamping: base + rng.next(upperBound: 4) - 1)
                let needsWork = RegulationPolicy.full.needsRegulation(before)
                return CategoryScore(
                    category: category,
                    before: before,
                    after: needsWork ? Score(clamping: before.value + 1 + rng.next(upperBound: 3)) : nil,
                    exerciseSlug: needsWork ? "seed-placeholder" : nil
                )
            }
            return CheckIn(
                kind: .full,
                localDate: day,
                timeZoneIdentifier: "America/Los_Angeles",
                scores: scores,
                completedAt: Date(timeIntervalSince1970: 1_785_000_000)
            )
        }
    }
}

/// Small deterministic PRNG so fixtures are reproducible across processes and
/// platforms. `SystemRandomNumberGenerator` is not, and `Int.random` would make
/// snapshot tests flaky.
struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) { self.state = seed }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func next(upperBound: Int) -> Int {
        guard upperBound > 0 else { return 0 }
        return Int(next() % UInt64(upperBound))
    }
}
