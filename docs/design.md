# Design notes

Dr Mia wants an ambassador program to get more downloads
Dr Mia wants the design to look in a certain style
Dr Mia wants a comprehensive map system

how to get the login to work

okay but we are going to need to fix that where it should lead to a page where it's like thanks for creating an account with us. also the

welcome page that describes what the app does when the user first signs up and make an account

remove rate out of ten feature entirely

ambassador

go through the whole codebase, run the simulator and look for bugs, fix everything, make no mistakes.

---

## Shipped (2026-08-21)

- Welcome first-session: “Your personal coherence coach.” / “C.A.L. is the name, coherence is the game.” (no feature rows)
- App icon: orb (no bear). In-app character stays the orb.
- Spoken check-in: five topics, 0–10 via dialogue + under-orb chips; scores saved + memory; Cal talks (no silent hold / no slider screen)
- Opener: `{{session_opener}}` — “Check in today.” if not done; result-based greeting if done
- Suggestion chips under the orb
- Guided practices gated (basics free); Breathe Health Center first on map; clinic symptom → BHC once/day
- No reconnect when popping menu destinations

Still open: ambassador polish, broader “Cal” → “C.A.L.” copy sweep, tool-routing edge cases
