# Plan — Cal speaks

Voice in two places, and they are **not the same feature**. Treating them as one
is the main way this goes wrong, so the split is the first section.

Providers: OpenAI (already integrated, key already server-side) and ElevenLabs
(new vendor, new key, new sub-processor — see §7, which is the part that is not
an engineering problem).

---

## 1. The two features, and why they are different

| | Guided practice | Chat |
|---|---|---|
| What is spoken | Dr. Mia's authored scripts | Cal's generated replies |
| Text known ahead of time? | **Yes — fixed, identical for every student** | No |
| Must work offline? | **Yes.** It works offline today. | No |
| Latency budget | Zero. The audio *is* the pacing. | ~1s to first word |
| Right approach | **Pre-synthesise once, ship/cache the files** | Stream TTS as tokens arrive |
| Cost model | One-off, ~40 lines of text, total | Per reply, per student, forever |

The practice scripts are the same text for everybody, every time. Synthesising
them per playback would spend money and network on a fixed asset, and — worse —
**break the offline guarantee the breathwork player has today**. `BreathHaptics`
already documents the intent: *"a user can close their eyes — or put the phone
face down with the audio running"*. That must keep working at 2am with no signal.

So: **practice audio is a build artifact, not a runtime call.** Chat is the only
place a live TTS request belongs.

---

## 2. Practice audio — pre-rendered

### The pipeline

A script in `tools/`, in the same spirit as `make-cal-asset.py` and
`build-content-corpus.py`: offline-checkable input, deliberate cost, committed
output.

```
tools/render-practice-audio.py
  reads   Packages/CalKit ExerciseScript beats (the authored text)
  calls   ElevenLabs TTS, one clip per beat
  writes  Packages/CalContent/Resources/Audio/<exercise>/<beat-id>.m4a
          plus a manifest.json with durations
```

Per-beat clips rather than one file per exercise. The player is beat-driven
already (`Beat` has `id`, `start`, `duration`), so per-beat lets the existing
monotonic timeline stay the source of truth and the audio follow it. One long
file would make the audio the clock, and then a drift bug becomes a *pacing* bug
in a breathing exercise — the failure `ExercisePlayerModel` is explicitly built
to avoid.

### The check that must exist

`tools/check-practice-audio.sh`, modelled on `check-prompt.sh`: **fail if the
authored beat text has changed but the audio has not.** Dr. Mia's wording is
fixed and preserved verbatim; audio that has silently drifted from the script is
Cal saying something she did not write, in a voice that sounds like hers.

### Timing

The rendered clip will not equal `beat.duration`. Two rules:

- If the clip is **shorter**, play it at the beat's start and let silence fill —
  the pause is part of the practice.
- If the clip is **longer**, that is a **failure**, not something to paper over
  by speeding up audio or stretching the beat. The script fails and the pacing
  gets re-proposed to Dr. Mia (§17 item 5 is still open anyway).

### Cost

Roughly 40 beats across six practices, ~80 characters each ≈ **3,000 characters,
once**. Negligible on any ElevenLabs tier. Re-rendered only when she changes the
words or the voice.

---

## 3. Chat audio — streamed

### Where the key goes

A second Edge Function, `speak`, for the same reason `coach` exists: an `.ipa` is
a zip and a shipped key is one a stranger can spend (§8.1). **Not** folded into
`coach` — different cadence, different failure mode, and a TTS outage must not
take chat down with it.

### Shape

`SpeechClient` in `CalAI`, mirroring `CoachClient` exactly:

```swift
public protocol SpeechClient: Sendable {
    func speak(_ text: String, voice: CalVoice) -> AsyncThrowingStream<Data, Error>
}
```

A protocol so `MockSpeechClient` can be injected and **no test or preview ever
spends money or touches the network** — the rule `-CalUseMockCoach 1` already
enforces for the model. The same flag should silence TTS.

### Chunking

Do not wait for the whole reply. Buffer the token stream to the first sentence
boundary, send that, keep going. First audio in about a second on a reply that
takes four to finish.

Chunk on **sentence** boundaries, not on a character count. Cal's replies are
short and often end in a question — "Would it help to take one slow breath
together?" — and splitting mid-clause produces the wrong intonation on the one
sentence that matters most.

### Optional, and separable: speech *in*

The student talking to Cal is a different feature and should be its own decision:
OpenAI `gpt-4o-transcribe` or Whisper, on-device `SFSpeechRecognizer` as the
offline fallback. **It changes the privacy story much more than TTS does** — see
§7 — because it sends the student's own voice, not Cal's words. Recommend
deferring until TTS has shipped and been used.

---

## 4. Provider choice

Build against the protocol; the answer is a configuration value, not a rewrite.

| | ElevenLabs | OpenAI TTS |
|---|---|---|
| Quality | Better, noticeably so for a calm guided voice | Good |
| Cost | Higher per character | Lower |
| Voice cloning | Yes — see §5 | No |
| Vendors to add | **One new** | **None** — key already deployed |

**Recommended split:** ElevenLabs for practice audio (rendered once, so cost is
irrelevant and quality is permanent), OpenAI for chat (per-reply cost, already
integrated, one fewer sub-processor for the highest-volume path).

That also means chat voice can ship **without adding a vendor at all**, which
makes §7 a much smaller conversation.

---

## 5. The question this plan cannot answer

ARCHITECTURE §17 item 7:

> **Will she record audio in her own voice?** Strongly recommended — the biggest
> differentiator against every other wellness app, and the part no model can
> replace.

That is still open, and **it is a decision about this feature, not adjacent to
it.** Three futures:

1. **She records the practices herself.** Then §2's pipeline is not a TTS script,
   it is an import-and-trim script, and the quality is unbeatable. The player
   work is identical either way.
2. **She licenses her voice to a clone.** ElevenLabs can do this from a short
   sample. Needs her **explicit written consent**, naming the uses — a
   synthesised clinical voice saying things she never said is a real harm and a
   real liability. Do not do this on a verbal yes.
3. **A neutral synthetic voice**, clearly not hers.

**Build for (3) and design so (1) drops in.** Per-beat files with a manifest
means swapping synthesis for her recordings is replacing files, not rewriting the
player. That is the whole reason for the per-beat structure.

---

## 6. Client work

- **`AVAudioSession`** — `.playback` category so the practice keeps running with
  the phone face down and the silent switch on. `.spokenAudio` mode. This is the
  first audio in the app; `ARCHITECTURE.md` §3 already lists AVFoundation for
  "background audio for breathwork" and it has never been built.
- **Interruptions.** A phone call mid-practice must pause and resume, not desync.
  Route changes too — unplugging headphones should pause, not blast a lecture
  hall.
- **Background audio capability** in the entitlements. Currently
  `Cal.entitlements` is deliberately empty, so this is the first entry and worth
  a deliberate decision.
- **VoiceOver.** If VoiceOver is on, the practice cue is already announced by
  `.accessibilityAddTraits(.updatesFrequently)`. Speaking it *as well* means two
  voices over each other. **Suppress Cal's TTS when `UIAccessibility.isVoiceOverRunning`** —
  the screen reader wins; it is the user's chosen voice.
- **Haptics.** `BreathHaptics` already paces the breath. Voice plus haptics plus
  the ring is three channels saying one thing; verify it is grounding rather than
  busy, and offer voice/haptics independently in Settings.
- **A real off switch.** Voice must be optional and off by default in chat.
  Someone opens a wellness app in a library.

---

## 7. Privacy — a specific sentence becomes false

`CalKit.MemoryConsent.sharingNote` currently reads:

> We do not sell this or share it with advertisers or analytics companies. It is
> processed by **the AI provider that generates Cal's replies, and by nobody
> else.**

Add ElevenLabs to the chat path and **that sentence is untrue.** Consequences,
all of which are cheap now and expensive after shipping:

- **Update the wording** and bump `MemoryConsent.currentVersion` past
  `memory-v1`. `isActive` checks the version, so a bumped version correctly
  re-asks — which is the right behaviour when the set of processors changes, and
  is exactly why that version field exists.
- **`PrivacyInfo.xcprivacy`** — TTS of Cal's replies adds no new *category* (user
  content is already declared). **Speech input would**: audio data, and voice is
  biometric-adjacent under several state regimes. Another reason to defer STT.
- **Update `docs/LAUNCH-REQUIREMENTS.md` §18** — a second AI sub-processor
  changes the vendor-agreement answer, which is already gated on the unresolved
  PHI question.

**The mitigation worth stating:** TTS sends **Cal's words, not the student's**.
The reply is already the model's output. That is a materially smaller disclosure
than "we send your journal to a second company", and it should be said plainly
rather than buried.

Choosing OpenAI for chat TTS (§4) avoids all of the above — same processor,
sentence stays true, no version bump.

---

## 8. Cost

Chat replies cap at 400 output tokens ≈ 1,600 characters, and Cal's are usually
far shorter — call it **250 characters spoken per reply**.

| | Per 1,000 replies |
|---|---|
| OpenAI TTS | cents |
| ElevenLabs | dollars, roughly an order of magnitude more |

Neither is the point. **The point is that there is still no budget enforcement,
no rate limit and no kill switch** — the `coach` function's own header says so,
and §10's controls remain unbuilt. Voice multiplies the cost of every message
while that is true, and the endpoint is public.

**Build the budget controls before or with this, not after.** That has been
deferrable while chat was text; it stops being deferrable when every reply also
buys audio.

---

## 9. Order

1. `AVAudioSession`, background capability, interruption and route handling —
   no vendor, no key, and it is the part that breaks in ways users feel.
2. Practice audio pipeline with a neutral voice + the drift check. Offline, and
   the highest-value half.
3. Ask Dr. Mia §5. Everything after this is cheaper once answered.
4. `SpeechClient` + `MockSpeechClient` + the `speak` function; chat voice off by
   default.
5. Budget controls (§8) — not optional by this point.
6. Speech input, if wanted, as its own decision with its own consent change.

Steps 1 and 2 need no new vendor, no new key, and no privacy change. Step 4 is
where §7 lands, and choosing OpenAI there keeps it small.
