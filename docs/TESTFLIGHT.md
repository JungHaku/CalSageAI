# TestFlight — beta metadata and what to tell testers

Everything App Store Connect asks for on the TestFlight tab, drafted and counted.
Companion to [`APP-STORE.md`](APP-STORE.md), which covers the public listing.

**Internal vs external, because they have different bars.** Internal testing (up
to 100 people on the team, via App Store Connect roles) needs **no review** — the
build is available as soon as it finishes processing. External testing needs
**Beta App Review**, which applies most of the App Review guidelines, including
the ones still open in §4 below. Start internal.

---

## 1. Test Information

### Beta App Description

> Cal is a daily coherence check-in for university students, built with WholeLife
> Ministries. Rate how you're doing on a 0–10 scale; if you're low, Cal walks you
> through a short guided breathing practice and asks again, so you can see what a
> couple of minutes actually changed. There's also a campus map, a study timer,
> and Cal — an AI coach you can talk to.
>
> This build is for internal testing. It talks to a live backend and a live AI
> model, so please don't put anything in it you wouldn't want stored.

Note the last line. `APP-STORE.md` §7 records that App Store Connect's help text
says the Beta App Description is **shown to testers**, so it is the right place
for that warning and the wrong place for internal notes.

### Feedback email

The same address as `CalSupportEmail` in `Info.plist`. Keep them identical — a
tester who replies to the wrong one should still reach a human.

**Currently `beck.alexmlg@gmail.com`, which should change before external
testing.** Guideline 1.2 asks for published contact information and *timely*
responses, and a personal Gmail is a weak answer to a reviewer who checks.

### Marketing URL / Privacy policy URL

Privacy policy is **required** for external testing and is currently
`breathehealthcenter.com/cal/privacy`, which has never been confirmed to resolve.
A 404 is a 2.1(a) rejection. Internal testing does not check it.

---

## 2. "What to Test" — paste this into the build's notes

Keep it short and ask for specific things. Testers who are told "have a look"
report nothing; testers given four numbered tasks report bugs.

```
Thanks for testing Cal. About 10 minutes. Please try these four things and
tell me what was confusing, not just what broke.

1. CHECK IN (30 seconds)
   Home > Start today's check-in. Drag the slider to a low number and continue.
   You should get a guided breathing minute with Cal in the middle, then be
   asked the same question again.
   - Did the breathing pace feel right, or too fast/slow?
   - Did the second question feel worth answering?

2. TALK TO CAL (2 minutes)
   Chat tab. Tell it something real about your week.
   - Does it sound like a person who is listening, or like a chatbot?
   - Tap the small flag next to any reply — that's the report button. It
     should open a form. (Reports are saved on your phone for now.)

3. MAKE AN ACCOUNT (1 minute)
   Settings > Account and memory > Create an account instead.
   You'll get a confirmation email — click the link, then come back and sign in.
   - Did the email arrive? How long did it take?
   - The "Let C.A.L remember our conversations?" question defaults to NO.
     Was it clear what you were agreeing to?

4. LOOK AROUND (5 minutes)
   Navigate, Planner, Study, History, Settings.
   - Anything that looks broken, empty, or unfinished?
   - Try the red life-ring button in the top right from a few screens.

KNOWN, DON'T REPORT:
- Practices and Progress have padlocks. That's the paid tier; it isn't built
  to buy yet.
- The campus list shows street addresses instead of building names for a lot
  of places, and the Dining/Health filters barely work.
- Your data doesn't sync between devices yet, even signed in.
- Conversations with Cal disappear when you leave the tab.
- The app is light-mode only on purpose.

WHAT I MOST WANT TO KNOW:
Did anything make you feel worse, judged, or watched? That matters more than
any bug.
```

---

## 3. Before inviting anyone

In the order they will actually bite.

1. **Auth mail has to go through Resend, from a domain you verified.**
   Built-in Supabase SMTP only delivers to project members. Resend's
   `onboarding@resend.dev` only delivers to the Resend account owner. Either
   way testers never get "check your email." Point Auth at Resend SMTP
   (`./tools/configure-resend-smtp.sh` or Authentication → Email → SMTP) using
   an address on a verified domain. Then delete the stuck user and sign up again.
2. **Set a spend cap in the OpenAI dashboard.** The coach function is public
   (`--no-verify-jwt`, so anonymous chat works as designed), has no per-user
   budget, no rate limit and no kill switch — none of §10's controls are built.
   Every tester message spends real money and nothing stops a loop.
3. **Delete the smoke-test accounts** in Supabase → Authentication → Users.

---

## 4. Known gaps, so nobody reports them as bugs

Recorded here rather than left to surprise a tester or a reviewer.

| Gap | Why it is not a bug yet |
|---|---|
| No cross-device sync | `SyncEngine` is still `NoOpSyncEngine`. Accounts authenticate; data stays on the device (ARCHITECTURE §15 step 5). |
| Chat does not persist | `ChatViewModel` holds messages in memory and mints a new thread each time the view loads. `chat_threads`/`chat_messages` exist and are unused. |
| No cost visibility | `.finished` discards its `CoachUsage` and nothing writes `ai_usage`, so there is no dashboard — only an invoice. |
| Cal does not read Dr. Mia's content | No `CHROMA_URL` on the hosted function, so retrieval and personal memory are both skipped. Cal answers from the system prompt alone; M1–M3 are inert in production. |
| Five practice categories have no copy | §17 items 5–6, blocked on Dr. Mia. |
| Motivation pool is five lines | It visibly loops within a fortnight (§17 item 15). |
| Reports are device-local | Guideline 1.2 is satisfied, but nothing forwards them to `safety_events`, so you will not see them. |

---

## 5. Upload

The bundle identifier is `org.wholelifeministries.cal`. Register that App ID in
the developer portal and create the App Store Connect record with it **before**
archiving — the identifier cannot be changed afterwards.

Then: **Xcode → Product → Archive → Distribute App → TestFlight**. Xcode handles
signing and upload against the signed-in account, which is why this is not a
command in this file.

`ITSAppUsesNonExemptEncryption` is already `false` in `Info.plist`, so the export
compliance question will not be asked at upload.

**The App Privacy nutrition label must be updated before external testing.** It
was filed as "Data Not Collected", which was true before accounts existed and is
not now. `Cal/PrivacyInfo.xcprivacy` declares email, user ID, user content and
health — Apple compares the two.
