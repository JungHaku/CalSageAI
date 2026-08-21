# Plan — Cal answers when you open the app

> **Shell superseded.** §1 / §5 / §9 step 2 (“five tabs gone”, Cal as the only
> root) are replaced by [`PLAN-cal-sage-shell.md`](PLAN-cal-sage-shell.md): the
> tab bar returns with Cal Sage AI as the raised middle orb. Keep this doc for
> §3 tools, §7 safety, and §8 privacy/cost.

The app stops being five tabs with a chat in one of them and becomes a
conversation that can open screens. You launch it, Cal is listening, and every
other surface in the app — check-in, breathwork, the map, the planner — is
somewhere Cal takes you rather than somewhere you navigate to.

ElevenLabs owns the whole spoken loop (mic, STT, turn-taking, LLM, TTS). The
`coach` function stays for typed chat. Practice narration is live agent voice on
the app's timeline (§6), not pre-rendered assets. §8 records the privacy and
cost consequences so they are decisions on the record.

**Status: demo.** Every feature stays unlocked, metering is deferred, and §8's
privacy work is listed but not gated on. Nothing here is safe to put in front of
a student who is not in the room with us.

Build order for going live: `PLAN-voice-implementation.md`.

---

## 1. Decisions taken

| Question | Answer |
|---|---|
| What ElevenLabs does | **Everything.** Mic, STT, turn-taking, barge-in, the LLM, TTS. |
| The five tabs | **Superseded** — see `PLAN-cal-sage-shell.md`. (Was: gone; Cal is the root.) |
| Who moves the screen | **Cal**, via client tools, mid-sentence. |
| Practice narration | **Live agent voice**, not build artifacts. |
| Crisis detection | **`CrisisDetector` client-side**, on ElevenLabs' transcript events. |
| No mic / no network | **Blocking state.** Online-only, degrade loudly. |
| Free vs premium | **Everything on**, for the demo. Revisit before anyone else uses it. |

Two things nobody has ruled on, assumed here and flagged so they can be
reversed cheaply:

- **Emergency** keeps its one-tap guarantee (`ARCHITECTURE.md` §9.2 Layer D) as a
  persistent affordance on the voice root, carried into every pushed screen —
  see §5.
- **Dr. Mia has not seen this.** The five tabs are her spec §1, and §4 changes
  who assigns the numbers that drive streaks, trends and the premium pitch. This
  plan assumes we build it and show her, not that it is approved.

---

## 2. The agent is a checked-in artifact

There is no agent yet. Creating one by clicking around the ElevenLabs dashboard
makes Cal's clinical voice a thing that lives on a web page nobody can diff, and
`docs/PROMPT-cal.md` becomes decorative — the prompt in the repo would no longer
be the prompt Cal uses.

So the agent is a file, and the dashboard is an output:

```
elevenlabs/agent.json          the whole agent: prompt, voice, tools, turn config
tools/sync-agent.sh            pushes agent.json to the ElevenLabs API (create or update)
tools/check-agent.sh           fails if PROMPT-cal.md changed and agent.json did not
```

This is exactly the shape `tools/sync-prompt.sh` and `tools/check-prompt.sh`
already establish for the `coach` function, for the same reason. `check-agent.sh`
runs in the same place `check-prompt.sh` does.

`agent.json` composes its system prompt **from `docs/PROMPT-cal.md`** plus a
voice-specific addendum — spoken replies want shorter sentences and no markdown,
and Cal currently emits markdown that `CoachMarkdown.swift` renders. The
addendum is the diff, not a second copy of the prompt.

### What moves, and what does not

| Today | Under the agent |
|---|---|
| `PROMPT-cal.md`, injected by `coach/prompt.ts` | `agent.json` prompt, synced from the same file |
| Corpus retrieval (`coach/retrieval.ts`, Chroma) | Agent tool → webhook → the same retrieval code |
| Coherence digest (`ChatViewModel.digest()`) | Client tool `get_today_status`, §3 |
| Memory (`coach/memory.ts`, M3) | Agent tool → webhook → the same memory code |
| `CrisisDetector`, on-device, pre-send | **Still on-device — but post-hoc.** §7 |
| `MAX_OUTPUT_TOKENS = 400` blast radius | **Nothing equivalent.** §8 |

The `coach` function does **not** get deleted. It stays as the brain for typed
chat, and its retrieval and memory modules become the bodies of the agent's
server webhooks. What it stops being is the thing that generates spoken replies.

---

## 3. Client tools — how Cal drives

A new package, `Packages/CalVoice`, holding the session and the tool layer.

```swift
public protocol VoiceSession: Sendable {
    func connect() async throws
    func disconnect()
    var events: AsyncStream<VoiceEvent> { get }
}

public enum VoiceEvent: Sendable {
    case connected, disconnected
    case userTranscript(String, isFinal: Bool)
    case agentTranscript(String, isFinal: Bool)
    case agentSpeaking(Bool)
    case toolCall(CalTool, id: String)
    case failed(VoiceFailure)
}
```

A protocol, so `MockVoiceSession` exists and **no test or preview ever opens a
microphone, a socket, or a billing line**. `-CalUseMockCoach 1` silences this
too; UI tests run against a scripted event sequence.

### The tools

| Tool | Does | Writes data? |
|---|---|---|
| `get_today_status` | Returns the `CoherenceSummary` digest | no |
| `start_check_in(kind)` | Opens the check-in surface, begins a `CheckInFlow` | no |
| `record_score(category, value, phase)` | Records one `before`/`after` rating | **yes** |
| `complete_check_in` | Sets `completedAt`, persists | **yes** |
| `play_practice(slug)` | Pushes `ExercisePlayerView`, starts the timeline | no |
| `stop_practice` | Ends it early | no |
| `show_place(query)` | Pushes the map, runs the existing search, selects a result | no |
| `open_screen(id)` | History, analytics, practices, planner, settings | no |
| `end_session` | Hangs up | no |

`get_today_status` is not optional. `PROMPT-cal.md` forbids inventing a number,
and `ChatViewModel.digest()` is currently the only reason that rule holds — it
hands Cal the real streak and the real averages. An agent with no equivalent will
make numbers up, confidently, in a voice, about the student's own mental health.
**Ship this tool before the demo, not after.**

`show_place` calls into `PlaceSearching`, which already has the substring-then-
semantic fallback `NavigateView` uses. Cal gets the same search the user does.

### Execution

Tools run on the `@MainActor` against a `VoiceRouter` that owns a
`NavigationPath`. A tool call mutates the path; SwiftUI does the rest. The tool
result returned to the agent is a short factual string — `"opened 4-7-8"`,
`"no place matched 'the gym'"` — so Cal can talk about what just happened
instead of narrating a plan and then failing silently.

Every tool is a value type with a `Codable` payload and a pure `execute`
signature, so the mapping from agent JSON to app effect is unit-tested without a
simulator. The one thing that must not be discovered at demo time is Cal saying
"let's breathe together" while nothing moves.

---

## 4. The check-in becomes a conversation

Cal asks the questions out loud and calls `record_score` with the number.
`CheckInFlow` stays the state machine — it is pure logic with no UI already, and
its tests are the reason the regulate-then-re-rate loop is trustworthy. What
changes is who advances it: the agent, through tools, instead of a tap.

The screen still exists. It renders `flow.step` and the score as Cal records it,
so the student can see what is being written about them. It is a mirror, not an
input.

**Three things this puts at risk, and what holds them.**

1. **An LLM is now assigning the numbers that feed streaks, trends and
   `AnalyticsView`.** `record_score` takes a `Score`, which is already a
   validated type — reject out-of-range values at the tool boundary and make Cal
   re-ask rather than clamping. A silently clamped 11 is a wrong number in the
   student's history forever.
2. **The regulation threshold is policy, not vibes.** `RegulationPolicy` decides
   when a low score routes into breathing, and it differs by tier. The agent must
   not decide this. `record_score` returns the next step — `"regulate: 4-7-8"` or
   `"next: breath"` — and Cal follows what the state machine says. That keeps
   Dr. Mia's spec in Swift where it is tested, not in a prompt where it is not.
3. **Ten categories is a long conversation.** The full check-in is ten
   rate-regulate-rerate loops. Spoken, that is not two minutes. Worth watching in
   the demo and worth telling Dr. Mia if it turns out the framework does not
   survive being said out loud.

---

## 5. What the root screen is

`RootView` loses the `TabView` entirely and becomes `VoiceRootView`:

- Cal, large, with a state that reads at a glance — listening, thinking,
  speaking. `CalAvatar` and the brand work from the last commit is the material.
- A live transcript, scrolling, because a voice-only interface is unusable to
  anyone who cannot hear it and unverifiable to everyone else.
- **Keyboard affordance** — tap to type instead. This routes to the existing
  `ChatView` path against `coach`, unchanged.
- **Emergency**, persistent, fixed corner, red, `emergency-button` identifier
  preserved. It was a toolbar item on all five tabs; with the toolbar gone it
  needs a home that does not depend on Cal working. It must open `EmergencyView`
  when the socket is dead, the mic is denied, and Cal is mid-sentence.
- **A menu**, small, for the destinations Cal can reach — so a student who does
  not want to talk to anything today can still get to their history and their
  settings. "Tabs gone" is a decision about the default, not a decision to trap
  anyone.

### Degrading loudly

Online-only was chosen, so the failures must be legible rather than a spinner:

| Condition | What the person sees |
|---|---|
| Mic permission denied | Cal explains, offers typed chat, offers Settings |
| No network | A stated "Cal needs a connection" — not a retry loop |
| Socket drops mid-session | Reconnect once, visibly; then stop and say so |
| Agent errors / quota | Authored copy in Cal's voice, not an error code |

The one thing that must never be behind a network check is Emergency.

---

## 6. Practice audio — live, but the clock stays ours

Live agent voice was chosen over pre-rendered files. That is fine for the voice,
and dangerous for the pacing, and those can be separated.

**Do not let the agent freewheel the narration.** `ExercisePlayerModel` runs a
monotonic timeline because a drift bug in a breathing exercise is a *pacing* bug —
the user is matching their breath to it with their eyes closed. If the agent
decides when to say "breathe out", then model latency, a retry, or a long
inhale token becomes a physically wrong instruction.

**Synthesise at practice start, play on the existing timeline.** When
`play_practice` fires, request TTS for every beat in the script up front, hold
the clips in memory, and fire them on the beat boundaries `ExercisePlayerModel`
already computes. Same voice as Cal, no committed audio assets, no build
pipeline — and the timeline is still the source of truth.

That pays one latency cost, at the start, where a two-second "let's begin" is
natural anyway. Roughly 40 beats × ~80 characters across six practices; a single
practice is a few hundred characters.

Still required for practice audio:

- `AVAudioSession` `.playback` / `.spokenAudio`, so a face-down phone keeps
  going. This is the first audio in the app.
- Interruption and route-change handling. A phone call must pause and resume,
  not desync. Headphones out must pause, not broadcast.
- Background audio in `Cal.entitlements`, currently empty by choice.
- **Suppress Cal's speech when `UIAccessibility.isVoiceOverRunning`.** VoiceOver
  already announces the cue; two voices over each other is worse than one.
  Voice-first plus VoiceOver is a real combination and it needs deciding, not
  discovering.
- Voice and haptics independently switchable.

Consequence of live narration over committed per-beat files: **the breathing
exercise no longer works offline**, which it does today. That is the price of
the choice and it is worth restating once here.

---

## 7. Safety

`CrisisDetector` stays exactly as written — same patterns, same
`CrisisFixture.all` regression suite, same pending clinician sign-off. It moves
from "runs before the message is sent" to "runs on the `userTranscript` events
ElevenLabs streams down".

```
VoiceEvent.userTranscript(text, isFinal: true)
  → CrisisDetector.evaluate(text)
  → .acute:  interrupt the agent, mute output, present EmergencyView
  → .elevated: surface resources alongside; let Cal keep talking
```

**Interrupt, do not overlay.** On `.acute` the current behaviour is that the
model is suppressed entirely (`ChatViewModel.handle`, §9.2 Layer D). The voice
equivalent is cutting the agent's audio, not showing a card over the top of Cal
cheerfully continuing. The session-level interrupt has to be wired and tested
with a scripted `MockVoiceSession` transcript, because this is the one path
nobody gets to debug live.

**Be honest about what was lost.** On text, detection ran *before* anything was
sent — nothing could be generated in response to a crisis disclosure. On voice,
detection runs on a transcript that the agent has already received, so Cal may
have begun replying. The gap is a fraction of a turn, and it is not zero.

Two mitigations, both cheap, neither chosen yet:

- Act on `isFinal: false` partials for the acute patterns only. Earlier trigger,
  more false positives, and the cost matrix is already asymmetric in that
  direction by design.
- Put a safety clause in the agent prompt as well. It costs nothing, it is not
  testable, and it is not a substitute — but "untested second layer" beats
  "no second layer" when the first one is provably late.

`safety_events.matched_rule` still gets written, so the weekly review with
Dr. Mia sees why something fired. That reporting path must not go through the
agent.

---

## 8. What this costs, stated plainly

### The consent sentence is now false

`MemoryConsentCopy.sharingNote` promises:

> It is processed by the AI provider that generates Cal's replies, and by nobody
> else.

Under this plan the student's **voice** goes to ElevenLabs. Not Cal's words —
theirs. That is a bigger change than adding TTS, and it was deferred until this
plan made it unavoidable.

Required before anyone outside the room uses this:

- Rewrite `sharingNote` and bump `MemoryConsent.currentVersion` past `memory-v1`.
  `permitsRemoteMemory` checks the version, so a bump correctly re-asks — which
  is the whole reason that field exists.
- `PrivacyInfo.xcprivacy`: audio data. Voice is biometric-adjacent under several
  state regimes, which is a different conversation from "user content".
- `NSMicrophoneUsageDescription` and `NSSpeechRecognitionUsageDescription`.
- `docs/LAUNCH-REQUIREMENTS.md` §18 — a second AI sub-processor, on the highest
  volume path, handling voice.
- `ARCHITECTURE.md` §18 decision log.

### There is still no budget control

`coach/index.ts` caps a single reply at 400 output tokens — a blast radius, not
a budget. **The agent has no equivalent.** A live session bills per minute and
has no natural end; an open socket in a pocket is a bill.

For the demo: a hard client-side session timeout, and a signed-URL Edge Function
(`voice-token`) rather than a public agent ID — same argument as §8.1, an `.ipa`
is a zip, and a public agent ID is one a stranger can talk to for as long as they
like. That is thirty lines and it is the difference between a demo and an open
tap.

### The tests

All six files in `CalUITests/` drive the tab bar — 32 references. They do not
adapt; they get rewritten against the voice root. `LayoutRegressionTests`,
`ScreenshotTests`, `AccessibilityAuditTests` and `DynamicTypeTests` all need new
entry points, and the accessibility audit matters *more* here, not less: a
voice-first interface has to prove it works for someone who cannot use voice.

`CalKit` tests are untouched. `CheckInFlow`, `CrisisDetector`, `StreakCalculator`
and the rest keep holding, which is the argument for §4 leaving the state machine
alone.

---

## 9. Order

1. **`CalVoice` package** — `VoiceSession`, `VoiceEvent`, `CalTool`,
   `MockVoiceSession`. No vendor, no key, fully testable. The tool layer and the
   router are the actual architecture; the socket is a detail.
2. **`VoiceRootView`** against the mock. Transcript, Cal's states, Emergency,
   typed-chat escape hatch, the loud failure states from §5. The whole redesign
   is visible and demoable before a single billable second.
3. **`elevenlabs/agent.json` + `sync-agent.sh` + `check-agent.sh`**, and the
   `voice-token` function. Create the agent from the file, never the dashboard.
4. **Real session.** Wire `ElevenLabsVoiceSession`, connect the tools, hold
   `get_today_status` as a launch blocker so Cal cannot invent numbers.
5. **Safety on transcripts** (§7), with the interrupt path tested against a
   scripted mock. Not after the demo.
6. **`AVAudioSession`, interruptions, background capability** (§6). This is what
   breaks in ways people feel.
7. **Practice narration** — synthesise-at-start on the existing timeline.
8. **Conversational check-in** (§4) — last, because it writes data and it is the
   one that needs Dr. Mia.

Steps 1–2 need no vendor, no key and no privacy change, and they are where the
design question actually gets answered. Step 3 is the first dollar.
