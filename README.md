# Cal Coherence

A coherence coach for UC Berkeley students, built with Breathe Health Center.
Architecture and all design decisions: [`ARCHITECTURE.md`](ARCHITECTURE.md).

**Phase 0 (foundation) is complete.** Phase 1 is the check-in flow — see §19.

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
open Cal.xcodeproj
```

The five local packages are wired as `XCLocalSwiftPackageReference`s, so they open
inside the project and edit live — no separate workspace needed.

Build and test on a simulator:

```bash
xcodebuild test -project Cal.xcodeproj -scheme Cal -destination 'platform=iOS Simulator,name=iPhone 17'
```

⚠️ `-only-testing` silently runs **zero** Swift Testing tests unless you double the
trailing parentheses (`-only-testing:CalTests/AppContainerTests/defaults()()`) —
xcodebuild strips the last pair. Silent success is worse than a failure, so prefer
running the whole action.

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

## The database

Requires the Supabase CLI, which is not yet installed here:

```bash
brew install supabase/tap/supabase
```

Then, from the repo root:

```bash
supabase start && supabase db reset && supabase test db
```

`db reset` applies `supabase/migrations/` then `supabase/seed.sql`, which creates
one deterministic test user with 60 days of check-ins — that's what makes the
analytics screens real. `test db` runs the pgTAP suite in `supabase/tests/`, which
sweeps the catalog for the RLS invariants in §11.6 (including that no view is
missing `security_invoker`).

`seed.sql` writes directly into `auth.users`. It is local-only and must never run
against staging or production.

---

## Before this can ship

Tracked in full at §18.6 and §20. The blocking ones:

1. **Is Cal part of BHC's clinical care, or a separate consumer product?** Decides
   whether the data is PHI, and therefore your Supabase tier and vendor
   agreements. Needs Dr. Mia's counsel, in writing. (§18.1)
2. **Apple Developer *organization* account under BHC** — guideline 5.1.1(ix)
   requires healthcare apps to ship from the legal entity providing the service.
   D-U-N-S number pending.
3. **The Berkeley crisis numbers are unverified and conflicting.** UC's own pages
   disagree. `EmergencyContact.pendingVerification` renders them as visibly
   unverified, and a test fails if anyone adds digits without promoting them
   deliberately. Someone must dial both. (§9.3)
4. **Rights to "Cal" and Berkeley marks**, or a rename. (§1)
5. **Both spec emails arrived truncated** — see [`docs/`](docs/).
