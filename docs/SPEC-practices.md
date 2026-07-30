# SPEC — Cal Guided Coherence Practices (verbatim)

> Source: Dr. Mia, received 2026-07-30. **Working title only** — she has asked that
> the final section be renamed later.
>
> Her instruction: *"The text below is intentionally preserved in full without
> condensation."* This file is therefore the authoritative wording. Do not edit,
> shorten, or paraphrase it. Any change comes from her.
>
> These five are **library practices** from the Premium Guided Library list in
> [`SPEC-premium.md`](SPEC-premium.md). They are **not** the ten per-category
> regulation exercises, which are still outstanding — see ARCHITECTURE.md §20.

---

## Cal Guided Coherence Practices (Working Title)

Note: Working title only. User requested that the final section be renamed later. The
text below is intentionally preserved in full without condensation.

### 1. Microcosm → Macrocosm Breath

**Purpose:** Expand awareness beyond the self and cultivate a sense of connection.

Cal says:

Close your eyes and breathe slowly.

As you inhale, imagine your nervous system as a tiny universe—a living microcosm
filled with light, intelligence, and possibility.

As you exhale, allow that light to expand beyond your body...

Filling the room...

Flowing beyond the walls...

Expanding into the vast universe—the macrocosm.

With every breath, remember:

The light within you is not small or separate. It is connected to something infinitely
greater.

Rest in that feeling for several slow breaths.

### 2. Golden Spark Visualization

**Purpose:** Shift attention from stress toward inner vitality.

Cal says:

Close your eyes.

Notice the stillness between each inhale and exhale.

In the center of your heart, imagine a tiny golden spark.

With every breath, watch it become brighter...

Growing into a warm golden flame.

Allow this light to gently dissolve tension...

Releasing fear...

Softening old patterns...

Let the golden light spread through your chest...

Into your spine...

Through your arms...

Your abdomen...

Your legs...

Until your entire body feels surrounded by a quiet golden glow.

Rest here for a few breaths.

### 3. Presence of Light

**Purpose:** Cultivate presence and inner stillness.

Cal says:

For the next few moments, don't search for answers.

Simply experience being.

Slowly repeat:

I am here.

I am whole.

I am light.

After each phrase, notice what happens inside your body.

Does your breathing soften?

Does your chest feel more open?

Do you notice even the smallest feeling of peace or expansion?

There is nothing to force.

Simply allow yourself to experience this moment exactly as it is.

### 4. Solar Plexus Light

**Purpose:** Strengthen feelings of agency, confidence, and embodied awareness.

Cal says:

Place one hand over your solar plexus, just above your navel.

Feel the warmth beneath your hand.

Imagine a radiant sun shining there.

With each inhale, its light becomes brighter.

With every exhale, that light travels throughout your nervous system...

Flowing through your chest...

Down your spine...

Into your shoulders...

Arms...

Hands...

Legs...

Feet...

Illuminating every cell.

As you breathe, quietly repeat:

The light I seek already lives within me.

Rest in that awareness.

### 5. Sovereignty Reflection

**Purpose:** Reduce unnecessary struggle and return to inner steadiness.

Cal says:

Take one slow breath.

Ask yourself:

What can I let go of right now so my inner light can shine more freely?

Wait quietly for whatever arises.

It may be a fear...

A need to be right...

A resentment...

A worry...

Or simply the urge to keep fighting.

You don't need to solve anything in this moment.

Simply notice it.

Breathe.

Then choose peace over struggle.

Allow yourself to return to the quiet strength already within you.

---

## Implementation notes (ours, not hers)

**The wording is fixed; the pacing is not yet.** Each practice is prose with `...`
marking a pause, but no durations are given. Turning these into playable
`ExerciseScript` timelines means assigning a number of seconds to every line and
every pause — and pacing a breath practice is a clinical decision, not a
formatting one. Read too fast and it becomes stressful; too slow and people
abandon it. **We will propose timings and she must approve them before launch.**
See ARCHITECTURE.md §20.

**Structural read of each practice**, for mapping onto the step model:

| # | Practice | Shape | Proposed category default |
|---|---|---|---|
| 1 | Microcosm → Macrocosm Breath | paced breath + expanding visualisation | `connection` |
| 2 | Golden Spark Visualization | free breathing + progressive body visualisation | `emotional_flow` |
| 3 | Presence of Light | spoken affirmation with pauses to notice | `presence` |
| 4 | Solar Plexus Light | hand placement + paced breath + affirmation | `energy` |
| 5 | Sovereignty Reflection | question + silent wait + choice | `choice` |

Practices 2, 3, and 5 are **not breath-paced** — they are guided attention with
silences. The step model already supports this (a `cue` step has a duration but no
breath instruction and fires no haptic), so they play correctly without a
breathing ring driving them. Practices 1 and 4 are breath-paced and use the ring.

**Categories still without a practice:** `safety`, `breath`, `body_awareness`,
`inner_knowing`, and `authentic_expression`. The free tier's `overall` has only the
labelled placeholder. Those are the outstanding per-category regulation exercises.

**Status:** all five are implemented as playable scripts in
`Packages/CalContent/Sources/CalContent/Resources/content.json`.

**Only her wording is used.** Long instructional lines became spoken `cue` steps;
unworded breath beats carry the pacing. Nothing was reworded, shortened, or added.
Where a line reads as an instruction *about* breathing rather than a breath
instruction itself ("As you inhale, imagine your nervous system as a tiny
universe…"), it is a cue followed by an actual breath beat — a literal ten-second
inhale is not comfortable, and that mismatch is why pacing needs her eye.

### Proposed timings — for Dr. Mia to approve

| Practice | Runtime | Beats | Longest breath |
|---|---|---|---|
| Microcosm → Macrocosm Breath | 1:58 | 21 | 7s |
| Golden Spark Visualization | 1:56 | 21 | 6s |
| Presence of Light | 1:22 | 12 | — (no paced breath) |
| Solar Plexus Light | 2:02 | 23 | 7s |
| Sovereignty Reflection | 1:45 | 16 | 7s |

Sovereignty Reflection holds a **12-second silence** after "Wait quietly for
whatever arises" — the longest pause in any practice, and the one most likely to
need tuning either way.

A test asserts no breath beat exceeds 10 seconds and every practice runs between
30 seconds and 10 minutes, so a future timing edit can't quietly become
uncomfortable.
