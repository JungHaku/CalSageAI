# Plan — WholeLife brand, Cal the character, and finishing the chatbot

Three efforts, in dependency order. Phases 1–3 are visual and can ship without a
backend. Phases 4–5 are the chatbot, and 5 depends on 4.

Decisions already taken (2026-08-03), so they are not re-litigated below:

- **Slate is the interactive colour. Sage and gold are identity only.** See §1.
- **The Cal artwork is recoloured to brand and loses the Berkeley script.** See §2.
- **WholeLife Ministries Inc. is the entity behind the app**, replacing Breathe
  Health Center in every document that names one. See §6.

---

## 1. Brand tokens

`CalDesign` already owns every colour the app draws, and `ContrastTests` already
measures every ink against every surface it lands on. So this is an addition to a
system, not a new system.

### The collision this avoids

`CoherenceScale` is not decoration. Green means *high coherence*, amber means
*moderate*, red means *low* — a student learns that scale in their first week. The
WholeLife palette is sage green and gold, which are the same two hues. Making sage
the button colour would mean every primary action reads as "moderate", and green
chrome would compete with "you are regulated".

So the brand green and gold are confined to surfaces that carry **identity** and
never **state**: headers, the Cal avatar and its halo, empty states, dividers, the
paywall. Interaction takes the logo's slate, which is close enough to the bear's
trousers that the two assets reconcile rather than fight.

The three band hues are left exactly as they are. They are tuned to *separated*
luminance — roughly 9.0, 6.4 and 4.6 against the card — specifically so they
survive greyscale, print, and red-green colourblindness. Retuning them to be more
on-brand would undo that, and a test would catch it, correctly.

### New file: `Packages/CalDesign/Sources/CalDesign/Brand.swift` ✓ Built

Final values, after measuring. Two of the proposals did not survive contact with
`Contrast` — noted below, because the reasons are the useful part.

| Token     | Light     | Dark      | Role                                          |
|-----------|-----------|-----------|-----------------------------------------------|
| `slate`   | `#414D5C` | `#A8B6C8` | **Interactive.** Buttons, links, tab selection.|
| `sage`    | `#5C8A75` | `#8FBFA8` | Meaningful fills. Clears 3.0:1 everywhere.    |
| `sageInk` | `#45705C` | `#8FBFA8` | Text-safe sage. Headers, wordmarks.           |
| `gold`    | `#C9A24B` | `#D9B96B` | **Decorative only** — haloes, hairlines.      |
| `goldInk` | `#7E6220` | `#D9B96B` | Text-safe gold.                               |

**`cream` was dropped.** The logo's off-white `#F7F4EC` measures **1.029:1**
against the existing `Surface.cardLight` (`#F2F1EC`) — the same colour. The card
surface was already chosen warm for the same reason the logo is, so a third
near-identical off-white would be weight with nothing behind it. A test asserts
the redundancy so the token is not reintroduced by someone eyeballing the logo.

**`gold` cannot carry meaning.** At the logo's exact value it measures 2.40:1 on
the app background — below the *non-text* 3.0:1 of WCAG 1.4.11, not merely below
the text threshold. So it is confined to haloes and hairline dividers, which the
spec exempts, and `goldInk` exists for when gold must be read. The same fill/ink
split `CoherenceScale` already uses, for the same reason.

**The logo's sage also failed** as a meaningful fill — `#6B9B85` measures 2.79:1
on a card. `sage` is the darkened value that clears 3.0:1 on every surface in both
modes.

### Also in this phase ✓ Built

- **`AccentColor.colorset` populated** with slate light / dark. It was
  `{ "idiom": "universal" }` with no colour in it, so every unstyled control in
  the app had been rendering system blue.
- **`Surface.allTextPairings`** — the neutral pairings plus `Brand.textPairings`,
  and what `ContrastTests` now iterates. Two lists, one entry point, so adding to
  either is enough.
- **Five new assertions** in a `Brand` suite, including the negative ones: that
  gold fails the non-text threshold, that the sage/band collision is real
  (1.23:1 and 1.30:1), and that slate stays ≥2.0:1 from every band fill so a
  button never reads as a score.

**Done:** 21 tests pass in 4 suites; `xcodebuild build` succeeds. No view touched.

---

## 2. Cal, as an asset

### The artwork

The downloaded image is a 1240×1240 transparent PNG, 1.6 MB — a meditating bear in
a Berkeley-script "Cal" hoodie and navy trousers.

The script comes off. The README already lists *"Rights to 'Cal' and Berkeley
marks, or a rename"* as a launch blocker, and Berkeley's mascot is a bear, so a
cartoon bear wearing their wordmark is the most exposed asset in the project.
Recolouring also resolves the palette clash for free: navy is foreign to the
WholeLife scheme, slate is not.

Regenerating is cleaner than editing. Removing the script by hand means inpainting
navy lettering that overlaps the drawstrings and the mala beads. One more
generation with the hoodie specified blank costs a prompt and produces a better
result than any filter.

Until the new file exists, the current image is wired in as a placeholder. Every
use site goes through one view, so replacing it is dropping in an asset.

### The download had no transparency at all

Worth recording, because it will recur on every regeneration.

The file was **1254x1254 in RGB mode with no alpha channel**. The transparency
checkerboard was not a viewer's backdrop — it was baked into the pixels as
literal alternating `#F1F1F1` and `#FEFEFE` squares. Dropped into the asset
catalogue as downloaded, Cal would have rendered sitting on a grey checkerboard,
and it would have read as a rendering bug rather than as a bad export.

So the repair is a committed script, `tools/make-cal-asset.py`, not a one-off.
It recognises the background by two properties that must both hold:

1. **Neutrality** — the checker's channels are within 2 of each other; the cream
   hoodie is warm and spreads about 20. Colour alone would have eaten the hoodie,
   which is only 29 apart from the light checker square in blue.
2. **Connectivity** — the fill starts at the four corners and spreads only
   through neighbouring background, so an enclosed cream region is unreachable
   even if it passed the colour test. Cal's continuous dark outline is what makes
   that hold.

Edges are then feathered, because a hard binary mask leaves the original
antialiased pixels — which are blends of ink *and checker* — fully opaque, and
that shows up as a pale fringe against a dark background.

### The work ✓ Built

- **`Media.xcassets/Cal.imageset`** in `CalDesign`'s own resources at 1x/2x/3x
  (200/400/600px), 519 KB on disk. Inside an `.xcassets`, not beside it: a bare
  `.imageset` is copied into the bundle verbatim and `Image(_:bundle:)` resolves
  names only against a catalogue compiled by `actool`. Xcode compiles it to a
  273 KB `Assets.car` in the app — smaller than the source, and a fifth of the
  1.6 MB original.

  Note that plain `swift build` on macOS **copies** the catalogue rather than
  compiling it, so `Bundle.module` has no `Assets.car` there. That does not
  affect the app or the tests, but it means a package-only preview will not find
  the image.

- **`CalAvatar`** — four named sizes (`bubble` 28, `inline` 44, `card` 96,
  `hero` 180), three halo options, and decorative-by-default accessibility.
  Two decisions inside it:

  *VoiceOver.* The bubble avatar repeats once per assistant message, so a
  labelled one would announce Cal between every reply in a scrolled thread.
  Decorative is the default; a label is opt-in.

  *Dynamic Type.* Scaling is a property of the size, not a blanket rule. The
  bubble and inline sizes follow the text beside them or they become specks at
  AX5; the card and hero sizes are fixed, or a 180pt hero at 2.4x evicts the
  screen it introduces. The scaling sizes are capped at 1.6x.

- **Placement.** Assistant chat bubbles (top-aligned, so the avatar sits level
  with the reply's first line), a new empty-chat state, the Home greeting, and
  the breathwork player.

  In the player Cal sits **inside** the ring and deliberately does not breathe
  with it. The ring's scale is the instruction — it is how the exercise is
  followed without reading — so it must stay the only moving thing on screen.
  He is a still point at the centre, which is also what the pose is of. The
  `scaleEffect` and its animation are untouched and still apply only to the
  circle; nothing here goes near the timing.

- **Not done:** `AppIcon.appiconset` is still the placeholder. Worth generating
  once the recoloured artwork exists rather than twice.

---

## 3. Restyling the surfaces

Apply the tokens to `HomeView`, `ChatView`, `CheckInView`, the `RootView` tab bar,
and `PaywallView`.

Re-run `LayoutRegressionTests`, `AccessibilityAuditTests`, and `DynamicTypeTests`.
Note that the audit's contrast check is known-unreliable in this project — it
reported "Contrast failed" on pure black at 18.57:1 — which is exactly why the
computed `ContrastTests` from §1 is the check that matters here.

---

## 4. Supabase, for real

ARCHITECTURE §15, restricted to what the chatbot needs.

1. **Run what is already written. ✓ Done, and it passes.** `supabase start &&
   supabase db reset && supabase test db` — the first time any of it had been
   executed. **32 pgTAP tests pass across both files.** The migrations apply
   cleanly (a few idempotency NOTICEs, no errors), the seed loads, and the RLS
   and isolation invariants hold. This was the cheap gate before touching a real
   project, and the schema cleared it.
2. **Hosted project. Partly done.** The project exists — `CalAI`,
   ref `woudmxksrkrzjnmlfven`, us-east-1, Postgres 17.6.1 — and
   `supabase link` has been run. `supabase db push` remains, and must be run by
   someone who can supply `SUPABASE_DB_PASSWORD`.

   **`supabase db reset --linked` must never be run against this project.** Reset
   loads `seed.sql`, which writes directly into `auth.users`. `db push` applies
   migrations only and does not seed — that is the one that is safe here.
3. `supabase secrets set OPENAI_API_KEY=...` — **must be run by a human with the
   key.** It does not go in a file, a commit, or a message.
4. `supabase functions deploy coach`.
5. **Decide on Chroma.** Retrieval degrades gracefully with `CHROMA_URL` unset —
   the function behaves exactly as it did pre-M1 — so shipping without it is a
   real option. Hosted Chroma is a second vendor and a second bill. Local Docker
   works today and is enough for development.

`seed.sql` writes directly into `auth.users`. Local only. Never staging, never
production.

---

## 5. Finishing the chatbot

The architecture is done. What is missing is wiring and durability. Each item
below is a specific gap, with where it lives.

**Configuration**

- The endpoint is hardcoded to `http://127.0.0.1:54321` (`Cal/CalApp.swift:226`,
  and again in `LiveCoachClient.local()`). It needs to come from build
  configuration: Debug → local stack, Release → the hosted project.
- The live coach is opt-in behind `-CalLiveCoach 1`. That default was correct when
  a real model meant a surprise bill during a test run; it becomes wrong once the
  product ships. Live by default in Release, mock everywhere in tests — the
  existing `-CalUseMockCoach 1` already wins over everything and should keep doing
  so.

**Durability**

- **Conversations do not survive.** `ChatViewModel` holds `messages` in memory and
  mints a fresh `threadID` each time the view loads, so leaving the tab discards
  the thread. `chat_threads` and `chat_messages` exist in the schema and nothing
  writes to them. Local persistence first (SwiftData, matching the existing
  stores), sync second.
- **Usage is thrown away.** `ChatViewModel.swift:150` handles `.finished` by
  ignoring its `CoachUsage` payload, and nothing anywhere writes `ai_usage`. §10.4
  argues for cost-per-active-user on a dashboard in week one rather than on an
  invoice in month three; today there would be no dashboard. The function has the
  numbers and already sends them — they just need catching and storing.

**Deferred, deliberately, but needs a decision**

- Per-user budgets, the kill switch, prompt versioning, and the server-side
  classifier (§9.2 Layer B). The function's own header admits none of these exist.
  Shipping half a budget system is worse than shipping none, so the question is
  whether the first real bill or the first real student comes first.

---

## 6. Documents that are now wrong

WholeLife Ministries Inc. is the entity. These name Breathe Health Center and need
updating — not cosmetically, because the entity determines legal obligations:

- `ARCHITECTURE.md` §17 — including whether Cal is part of clinical care, which
  decides whether the data is PHI and therefore what vendor agreements Phase B
  needs.
- `docs/LAUNCH-REQUIREMENTS.md` — App Store guideline **5.1.1(ix)** requires a
  healthcare app to ship from the legal entity providing the service. The Apple
  Developer *organization* account and the pending D-U-N-S number must now be
  WholeLife's, not BHC's.
- `docs/APP-STORE.md` — seller name, privacy policy URL, support URL.
- `README.md` — the opening line, and blocker #4 on the Berkeley marks, which §2
  above partially resolves.

---

## Order of work

§1 → §2 → §3 can proceed immediately and independently of any backend.
§4 → §5 is the chatbot and needs the hosted project and the API key.
§6 can happen at any point and touches no code.
