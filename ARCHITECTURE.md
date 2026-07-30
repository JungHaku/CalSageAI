# Cal Coherence — MVP Architecture

**Client:** Breathe Health Center (Dr. Mia Curcuruto)
**Product:** `Cal` — a coherence coach for UC Berkeley students.
**Owner:** Beck Jungwhan
**Revised:** 2026-07-30 — restructured as a **local-first MVP, no backend**.

Everything that gates *shipping to real students* — privacy law, App Store review,
payments, AI vendor terms, campus data sources — moved to
[`docs/LAUNCH-REQUIREMENTS.md`](docs/LAUNCH-REQUIREMENTS.md). It is unchanged and
still cited; it is just not what you need open while building.

Dr. Mia's source material, verbatim:
[`SPEC-free.md`](docs/SPEC-free.md) · [`SPEC-premium.md`](docs/SPEC-premium.md) ·
[`SPEC-practices.md`](docs/SPEC-practices.md)

---

## Contents

1. [What the MVP is](#1-what-the-mvp-is)
2. [Backend-ready seams](#2-backend-ready-seams) ← *the part that matters most*
3. [Stack](#3-stack)
4. [Client architecture](#4-client-architecture)
5. [Local data](#5-local-data)
6. [Content pipeline](#6-content-pipeline)
7. [The check-in](#7-the-check-in)
8. [Guided practices](#8-guided-practices)
9. [Safety](#9-safety)
10. [AI — deferred, and where the key would have to live](#10-ai--deferred-and-where-the-key-would-have-to-live)
11. [Testing](#11-testing)
12. [Payments](#12-payments)
13. [Campus data](#13-campus-data)
14. [Privacy in a local-only app](#14-privacy-in-a-local-only-app)
15. [Phase B: adding Supabase](#15-phase-b-adding-supabase)
16. [Build order](#16-build-order)
17. [Open questions for Dr. Mia](#17-open-questions-for-dr-mia)
18. [Decision log](#18-decision-log)

---

## 1. What the MVP is

**A complete, useful app that runs entirely on the phone.** No accounts, no server,
no database, no API keys. A student installs it and it works — on the bus, in a
basement, in airplane mode.

This is a better MVP than the original plan, not a compromised one. The whole
coherence framework — the ten questions, the regulation trigger, the guided
practices, the before/after measurement, streaks, trends — is *local computation
over local data*. None of it needed a server. Deferring the backend removes the
$25–$1,050/month hosting question, the auth surface, the RLS surface, and most of
the legal surface (§14), and it does not remove a single thing a student would
notice in week one.

### In scope

| | |
|---|---|
| **Check-in** | Ten premium categories + the free single question, before/after capture, tier-specific regulation trigger |
| **Guided practices** | Dr. Mia's five, plus per-category regulation exercises as she supplies them |
| **Breathwork player** | Monotonic timing, breathing ring, phase-derived haptics, background audio |
| **History & analytics** | Streaks, daily/weekly/monthly trends, category trends, mean before→after delta |
| **Home** | Today's state, streak, daily motivation from a bundled pool |
| **Campus** | Map + the 231 seeded places, resource directory, study timer |
| **Planner** | EventKit — the student's existing iOS calendars |
| **Emergency** | Fully offline, one tap from everywhere |
| **Profile** | Name, major, grad year, goals, interests — device-local |
| **Export / delete** | Share-sheet JSON export; delete wipes the local store |

### Out of scope for the MVP

| | Why | Where it goes |
|---|---|---|
| Accounts / sign-in | Nothing to sync yet | Phase B |
| Supabase, RLS, migrations | Already written and correct in `supabase/`, just not run | Phase B |
| Cross-device sync | Needs accounts | Phase B |
| **AI coach chat** | No safe place for an API key without a backend (§10) | Phase B |
| AI journal / weekly review | Same | Phase B |
| Natural-language Navigate | Deterministic search covers the MVP; retrieval needs embeddings | Phase B |
| Canvas / Google calendar feeds | EventKit covers most of it with no OAuth | Phase B |
| Community features | A different product — scheduling, video, moderation | Post-launch |

**Premium ($11/mo) is still in scope** — StoreKit 2 works with no backend (§12).

### What already exists

Phases 0 and 1 are built and committed: the renamed project, five local Swift
packages, the check-in state machine, the breathwork player, SwiftData
persistence, **140 passing tests**, and the 231-place campus dataset. The
restructure below throws none of it away — §2 explains why it didn't have to.

---

## 2. Backend-ready seams

> *"Structure the MVP in a way that can easily incorporate database integration
> later."*

This is the requirement the rest of the document is organised around. The good
news: the architecture already did most of it, because every dependency has been a
protocol since Phase 0. Supabase arrives as **new implementations behind existing
protocols**, not as a rewrite.

### The five seams

| Seam | MVP implementation | Phase B implementation | UI changes? |
|---|---|---|---|
| `CoherenceStoring` | `SwiftDataCoherenceStore` | *same store* + `SyncEngine` pushing to Postgres | **No** |
| `ContentRepository` *(to build)* | `BundledContentRepository` — JSON in `CalContent` | `RemoteContentRepository`, bundled fallback | **No** |
| `CoachClient` | unused / `MockCoachClient` | `LiveCoachClient` → proxy | **No** |
| `IdentityProviding` *(to build)* | `LocalIdentity` — device UUID | `SupabaseIdentity` — `auth.uid()` | **No** |
| `SyncEngine` *(to build)* | `NoOpSyncEngine` | `SupabaseSyncEngine` | **No** |

Two already exist and ship in Phase 1. Three are small additions the MVP should
build **now, inert** — retrofitting them later is exactly what turns a swap into a
rewrite.

### Four invariants that make the swap safe

Cheap to honour now, expensive to retrofit. Treat them as rules.

**1. IDs are generated on-device as UUIDs, and are the future server primary key.**
Never let the server assign one. A `CheckIn.id` created today on a phone with no
account is the exact `checkins.id` that will exist in Postgres after sign-in. That
is what makes the first sync a plain upsert — no id remapping, no duplicate risk.
*Already true.*

**2. Domain types carry no `user_id`.** `CheckIn`, `CategoryScore`, and everything
in `CalKit` are user-agnostic; ownership is attached at push time by the sync
engine. So the same value type serves a no-account MVP and a multi-user backend
unchanged. *Already true.*

**3. Sync bookkeeping exists from day one, even though nothing syncs.** Every
persisted row already has `updatedAt`, `isDirty`, and `deletedAt`. `isDirty` is set
on write and never cleared in the MVP; delete is a soft delete. When the sync
engine arrives its outbox is simply *"everything still dirty"* — which on a device
that has never synced is the entire history. Nothing has to be reconstructed.
*Already true.*

**4. Local data must be claimable by a future account.** The one that isn't built
yet, and the one that matters most. A student who uses the app for two months
before accounts exist must not lose that history when they sign in.

### The claim migration

```
MVP                                   Phase B — first sign-in
────────────────────────────          ──────────────────────────────
LocalIdentity                         SupabaseIdentity
  deviceProfileID: UUID   ─────────►    auth.uid(): UUID
  (generated at first launch)           (assigned by Supabase)

StoredCheckIn                         checkins
  id: UUID              ────────────►   id  (same UUID, primary key)
  isDirty: true                         user_id ← attached at push
```

First successful sign-in is a **pure push**: the server has no rows for a brand-new
user, so there is nothing to merge and no conflict to resolve. Every dirty row is
upserted under the new `user_id`, then marked clean. Only *subsequent* devices ever
pull, and only then do §15's conflict rules matter.

Two things to design for now:

- **The local profile is a real record, not a bag of `UserDefaults` keys.** It gets
  a UUID at first launch and holds name, major, goals, interests, preferences. At
  claim time it becomes the `profiles` row. Loose defaults keys would be orphaned.
- **Nothing may key off "the current user".** In the MVP there is exactly one,
  implicitly. Any code that assumes that stays broken when there are two.

### What we keep even though the MVP never runs it

`supabase/migrations/`, `supabase/seed.sql`, and `supabase/tests/` stay in the
repo. They're written, correct, and reviewed; they are the Phase B target, and the
local model already mirrors them column-for-column. Deleting them would mean
re-deriving the same design later from memory.

---

## 3. Stack

| Layer | Choice | Note |
|---|---|---|
| Client | SwiftUI, iOS 18+ | |
| Local store | SwiftData | The source of truth, not a cache |
| Content | Bundled JSON in `CalContent` | Versioned, so remote can supersede later |
| Audio | AVFoundation | Background audio for breathwork |
| Payments | StoreKit 2, device-local entitlement | §12 |
| Maps | MapKit + the 231-place seed | |
| Calendar | EventKit | No OAuth, no Google verification |
| Crash reporting | Firebase Crashlytics | Free with no cap; Sentry's free tier is 5,000 errors/month, which one crash loop eats |
| CI | Xcode Cloud | 25 compute hours/month already included with the $99/yr membership |
| **Backend** | **none** | Phase B |

Deliberately absent: no third-party analytics or ad SDK **ever** (§14); no Firebase
for data or auth (one persistence story, not two); no Capacitor; no client-side LLM
key (§10).

---

## 4. Client architecture

Unchanged from Phase 0. The package split is what makes the fast test loop
possible, and it is also what makes §2's seams natural rather than bolted on.

```
Cal.xcodeproj                 five packages wired as local references
├── Cal/                      app target
│   ├── CalApp.swift          entry + AppContainer (DI, launch args)
│   ├── RootView.swift        the five-tab shell
│   ├── EmergencyView.swift   offline, one tap from every tab
│   └── Features/CheckIn/     flow, breathwork player, haptics
└── Packages/
    ├── CalKit/               pure logic, zero I/O — `swift test` in ~2s
    ├── CalDesign/            design system + previewable components
    ├── CalData/              SwiftData store, repositories, sync seam
    ├── CalAI/                CoachClient contract + mock
    └── CalContent/           bundled content + campus seed
```

`CalKit` has no UIKit, no SwiftUI, no SwiftData, and no network. That constraint is
load-bearing: `swift test --package-path Packages/CalKit` runs 82 tests in about
0.02 seconds with no simulator, which is the difference between testing constantly
and testing when you remember to.

**State:** `@Observable` view models, `async`/`await`, no Combine. Views own no
business logic. Every dependency is a protocol resolved once in `AppContainer` and
read from the environment, so previews, unit tests, and UI tests substitute mocks
without feature code knowing.

**Concurrency note.** Xcode 26 sets `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` on
app targets, so everything in the `Cal` module is implicitly main-actor isolated —
a good default for UI code, and the reason app-target test suites need `@MainActor`
while the packages stay nonisolated and `Sendable`.

---

## 5. Local data

SwiftData is the source of truth. The models already mirror the Postgres schema
column-for-column, which is what makes Phase B a push rather than a translation.

```swift
@Model final class StoredCheckIn {
    #Unique<StoredCheckIn>([\.id])
    var id: UUID                  // future server PK — never server-assigned
    var kindRaw: String
    var localDateISO: String      // "2026-07-30", mirrors Postgres `date`
    var timeZoneIdentifier: String
    var completedAt: Date?

    // Sync bookkeeping — inert in the MVP, populated correctly anyway (§2)
    var updatedAt: Date
    var isDirty: Bool
    var deletedAt: Date?          // tombstone, so deletes survive to Phase B

    @Relationship(deleteRule: .cascade, inverse: \StoredCategoryScore.checkIn)
    var scores: [StoredCategoryScore]
}
```

Three choices carried forward from Phase 1, each still load-bearing:

- **Days are `LocalDate` (y/m/d), not `Date`.** A check-in at 11pm and one at 1am
  are different days, and a `Date`-based streak breaks across DST. `LocalDate`
  makes those bugs unrepresentable, and it maps straight onto a Postgres `date`.
- **Mapping throws on drifted enums or out-of-range scores** rather than coercing
  to a default — a silently coerced row corrupts the averages that are the
  product's actual claim.
- **Delete is a soft delete.** In the MVP nothing pulls, so a hard delete would be
  harmless; the tombstone costs nothing now and is required the moment a second
  device exists.

### To build for the MVP

- `LocalProfile` model (§2) — UUID, name, major, grad year, goals, interests,
  preferences, `createdAt`.
- Daily-motivation history, so the message doesn't repeat.
- Range-aggregating analytics over `StoredCheckIn`. The arithmetic is already
  implemented and tested in `CalKit` (`averageBefore` / `averageAfter` /
  `averageDelta`, matching the `daily_coherence` view); this just needs a
  repository on top.
- Export: encode the store to JSON and hand it to a share sheet. In a local-only
  app that's a few lines, and it satisfies data portability outright.

---

## 6. Content pipeline

Originally authored content lived in Postgres so Dr. Mia could edit it without an
App Store release. Without a backend that isn't possible, so the MVP makes the
trade explicitly and keeps the door open:

- **All authored content ships as JSON in `CalContent`**, in the same shape as the
  future database rows.
- **Every item carries a `version` integer.** `ContentRepository` resolves an item
  by slug; the bundled implementation returns the bundled one. When
  `RemoteContentRepository` arrives it returns the remote item when its `version`
  is higher and falls back to bundled otherwise. Consumers never change, and the
  offline path stays the *primary* path rather than becoming a degraded one.
- **Content changes require an app release during the MVP.** That is the real cost
  of skipping the backend, and Dr. Mia should know it: a typo in a practice script
  is a 1–2 day turnaround, not a database edit. It's the strongest argument for
  doing Phase B before a wide launch. (§17, question 12.)

Content sets: `exercises` (the practices), `motivations`, `campusPlaces` (231
seeded), `campusResources`, and `questions` — the authored check-in copy, currently
a seed inside `CalKit` that should move to bundled content in MVP-1.

---

## 7. The check-in

Built in Phase 1. `CheckInFlow` in `CalKit` owns every transition; the view renders
`step` and nothing else.

```
rate → (if at/below the tier threshold) regulate → re-rate → next category → complete
```

Regulation is **immediate**, per category, as the premium spec requires — not
batched to the end. Skipping is always available: `score_after` stays `nil`, which
the analytics read as *unmeasured* rather than as *zero improvement*. Trapping
someone in a breathing exercise they don't want is bad product and worse
clinically; the framework is about restoring choice, so the app can't be the thing
that removes it.

**Threshold divergence, faithfully implemented.** The free spec routes the `0–4`
band into breathing, so a **5** gets "let's stay aware" and no exercise; the premium
spec says "5 or below" regulates. A 5 therefore regulates on premium and not on
free. Both are implemented, with a test pinning the difference (§17, question 11).

### Decision: the scale starts unset

*You asked me to call this one.*

**Decided: the slider will show no value, and Continue will stay disabled, until
the student deliberately picks a number.** *(Not yet implemented — the code still
defaults to 5. This lands in MVP-1.)*

Anchoring a self-report scale at a pre-filled value biases the answer — and 5 is
*exactly* the premium regulation threshold, so a pre-set 5 means anyone tapping
straight through is recorded as low-coherence and routed into an exercise. That
would inflate both the regulation rate and the mean before→after delta, which is
the single number Dr. Mia will read as evidence her method works. Protecting that
metric is worth one deliberate touch, and a student who genuinely feels a 5 still
makes exactly one tap.

The cost is real and worth stating plainly: the free tier is pitched as a
30-second check-in, and this adds friction across all ten premium questions. If she
disagrees once she's used it, it's a one-line change.

---

## 8. Guided practices

Dr. Mia has supplied **five**, verbatim, in
[`SPEC-practices.md`](docs/SPEC-practices.md). They are Premium Guided Library
sessions — **not** the ten per-category regulation exercises.

The step model already handles both shapes. A `cue` step has a duration and text
but no breath instruction and fires no haptic, so a silent guided reflection plays
correctly without a breathing ring driving it:

| Practice | Shape | Proposed default category |
|---|---|---|
| Microcosm → Macrocosm Breath | breath-paced + expanding visualisation | `connection` |
| Golden Spark Visualization | free breathing + body visualisation | `emotional_flow` |
| Presence of Light | affirmation + pauses to notice | `presence` |
| Solar Plexus Light | breath-paced + affirmation | `energy` |
| Sovereignty Reflection | question + silent wait + choice | `choice` |

**The wording is fixed; the pacing is not.** Her text marks pauses with `...` but
gives no durations, and turning that into a playable timeline means assigning
seconds to every line and every silence. Pacing a breath practice is a clinical
decision — too fast is stressful, too slow gets abandoned — so we propose timings
and she approves them before launch (§17, question 5).

Still needed: regulation exercises for `safety`, `breath`, `body_awareness`,
`inner_knowing`, `authentic_expression`, and the free tier's `overall`. Until they
arrive those categories route to a clearly-labelled placeholder, so a low score
always has somewhere to go.

---

## 9. Safety

Unchanged and fully in scope — **being local-only does not reduce this.**

- **Layer A — on-device pattern detection.** Built, and tested against a reviewed
  fixture set. Offline, instant, free. Tuned for recall, because the cost matrix is
  asymmetric: a false positive shows a card with a phone number, and a false
  negative is the worst outcome this app can produce.
- **Layer B — server classifier.** Phase B, when there is a server.
- **Layer C — prompt-level boundaries.** Phase B, when there is a model.
- **Layer D — always-available exit.** Built. Emergency Help is one tap from every
  tab, entirely offline, and never waits on a network call.

**In the MVP, Layers A and D are the whole pipeline — and that is coherent**,
because with no AI chat there is no generated text to moderate. The moment Phase B
adds the coach, Layers B and C become mandatory and California SB 243's
crisis-protocol and AI-disclosure obligations attach. See
[`LAUNCH-REQUIREMENTS.md`](docs/LAUNCH-REQUIREMENTS.md) §18.

**Still blocked:** the Berkeley crisis numbers. UC's own pages disagree —
`crisisresponse.berkeley.edu` prints (855) 817-8667 while
`uhs.berkeley.edu/after-hours` prints (855) 817-5667. The app ships 988 and 911
(nationally unambiguous) and renders the campus entries as visibly unverified, with
a test that fails if anyone pastes digits in without promoting them deliberately.
**Someone has to dial both.**

---

## 10. AI — deferred, and where the key would have to live

You asked when you'll need OpenAI keys. **Not yet** — and this deserves precision,
because *"skip the database"* and *"skip the backend"* are not the same decision.

There is no safe place for an API key in a local-only app. Anything shipped in the
binary is extractable; a key in the app means no rate limit, no spend ceiling, no
safety filtering, and no audit trail, with unbounded liability if it leaks. That
rule doesn't bend for an MVP.

So there are exactly three honest options:

1. **No AI in the MVP.** Recommended, and what this plan assumes. The check-in, the
   practices, analytics, streaks, and the campus features are the product's core
   and none of them need a model. The coach was Phase 3 in the original order
   anyway — a coach with no coherence history to reason about is a generic chatbot.
2. **A key-holder proxy with no database.** If you want the coach sooner, that's
   roughly 30 lines of server — a Cloudflare Worker, a Vercel function, or a
   Supabase Edge Function *used without the database*. It buys the key ceiling,
   rate limiting, and safety filtering without any of the schema, auth, or RLS work
   you're deferring. **This is the cheapest path to AI, and it does not require the
   Supabase migration.**
3. **A user-supplied key in Settings.** Fine for a private dev or demo build so you
   and Dr. Mia can feel the voice. Never for the App Store, never for real students.

**When to send me keys:** when you pick option 2 or 3. For option 2 I'd want an
OpenAI key to place in the proxy's secrets — never in the repo. Until then they'd
sit unused, which is its own small risk.

Model choice is already decided and verified: **`gpt-5.6-luna`** ($1/$6 per Mtok,
90% cached-input discount), about **$0.28/user/month at 100 messages** with
caching. Full comparison, caching traps, and vendor terms in
[`LAUNCH-REQUIREMENTS.md`](docs/LAUNCH-REQUIREMENTS.md) §10.

---

## 11. Testing

Six loops. Current state: **140 tests passing** — 118 across packages, 22 app + UI.

| Loop | Speed | What | Status |
|---|---|---|---|
| 1. Previews | instant | Every component per state, dark, XXXL | partial |
| 2. `swift test` on packages | ~2s | All logic, no simulator | **118 tests** |
| 3. Snapshot | ~1 min | `getsentry/SnapshotPreviews` turns each `#Preview` into a test | to build |
| 4. XCUITest | minutes | 5 seeded flows via launch arguments | **5 flows** |
| 5. TestFlight | days | Dr. Mia feels the pacing on a real phone | pending account |
| 6. Backend / RLS | — | 9 pgTAP catalog invariants, written | Phase B |

Loop 2 is the one you live in:

```bash
swift test --package-path Packages/CalKit
```

Seeded launch states keep UI tests deterministic: `-CalScenario day30Streak`,
`-CalUseMockCoach 1`, `-CalFixedDate 2026-07-29`.

**Four gotchas that have already cost real time here:**

- `xcodebuild -only-testing` silently runs **zero** Swift Testing tests unless you
  double the trailing parentheses (`Target/Suite/myTest()()`). Silent zero-test
  success is worse than a failure — assert a nonzero count in CI.
- `.accessibilityIdentifier` on a SwiftUI **container propagates to every
  descendant and overwrites theirs**, making child elements unqueryable. Identify
  leaves. When a UI test can't find something visibly on screen, print
  `app.debugDescription` before theorising.
- **A simulator you're driving by hand starves a concurrent test run.** The same
  suite went from 124 seconds to 69 minutes and produced two bogus timeout
  failures. Detach and `xcrun simctl shutdown all` before trusting a result.
- **Tests that assert on a persistent store break the moment persistence lands.**
  Assert on the configuration (*is this store ephemeral?*), not on residual disk
  state.

---

## 12. Payments

StoreKit 2 needs no backend, so premium stays in scope for the MVP.

- One auto-renewable subscription at the $10.99 tier, with a 7-day intro trial.
- Entitlement from `Transaction.currentEntitlements`, evaluated **on device**.
- **The honest limitation:** a device-local entitlement is not tamper-resistant. In
  the MVP that risk is bounded, because premium unlocks *content and analytics
  already on the phone* rather than metered server spend. The moment Phase B adds
  the AI coach, server-side verification becomes mandatory — otherwise a jailbroken
  device gets unlimited access to a paid model tier.
- A `.storekit` configuration file exercises purchase, restore, trial, renewal,
  expiry, and refund entirely in the simulator, so this is testable in Loop 4 with
  no App Store Connect round-trip.
- Apple takes 15% under the Small Business Program: **$9.35 net on $11**. Enroll
  before launch. Rejection-proofing and server-verification details in
  [`LAUNCH-REQUIREMENTS.md`](docs/LAUNCH-REQUIREMENTS.md) §12.

---

## 13. Campus data

Hand-curated, bundled, offline — which is exactly what a no-backend MVP wants.

**Already seeded:**
[`content/berkeley-locations-raw.json`](content/berkeley-locations-raw.json) — 231
distinct campus locations with coordinates, loaded by `CalContent`. (235 raw; the
source page lists four libraries twice at identical coordinates, so the loader
collapses exact duplicates rather than drawing two pins on one building.)

MVP: map + places, resource directory, study timer, EventKit planner. Deferred to
Phase B: library-hours API, transit feeds, Canvas/Google ICS, natural-language
Navigate. Source URLs, access constraints, and the traps — Canvas' API policy
forbids asking students to paste tokens; unverified Google OAuth expires every
user weekly — are in [`LAUNCH-REQUIREMENTS.md`](docs/LAUNCH-REQUIREMENTS.md) §14.

---

## 14. Privacy in a local-only app

**Staying local is a genuine privacy win, and it's worth understanding why.** With
no server there is no central store of students' mental-health data to breach, no
vendor chain to paper, no cross-border transfer, and deletion is provably complete
because it's one store on one device. That materially reduces exposure under the
laws that would otherwise dominate this project.

Still applies, MVP or not:

- **App Store review**, including guideline 1.4.1 — the primary rejection risk for
  anything resembling medical advice — the 16+ age rating, the privacy manifest,
  and the rule that healthcare apps ship from the legal entity providing the
  service. That still requires the BHC organization account.
- **Claim language.** "General wellness" framing keeps the app out of FDA device
  territory; claims about *treating* anxiety or depression do not.
- **No third-party analytics or ad SDK.** The FTC actions that produced real
  penalties were all about health data reaching analytics and ad vendors.
- **A privacy policy** that accurately says data stays on the device.

What changes the moment Phase B lands: chat text leaves the phone, and the AI
disclosure, SB 243 crisis-protocol publication, consent flow, and vendor terms all
attach. Full cited analysis in
[`LAUNCH-REQUIREMENTS.md`](docs/LAUNCH-REQUIREMENTS.md) §18.

**Unchanged and still blocking a real launch:** whether Cal is offered as part of
BHC's clinical care or as a separate consumer product. That decides whether the
data is PHI. It costs nothing to answer now and is expensive to answer late.

---

## 15. Phase B: adding Supabase

What actually happens, in order:

1. **Run what's already written.** `supabase start && supabase db reset &&
   supabase test db` — the schema, the `daily_coherence` view with
   `security_invoker`, the generated RLS policies, and 9 pgTAP catalog invariants
   are all in the repo, correct, and unrun.
2. **Auth.** Sign in with Apple first, then email/password, then
   anonymous→upgrade.
3. **`SupabaseIdentity`** replaces `LocalIdentity` behind `IdentityProviding`.
4. **The claim migration** (§2) — first sign-in is a pure push of every dirty row
   under the new `user_id`. No id remapping; the UUIDs already match.
5. **`SupabaseSyncEngine`** replaces `NoOpSyncEngine`. Conflict rules: check-ins and
   scores are append-only so conflicts are structurally rare; profile is
   last-write-wins per field; **journal never silently overwrites an unsynced local
   body** — losing someone's journal entry is the one unrecoverable data error in
   this app.
6. **`RemoteContentRepository`** — Dr. Mia edits content without an app release.
7. **The coach proxy** — Edge Function holding the key, plus safety Layers B and C,
   budget enforcement, and the kill switch.
8. **Server-side entitlement** — App Store Server Notifications V2.

Nothing in steps 1–8 requires touching `CalKit`, `CalDesign`, or any view.

---

## 16. Build order

**MVP-1 — seams and profile (next).** `ContentRepository`, `IdentityProviding`,
`NoOpSyncEngine`, `LocalProfile`. Small, boring, and the thing that makes Phase B
cheap. Move the check-in copy out of `CalKit`'s seed into bundled content. Also
implement the unset scale decision from §7, which is decided but not yet built.

**MVP-2 — practices.** Dr. Mia's five as structured scripts with proposed timings,
the per-category mapping, placeholder handling, and an exercise library browser.

**MVP-3 — retention loop.** Home, streak, daily motivation, morning reminder
(a *local* notification — no push, no entitlement), history list.

**MVP-4 — analytics.** Daily/weekly/monthly trends, per-category trends, and the
mean before→after delta as the headline. Where the 60-day synthetic fixture pays
off.

**MVP-5 — campus.** Map + 231 places, resource directory, study timer, EventKit
planner.

**MVP-6 — profile, export, delete, settings.**

**MVP-7 — premium.** StoreKit, paywall, local entitlement, gating.

**MVP-8 — polish and TestFlight.** Snapshot tests, accessibility pass, App Store
assets, external testers.

Then Phase B (§15), when a wide launch, cross-device sync, or the AI coach makes a
backend worth its cost.

---

## 17. Open questions for Dr. Mia

Blocking a real launch:

1. **Is Cal part of BHC's clinical care, or a separate consumer product?** Decides
   whether the data is PHI, and therefore the vendor agreements at Phase B.
2. **Apple Developer organization account under BHC.** Guideline 5.1.1(ix) requires
   healthcare apps to ship from the legal entity providing the service. D-U-N-S
   pending.
3. **Rights to "Cal" and Berkeley marks**, or a rename.
4. **The Berkeley crisis numbers** (§9). Someone must dial both.

Content, needed to finish the MVP:

5. **Pacing for the five practices** (§8). We propose timings; she approves. The
   wording is fixed and preserved verbatim.
6. **The ten per-category regulation exercises.** The spec gives each a phrase
   ("Cal guides a grounding exercise"); each needs authored copy. Six categories
   currently have none.
7. **Will she record audio in her own voice?** Strongly recommended — the biggest
   differentiator against every other wellness app, and the part no model can
   replace.
8. **The final name for the practices section** — she flagged the current one as a
   working title.
9. **Cal's voice.** Three or four transcripts of how she actually coaches would
   improve the eventual system prompt more than any description could.
10. **Crisis protocol copy** — exactly what Cal says at each severity, and which
    Berkeley resources in what order. She should own this wording.

Product:

11. **The two specs disagree on the regulation threshold** (§7). A 5 regulates on
    premium but not on free. Both are implemented faithfully; if it's an oversight
    rather than a design choice, it's a one-line change.
12. **Does she accept content changes requiring an app release** during the MVP
    (§6)? It's the main practical cost of skipping the backend.
13. **Free/premium boundary** — confirm the split, particularly whether free users
    get any coach chat once it exists.
14. **Sacred Care Fund** — how it's represented in-app.
15. **Launch timing.** Fall semester start is the obvious moment for a Berkeley
    student app.

*Resolved: the 0–10 scale starts unset rather than pre-filled (§7) — my call, as you
asked.*

---

## 18. Decision log

| # | Decision | Rationale | Revisit if |
|---|---|---|---|
| 1 | Native SwiftUI, iOS 18+ | Haptics, background audio, App Store trust | Android required |
| 2 | **Local-first MVP, no backend** | The whole framework is local computation; defers cost, auth, RLS, and most legal surface without losing a week-one feature | Cross-device sync or the AI coach becomes urgent |
| 3 | SwiftData is the source of truth, not a cache | There is nothing to cache from | Phase B — it becomes both |
| 4 | Every dependency behind a protocol from day one | Makes Phase B a swap, not a rewrite | Never |
| 5 | On-device UUIDs as future server PKs | First sync is a plain upsert with no id remapping | Never |
| 6 | Sync fields present but inert | Free now; the outbox is "everything dirty" later | Never |
| 7 | Keep `supabase/` in the repo, unrun | Written, correct, reviewed — it's the Phase B target | Never |
| 8 | No LLM in the MVP | No safe place for a key without a server (§10) | A 30-line proxy is worth it |
| 9 | Content bundled + versioned | Same shape as future rows; remote supersedes by version | Phase B |
| 10 | Clinical content authored, never generated | Dr. Mia's IP and protocol fidelity; also free and offline | Never |
| 11 | Scale starts unset | Anchoring at 5 — exactly the regulation threshold — would inflate the metric that is her clinical claim | She disagrees after using it |
| 12 | Device-local entitlement for the MVP | Premium unlocks local content, not metered spend | The AI coach lands |
| 13 | Logic in a pure SPM package | 2-second test loop | Never |
| 14 | Emergency screen offline, one tap, no unverified numbers | It has to work when nothing else does | Never |
| 15 | No third-party analytics or ad SDK | Exactly the conduct behind every FTC health-app penalty | Never |
| 16 | Curated campus data | Accurate, offline, no institutional approval needed | Berkeley grants GIS access |
| 17 | Portrait-locked | The breathwork ring needs the height | Tablet support |
