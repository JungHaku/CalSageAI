# Cal Coherence

A coherence coach for UC Berkeley students, built with Breathe Health Center.

**The MVP runs entirely on the phone — no backend, no accounts, no API keys.**
There is nothing to set up beyond Xcode.

- [`ARCHITECTURE.md`](ARCHITECTURE.md) — the MVP design, and how the backend drops
  in later without a rewrite
- [`docs/LAUNCH-REQUIREMENTS.md`](docs/LAUNCH-REQUIREMENTS.md) — what gates
  shipping to real students: privacy law, App Store review, payments, AI vendor
  terms
- [`docs/`](docs/) — Dr. Mia's specs, verbatim

**Built so far:** the check-in flow, the breathwork player, SwiftData persistence,
the five-tab shell, offline Emergency Help, and 231 seeded campus locations.
**140 tests passing.** Next up is MVP-1 — see ARCHITECTURE.md §16.

---

## The inner loop

All domain logic lives in `Packages/CalKit`, which has no UIKit, no SwiftUI, and no
network — so it tests in about two seconds with no simulator. This is where you
should spend most of your time.

```bash
swift test --package-path Packages/CalKit
```

Re-run on every save:

```bash
fswatch -o Packages/CalKit/Sources | xargs -n1 -I{} swift test --package-path Packages/CalKit
```

All five packages:

```bash
for p in CalKit CalDesign CalData CalAI CalContent; do (cd "Packages/$p" && swift test); done
```

## The app

```bash
open "CalSageAI.xcodeproj"
```

The five local packages are wired as `XCLocalSwiftPackageReference`s, so they open
inside the project and edit live — no separate workspace needed.

Build and test on a simulator:

```bash
xcodebuild test -project CalSageAI.xcodeproj -scheme Cal -destination 'platform=iOS Simulator,name=iPhone 17'
```

### Seeded launch states

UI tests and previews pin the app to a deterministic state instead of tapping
through screens to reach one:

| Argument | Effect |
|---|---|
| `-CalScenario empty` | no history |
| `-CalScenario lowCoherenceDay` | one unregulated low-band check-in |
| `-CalScenario day30Streak` | 30 consecutive days |
| `-CalUseMockCoach 1` | never reach a real model — no cost, no network |
| `-CalFixedDate 2026-07-29` | freeze the clock so streak assertions are stable |

### Test-loop gotchas

Each of these has already cost real time here:

- `-only-testing` silently runs **zero** Swift Testing tests unless you double the
  trailing parentheses (`-only-testing:CalTests/AppContainerTests/defaults()()`) —
  xcodebuild strips the last pair. Prefer running the whole action.
- **Don't drive the simulator by hand while a test run is going.** It starves the
  run: the same suite went from 124 seconds to 69 minutes and produced two bogus
  timeout failures. `xcrun simctl shutdown all` first.
- `.accessibilityIdentifier` on a SwiftUI **container overwrites every
  descendant's**. Identify leaf elements. When a UI test can't find something
  that's visibly on screen, print `app.debugDescription`.

## The database — not needed for the MVP

`supabase/` holds a complete schema, RLS policies, a seed, and 9 pgTAP catalog
invariants. **None of it runs during MVP development.** It is kept because it's
written, reviewed, and correct, and the local SwiftData models already mirror it
column-for-column — it is the Phase B target (ARCHITECTURE.md §15).

When that time comes:

```bash
brew install supabase/tap/supabase
supabase start && supabase db reset && supabase test db
```

`seed.sql` writes directly into `auth.users`. It is local-only and must never run
against staging or production.

---

## Before this can ship

Full list at ARCHITECTURE.md §17. The blocking ones:

1. **Is Cal part of BHC's clinical care, or a separate consumer product?** Decides
   whether the data is PHI, and therefore the vendor agreements at Phase B. Needs
   Dr. Mia's counsel, in writing.
2. **Apple Developer *organization* account under BHC** — guideline 5.1.1(ix)
   requires healthcare apps to ship from the legal entity providing the service.
   D-U-N-S number pending.
3. **The Berkeley crisis numbers are unverified and conflicting.** UC's own pages
   disagree. They render as visibly unverified, and a test fails if anyone adds
   digits without promoting them deliberately. Someone must dial both.
4. **Rights to "Cal" and Berkeley marks**, or a rename.
5. **Both spec emails arrived truncated** — see [`docs/`](docs/).
6. **Pacing for Dr. Mia's five practices.** Her wording is fixed; the timings are
   ours to propose and hers to approve.
