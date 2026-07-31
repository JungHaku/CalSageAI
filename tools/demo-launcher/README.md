# Demo launcher

Builds `Cal Demo.app` — a double-clickable launcher that boots a simulator,
builds the current source, installs, and launches with seeded data.

```bash
./tools/demo-launcher/build.sh
```

Puts `Cal Demo.app` on the Desktop. The icon is a **placeholder** — concentric
rings in the app's own palette, standing in until Dr. Mia's artwork arrives.

## What the demo shows

Launch arguments are `-CalScenario day30Streak -CalEntitlement plus
-CalUseMockCoach 1`:

- **30 days of seeded history**, so Progress and History have something in them
  rather than being empty. It is synthetic and deterministic — the same charts
  every time.
- **The full ten-question framework**, which is the thing Dr. Mia designed.
- **A mock coach.** Nothing reaches a real model: no cost, no network, no flake.

A seeded scenario also puts the store in memory, so every launch starts from the
same clean state and nothing tapped during a demo persists. That is deliberate
here and is *not* how the shipping app behaves.
