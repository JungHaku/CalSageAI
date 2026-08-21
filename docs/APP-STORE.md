# App Store submission — assets, metadata, and what still blocks it

Everything here is verified against App Store Connect Help and the Review
Guidelines as of **2026-07-30**. Character limits are exact.

> **Claim language.** Every string below is written to stay on the safe side of
> FDA general-wellness guidance (`LAUNCH-REQUIREMENTS.md` §18.5): no "treats",
> no "therapy", no "reduces symptoms of", no named conditions. Anything Dr. Mia
> rewrites needs the same pass before it ships.

---

## 1. Blockers — none of these are code

| Blocker | Why it stops submission | Owner |
|---|---|---|
| **The name "Cal"** | Berkeley marks are unresolved (§1). The app name, the character, and the bundle ID all use it. Renaming after launch costs the URL and the reviews. | Dr. Mia / counsel |
| **D-U-N-S number** | Needed for the Breathe Health Center **organization** account. Guideline 5.1.1(ix) says apps in "highly regulated fields (such as … healthcare)" **should** be submitted by the legal entity providing the service, not an individual — Apple's word is "should", but filing as an individual for a clinic-partnered health app invites exactly the question you do not want at review. | User |
| **Regulated medical device status** | Apple began requiring this status on **26 March 2026** for *new* apps meeting its criteria in the EEA, UK and US. A wellness app answering "Frequent" to Medical or Treatment Information in the age-rating questionnaire is the trigger. Determine the answer before submitting — this is new and easy to walk into. | Decision |
| **Privacy policy URL** | Mandatory in App Store Connect *and* linked in-app. `Legal.privacyPolicy` currently points at `breathehealthcenter.com/cal/privacy`, which has never been checked. A 404 is a 2.1(a) "fully functional URLs" rejection. | User |
| **Crisis numbers** | Two UC pages disagree on the after-hours line. Until someone dials both, the campus section ships as visibly unverified (§9.3). | Dr. Mia |
| **Subscription product** | The first auto-renewable subscription must be submitted **with** a build (§18.7). Either it goes in this submission or the paywall must not be reachable. | Decision |
| **Sacred Care Fund claim** | Cannot ship in any form yet (§18.8). | Dr. Mia |

---

## 2. Metadata

Limits are Apple's, and are counted here.

| Field | Limit | Draft | Count |
|---|---|---|---|
| **Name** | 30 | `C.A.L Coherence` | 16 |
| **Subtitle** | 30 | `A daily check-in for students` | 29 |
| **Promotional text** | 170 | see below | 148 |
| **Keywords** | 100 | see below | 98 |
| **Description** | 4000 | see below | ~1180 |

Promotional text (editable without a new build — use it for term dates, not features):

```
Thirty seconds a day. Rate how you're doing, take a guided minute when you need
one, and watch the pattern over a semester instead of guessing.
```

Keywords (comma-separated, no spaces after commas — spaces cost characters):

```
coherence,checkin,breathing,wellbeing,student,campus,berkeley,stress,focus,study,habit,mood,tracker,calm,breath
```

Description:

```
C.A.L is a daily coherence check-in built for university life.

Answer one question — how you're doing, right now, on a scale of 0 to 10. If
you're low, C.A.L takes you through a short guided breathing practice and asks
again, so you can see what a couple of minutes actually changed. That's the
whole loop, and it's designed to take about thirty seconds on an ordinary day.

WHAT'S IN THE FREE VERSION
• The daily check-in, with guided breathing whenever you need it
• Your streak, your recent average, and every check-in you've ever made
• Study Mode — a focus block that ends with a thirty-second reset
• Today's schedule, read from the calendars already on your phone
• A campus map with search and filtering
• Emergency help, one tap from every screen, working offline

C.A.L+ COHERENCE
A monthly subscription adds the full ten-area framework — safety, breath,
presence, emotional flow, body awareness, choice, connection, energy, inner
knowing, and authentic expression — each with a regulation practice when a
score comes back low. It also unlocks your full progress view and the guided
practice library.

YOUR DATA STAYS ON YOUR PHONE
There's no account and nothing is uploaded. You can export everything as a
readable file, or delete all of it, from Settings. Deleting the app takes your
history with it.

C.A.L is a wellness tool. It is not therapy, not medical care, and not a
substitute for either. If you are in danger, call 911. The Suicide & Crisis
Lifeline is 988, by call or text, at any hour.
```

**"What's New"** is not required for a first version.

---

## 3. Screenshots

Apple simplified this: **only one iPhone size is mandatory** — 6.9" — and
everything else is auto-scaled from it. **iPad screenshots are not required** for
an iPhone-only app.

- 6.9" accepts more than one exact pixel size. The captures produced by
  `ScreenshotTests` on an iPhone 17 Pro Max are **1320 × 2868**, which is the
  native 6.9" resolution — not the 1290 × 2796 that gets quoted, which is the
  6.7" size. Confirm against the accepted list in App Store Connect at upload;
  the uploader rejects a wrong size immediately, so this is self-correcting.
- 1–10 per display size. PNG or JPEG, **no alpha channel**.
- Capture on an iPhone 17 Pro Max simulator.

`ScreenshotTests` captures the six candidate frames as test attachments. It is
deliberately not part of the normal suite's assertions — it produces artefacts,
it does not verify anything.

Proposed order (the first two are what most people ever see):

1. Home with a streak — the daily loop, in one glance
2. The check-in question with the scale
3. A guided breathing practice mid-run
4. Progress: coherence over time
5. Study Mode running
6. Settings, showing export and delete — the privacy story is a feature

---

## 4. App privacy

The MVP transmits nothing off-device, so Apple's definition of "collect" is not
met and the honest answer is **Data Not Collected** — a single radio button that
ends the questionnaire. Two conditions, both currently true and both worth
re-checking before every submission:

- No analytics SDK, no crash reporter, no ad SDK. The answer covers third-party
  behaviour too, so adding any of them breaks it.
- No network calls carrying personal data. When the AI coach lands at Phase B
  this answer changes, and guideline 5.1.2(i) then requires explicit permission
  before sharing anything with a third-party AI.

`PrivacyInfo.xcprivacy` is separately mandatory and unrelated to the above — it
declares *required-reason API* usage, not data collection.

---

## 5. Export compliance

The app uses HTTPS and system crypto only, and nothing custom.

- `ITSAppUsesNonExemptEncryption` = **NO** (boolean false) in `Info.plist`. This
  is what stops App Store Connect asking on every single upload. Apple's wording
  is that OS-provided encryption is "**typically**" exempt — the hedge is theirs,
  so confirm nothing custom has crept in before answering.
- No CCATS, no ERN, no documentation upload.
- Residual obligation, easy to miss: the **BIS annual self-classification
  report**, due **1 February**. It is a US government filing, not an Apple one,
  and Apple's own documentation flags it.

---

## 6. Age rating

17+ no longer exists; the tiers are 4+, 9+, 13+, 16+, 18+. **16+ is the decision**
(§18.4) — the honest answer for frequent wellness content plus, at Phase B,
open-ended AI chat. Guideline 2.3.6 makes an honest answer a requirement and
warns about regulator inquiry, so the questionnaire gets answered to match the
app's behaviour, not its marketing.

---

## 7. TestFlight

**Internal testing** (up to 100 people, already on the team) triggers **no**
review and can start as soon as a build uploads. **External testing** (up to
10,000) triggers TestFlight App Review on the first build submitted to a group —
and that review checks against the **full** Review Guidelines, not a lighter
content-only pass. Note the ordering trap: an **internal group must exist before
an external one can be created**.

Blocks the **build** itself (red status, build unusable):
- A provisioning profile **missing the app identifier** — "Not Available for
  Testing". This one is genuinely fatal.

Blocks **upload**:
- App record (needs a registered bundle ID) and a signed agreement

Needs answering but is *not* fatal:
- **Export compliance.** "Missing Compliance" is a yellow status, not a red one —
  it gates distribution until answered rather than bricking the build.

Blocks **external testing only** — the build still works internally without it:
- **Beta App Description.** App Store Connect Help states outright that this field
  is required.
- **Feedback Email** is *not* documented as required anywhere, despite being widely
  listed as such. Fill it in regardless — it is the reply-to on tester invitations —
  but do not treat a missing one as the reason a submission is stuck.

The **subscription does not need to be approved** before external testing, but
the **Paid Apps Agreement must be Active**, with banking and tax complete. That
agreement is signed by the account holder, which loops back to the D-U-N-S
blocker above.

Apple publishes **no** service-level target for TestFlight App Review. The
"90% within 24 hours" figure that circulates is Apple's *App Review* number and
does not apply. Builds expire after 90 days.
