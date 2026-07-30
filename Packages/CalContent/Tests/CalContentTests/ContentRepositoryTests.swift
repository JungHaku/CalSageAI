import CalKit
import Foundation
import Testing

@testable import CalContent

@Suite("BundledContentRepository")
struct ContentRepositoryTests {
    let repo = BundledContentRepository()

    @Test("the bundled payload decodes")
    func decodes() async throws {
        let bundle = try await repo.bundle()
        #expect(bundle.version == 3)
        #expect(!bundle.exercises.isEmpty)
        #expect(!bundle.questions.isEmpty)
        #expect(!bundle.motivations.isEmpty)
    }

    // The check-in asks for a question on every step, so a repeated decode of a
    // few hundred KB would be silly. This also guards the actor's cache.
    @Test("repeated reads return the identical payload")
    func caches() async throws {
        #expect(try await repo.bundle() == (try await repo.bundle()))
    }

    // MARK: Questions

    @Test("every category has authored copy — the check-in can never render blank")
    func questionsAreComplete() async throws {
        let questions = try await repo.questions()
        for category in CoherenceCategory.allCases {
            let q = try #require(questions[category], "no question for \(category.rawValue)")
            #expect(!q.prompt.isEmpty)
            #expect(!q.rePrompt.isEmpty)
        }
    }

    /// The bundled JSON is the source; `CalKit`'s compiled-in seed is the
    /// last-resort fallback. Two copies of the same clinical text can drift, so
    /// this pins them together — exactly as the exercise seed is pinned.
    @Test("bundled question copy matches CalKit's fallback seed verbatim")
    func questionsMatchCalKitSeed() async throws {
        let bundled = try await repo.questions()
        for category in CoherenceCategory.allCases {
            let seed = CoherenceQuestion.seeded(category)
            let json = try #require(bundled[category])
            #expect(json.prompt == seed.prompt, "prompt drift on \(category.rawValue)")
            #expect(json.rePrompt == seed.rePrompt, "re-prompt drift on \(category.rawValue)")
            #expect(json.regulationSummary == seed.regulationSummary, "summary drift on \(category.rawValue)")
        }
    }

    // MARK: Exercises

    @Test("Dr. Mia's five practices are present, plus the labelled placeholder")
    func practicesPresent() async throws {
        let slugs = Set(try await repo.exercises(tier: nil).map(\.slug))
        for expected in [
            "microcosm-macrocosm-breath",
            "golden-spark-visualization",
            "presence-of-light",
            "solar-plexus-light",
            "sovereignty-reflection",
        ] {
            #expect(slugs.contains(expected), "missing practice: \(expected)")
        }
        #expect(slugs.contains("seed-placeholder"))
    }

    @Test("every exercise produces a playable timeline of a sane length")
    func allExercisesArePlayable() async throws {
        // Bound to a local first: iterating directly over `try await <call>`
        // segfaults this toolchain. Clearer this way regardless.
        let exercises = try await repo.exercises(tier: nil)
        for exercise in exercises {
            let timeline = try exercise.script.timeline()
            #expect(timeline.beats.count > 0, "\(exercise.slug) has no beats")
            // Over ten minutes is a pacing mistake rather than a design choice.
            // The floor is 30s because the study reset is deliberately that short.
            #expect(
                (30.0...600.0).contains(timeline.totalDuration),
                "\(exercise.slug) runs \(timeline.totalDuration)s"
            )
        }
    }

    @Test("no breath beat is uncomfortably long — pacing sanity")
    func breathBeatsAreComfortable() async throws {
        let exercises = try await repo.exercises(tier: nil)
        for exercise in exercises {
            let beats = try exercise.script.timeline().beats
            for beat in beats where beat.phase.isBreath {
                #expect(
                    beat.duration <= 10,
                    "\(exercise.slug): a \(beat.duration)s \(beat.phase.rawValue) is not comfortable"
                )
            }
        }
    }

    @Test("lookup by slug and by category both work")
    func lookups() async throws {
        #expect(try await repo.exercise(slug: "presence-of-light")?.title == "Presence of Light")
        #expect(try await repo.exercise(slug: "nope") == nil)
        #expect(try await repo.exercise(for: .presence)?.slug == "presence-of-light")
        #expect(try await repo.exercise(for: .connection)?.slug == "microcosm-macrocosm-breath")
    }

    /// Six categories still have no authored regulation exercise (§17 question 6).
    /// This test documents which, so when Dr. Mia supplies one the gap closes
    /// visibly instead of silently.
    @Test("categories still awaiting a practice are exactly the five we expect")
    func knownContentGaps() async throws {
        var missing: [CoherenceCategory] = []
        for category in CoherenceCategory.allCases
        where try await repo.exercise(for: category) == nil {
            missing.append(category)
        }
        #expect(
            Set(missing) == Set([.safety, .breath, .bodyAwareness, .innerKnowing, .authenticExpression]),
            "content gaps changed: \(missing.map(\.rawValue).sorted())"
        )
    }

    @Test("tier filtering separates the five practices from the free utilities")
    func tierFilter() async throws {
        let free = try await repo.exercises(tier: .free).map(\.slug)
        #expect(Set(free) == ["seed-placeholder", "study-reset"])
        #expect(try await repo.exercises(tier: .premium).count == 5)
    }

    /// Dr. Mia's spec makes the reset mandatory — "every session ends with" it —
    /// so it ships as authored content in her words rather than as UI copy.
    @Test("the study reset is her five cues, 30 seconds, plus the closing line")
    func studyReset() async throws {
        let reset = try #require(try await repo.exercise(slug: "study-reset"))
        let timeline = try reset.script.timeline()
        #expect(timeline.beats.map(\.text) == [
            "Breath", "Stretch", "Relax shoulders", "Jaw", "Eyes", "Back to work.",
        ])
        // Five cues at six seconds is the 30 seconds she specified; the closing
        // line runs past it.
        #expect(timeline.beats.prefix(5).reduce(0) { $0 + $1.duration } == 30)
        #expect(timeline.totalDuration == 34)
    }

    @Test("the browsable library is the five premium practices, not the utilities")
    func libraryIsPremiumOnly() async throws {
        let premium = try await repo.exercises(tier: .premium).map(\.slug)
        #expect(!premium.contains("study-reset"), "the reset is a tool, not a library session")
        #expect(!premium.contains("seed-placeholder"))
        #expect(premium.count == 5)
    }

    @Test("every practice carries Dr. Mia's authored purpose line")
    func purposesPresent() async throws {
        let exercises = try await repo.exercises(tier: .premium)
        for exercise in exercises {
            let purpose = try #require(exercise.purpose, "no purpose for \(exercise.slug)")
            #expect(!purpose.isEmpty)
        }
        #expect(
            try await repo.exercise(slug: "presence-of-light")?.purpose
                == "Cultivate presence and inner stillness."
        )
    }

    @Test("duration is exposed for list rows without re-deriving the timeline")
    func durationsExposed() async throws {
        let exercises = try await repo.exercises(tier: nil)
        for exercise in exercises {
            #expect(exercise.duration != nil, "\(exercise.slug) has no duration")
        }
    }

    // MARK: Motivations

    @Test("the motivation pool is Dr. Mia's five, verbatim")
    func motivationsMatchSpec() async throws {
        let bodies = try await repo.motivations().map(\.body)
        #expect(bodies.contains("You've survived 100% of your hardest days."))
        #expect(bodies.contains("Take one slow breath."))
        #expect(bodies.contains("Shoulders down."))
        #expect(bodies.contains("Drink some water."))
        #expect(bodies.contains("Go outside for five minutes."))
    }

    @Test("motivation ids are unique — they're used to suppress recent repeats")
    func motivationIDsUnique() async throws {
        let ids = try await repo.motivations().map(\.id)
        #expect(Set(ids).count == ids.count)
    }
}

@Suite("StaticContentRepository")
struct StaticContentRepositoryTests {
    @Test("an empty bundle still yields a question, via CalKit's fallback seed")
    func emptyBundleFallsBack() async throws {
        let repo = StaticContentRepository(.empty)
        let question = try await repo.question(for: .breath)
        #expect(question.prompt == CoherenceQuestion.seeded(.breath).prompt)
        #expect(!question.prompt.isEmpty)
    }

    @Test("a static bundle overrides the seed, which is how remote content will win")
    func overridesSeed() async throws {
        let override = CoherenceQuestion(
            category: .breath, prompt: "Reworded", rePrompt: "And now?", regulationSummary: "…"
        )
        let repo = StaticContentRepository(
            ContentBundle(version: 2, questions: [override], motivations: [], exercises: [])
        )
        #expect(try await repo.question(for: .breath).prompt == "Reworded")
    }
}
