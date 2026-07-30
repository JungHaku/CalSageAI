# Cal Coherence — Launch Requirements

Everything that gates **shipping to real students**: privacy law, App Store review,
payments and commission, AI vendor terms and pricing, and campus data sources.

Split out of `ARCHITECTURE.md` on 2026-07-30 when the plan was restructured around
a local-first MVP. None of it has changed — it is simply not what you need open
while building the MVP. All figures were verified against primary sources on
2026-07-29 and are cited inline; anything unconfirmed is marked **[unverified]**.

**Section numbers below are the originals**, so existing cross-references
("§18.2", "§10.3") still resolve.

---

## 10. Model choice & cost control

All prices per 1M tokens, verified 2026-07-29.

### 10.1 Don't use gpt-4o

gpt-4o is **superseded**. OpenAI's current-models page lists only the GPT-5.6 family as current tiers; gpt-4o still appears on the pricing page at $2.50 in / $1.25 cached / $10.00 out, and the `gpt-4o-2024-05-13` snapshot has a shutdown date of **October 23, 2026**. Beyond being the older model, it is *structurally worse at the one optimization that matters most for this app*: its cached-input rate is only 50% off base, where GPT-5.6 cache reads are 90% off. If your plan was "use gpt-4o and fix the bill with caching," that plan recovers ~32% where gpt-5.6-luna recovers ~51%.

Also: **do not pin to the gpt-5 generation** — gpt-5, gpt-5-mini, gpt-5-nano and gpt-5-pro snapshots all shut down **December 11, 2026**.

### 10.2 Current options

| Model | Input | Cached read | Output |
|---|---|---|---|
| gpt-5.6-sol | $5.00 | $0.50 | $30.00 |
| gpt-5.6-terra | $2.50 | $0.25 | $15.00 |
| **gpt-5.6-luna** | **$1.00** | **$0.10** | **$6.00** |
| gpt-5.4-mini | $0.75 | $0.075 | $4.50 |
| gpt-5.4-nano | $0.20 | $0.02 | $1.25 |
| gpt-4o *(superseded)* | $2.50 | $1.25 | $10.00 |
| **claude-haiku-4-5** | **$1.00** | **$0.10** | **$5.00** |
| claude-sonnet-5 | $2.00 → **$3.00 on Sep 1 2026** | $0.20 → $0.30 | $10.00 → **$15.00** |
| claude-opus-5 | $5.00 | $0.50 | $25.00 |
| Gemini 3.1 Flash-Lite | $0.25 | $0.025 | $1.50 |

Three caveats that change the ranking:

- **Claude Haiku 4.5 requires a 4,096-token minimum to cache anything.** A 1,500-token system prompt plus 2,000 tokens of history is 3,500 — *below the threshold*, so caching silently does nothing, with **no error**: `cache_creation_input_tokens` and `cache_read_input_tokens` both come back 0. Sonnet 5 and Opus 4.8 use 1,024; Opus 5 and Fable 5 use 512. OpenAI's threshold is 1,024 across the board.
- **Claude 4.7-and-later models use a new tokenizer producing ~30% more tokens for the same text.** That hits Sonnet 5, Opus 5, and Fable 5. Haiku 4.5 predates it and uses the old tokenizer — so Haiku is relatively cheaper than headline numbers suggest, and any cross-model comparison against Sonnet 5 must be adjusted up ~30%.
- **On GPT-5.6+, cache *writes* cost 1.25x uncached input** (billed separately as `cache_write_tokens`). Earlier models including gpt-4o had no write fee. Caching is still a large net win; just don't model it as free.

### 10.3 Measured cost for this workload

3,500 input tokens (1,500 system + 2,000 history) + 350 output, per message, uncached:

| Model | Per message | Per user / month @15 msgs | @100 msgs |
|---|---|---|---|
| gpt-4o | $0.01225 | $0.18 | $1.23 |
| gpt-5.6-luna | $0.00560 | $0.084 | $0.56 |
| claude-haiku-4-5 | $0.00525 | $0.079 | $0.53 |
| claude-sonnet-5 (intro) | $0.01050 | $0.16 | $1.05 |
| gpt-5.4-nano | $0.00114 | $0.017 | $0.11 |
| Gemini 3.1 Flash-Lite | $0.00140 | $0.021 | $0.14 |

With caching in steady state (~3,150 of 3,500 input tokens served from cache):

| Model | Per message | @100 msgs/month | Saving |
|---|---|---|---|
| **gpt-5.6-luna** | **$0.00277** | **$0.28** | −51% |
| claude-sonnet-5 (intro) | $0.00483 | $0.48 | −54% |
| gpt-4o | $0.00831 | $0.83 | −32% |
| claude-haiku-4-5 | *no saving available* | $0.53 | 0% (below cache minimum) |

**Recommendation: `gpt-5.6-luna` as the default coach model, `claude-sonnet-5` if you want a warmer voice for premium and can absorb ~2x.** Luna caches at your prompt size, has confirmed streaming and structured outputs, and lands near **$0.28/user/month at 100 messages** — comfortably inside the target in §10.5. If you prefer Anthropic and want caching, use Sonnet 5, not Haiku, or deliberately grow the cached prefix past 4,096 tokens.

The honest headline: **cost is not your risk here.** Even the priciest sane option is ~$1.50/user/month at 100 messages. Spend your effort on cache-friendly prompt ordering and capping history, not on downgrading model quality for an empathy-sensitive coaching product.

### 10.4 The mechanisms that bound the bill

Prices change; these don't:

1. **Server-side proxy** — the only place money can be spent. There is no client key.
2. **Pre-call budget check** against `ai_usage`. Free: N messages/day. Premium: a generous monthly token budget. Over budget returns an authored fallback with HTTP 200 — never an error, never an overage.
3. **`max_tokens` on every call.** Cal's replies are 2–4 sentences by design.
4. **Capped context** — rolling summary + last 6 turns.
5. **Prompt caching** with the volatile tail last (§8.3). On GPT-5.6 pass `prompt_cache_key` — it's required for reliable matching, and TTL is fixed at 30 minutes. On Anthropic, the 5-minute cache **refreshes free on every hit**, so an active conversation stays warm indefinitely and the 2x 1-hour write is usually wasted money.
6. **Batch API (50% off, 24-hour window)** for journal reflections and weekly reviews only — never the live turn. **But see §18.3:** Anthropic's Batch API is not HIPAA-eligible, so if you end up needing a BAA, this discount is unavailable and the nightly jobs move to the standard API.
7. **Provider-side hard spend cap** and budget alerts.
8. **A kill switch** — a `feature_flags` row that disables LLM surfaces and falls back to authored content. Flip a boolean at 2am, don't ship a build.
9. **Record `cost_micros` and `cached_tokens` per message** so cost-per-active-user is on a dashboard in week one, not on an invoice in month three. Assert `cached_tokens > 0` in a test — that's how you catch a prompt reordering that silently killed your cache.

### 10.5 Target

Keep AI cost **under ~$0.50/month per premium user**. Against $11 gross minus Apple's 15% (§12) = $9.35 net, plus Supabase, margin stays healthy. Free users should cost cents, which the daily cap and cheap routing guarantee.

---

---

## 12. Payments

- One auto-renewable subscription, `com.breathehealthcenter.cal.premium.monthly`, at the $10.99 tier, with a 7-day free trial as an introductory offer.
- **StoreKit 2:** `Product.products(for:)`, `product.purchase()`, a `Transaction.updates` listener, `Transaction.currentEntitlements` for immediate UX. Gate `AppStore.sync()` behind an explicit **Restore Purchases** button, then re-read entitlements.
- **The server is the authority.** App Store Server Notifications V2 → an Edge Function `appstore-webhook` upserting `subscriptions`. AI budget and premium gating read `subscriptions`, not the client's word — otherwise a jailbroken device gets unlimited access to your paid model tier. Use Apple's App Store Server Library rather than hand-rolling JWS verification.
- **Local testing:** a `.storekit` configuration file exercises purchase, restore, trial, renewal, expiry, refund, and billing retry entirely in the simulator with no App Store Connect round-trip. Set it in the scheme and it becomes part of Loop 4; use Xcode's Transaction Manager to force edge cases.
- **Commission:** 30% standard, **15% under the Small Business Program** (under $1M/year — you qualify), and 15% automatically after one year of paid service. On $11: **$9.35 net at 15%**, $7.70 at 30%. Enroll in the Small Business Program before launch so you're at 15% from day one. Everything in §10 is sized against $9.35.
- **Rejection-proofing.** Show subscription name, duration, and full renewal price on the paywall, plus functional Privacy Policy and **Terms of Use (EULA)** links — in both the binary *and* the App Store Connect metadata. A missing or broken Terms link is a commonly reported 3.1.2 rejection. (The enumerated in-binary disclosure list lives on Apple's subscriptions page, not in guideline 3.1.2's text itself.)
- **RevenueCat** is free up to **$2,500 monthly tracked revenue** — about the first 227 subscribers at $11 — then 1% of tracked revenue. That makes it effectively free insurance through your entire campus-scale phase, covering the fiddly parts of JWS verification and grace-period edge cases. Reasonable either way; doing it yourself keeps entitlement in Postgres next to `ai_usage`, which is worth something.
- **[unverified, and don't build on it]** Apps on the US storefront may currently include external purchase links with no Apple commission. This is legally unstable pending Supreme Court review — treat 15% as the planning number, not 0%.
- **Sacred Care Fund.** Represent it accurately in-app but do not implement it as a payment split — Apple's IAP doesn't do splits, so it's an accounting decision on BHC's side. Also check whether "supports X" language triggers Apple's charity/donation rules.

---

---

## 14. Campus data integrations

**Hand-curate the location dataset. This is not a close call** — and it's already started: **[`content/berkeley-locations-raw.json`](content/berkeley-locations-raw.json) holds all 235 official campus locations with names, slugs, and exact coordinates**, extracted from `berkeley.edu/map`, and loaded by `CalContent`. I spot-validated it: 227 fall inside the main-campus bounding box, and the 8 outliers are genuine off-campus UCB properties (the Richmond library facilities, the Botanical Garden, 1608 4th Street).

One data-quality issue found while validating: **the source page lists four libraries twice** — Doe Memorial, Moffitt, Hargrove Music, and Starr East Asian — as `<slug>` and `<slug>-2` at *identical* coordinates. Left alone that draws two pins on one building, so `CampusPlaceSeed` collapses exact (name, lat, lng) matches at load and keeps the un-suffixed slug; 235 raw becomes 231 distinct. Only exact matches collapse, so two genuinely different rooms sharing a name still both survive, and a test fails if a re-scrape introduces a *new* duplicate.

Buildings essentially never move, so a static bundled JSON is the correct architecture, not a runtime dependency. Treat the extraction as one-time seeding plus a quarterly re-run.

Three caveats on that file: `berkeley.edu/map` has **no supported API** (the WordPress REST API doesn't expose the location post type), so this is scraping against markup that can change without notice; the names carry a `" - University of California, Berkeley"` suffix to strip; and the source page's coordinates come from Google Maps embeds that also contain **Berkeley's own Google Maps API key** — extract only lat/lng, never reuse that key, never commit the page HTML.

| Feature | v1 | Later |
|---|---|---|
| Campus map & places | The 235 seeded locations + hand-added categories, tags, and "quiet room" judgments | Official Facilities GIS (needs a CalNet account and a business case to `maps@berkeley.edu`) |
| **Library hours** | **Live API — see below** | — |
| Resource directory | Curated, every phone number `verified_at` by a human | — |
| Events / discounts | Dr. Mia curates via Studio | Campus event feeds |
| Class schedule / assignments | **ICS only** — see below | — |
| Transit | AC Transit GTFS-realtime, server-cached | 511 aggregator |
| Emergency numbers | Compiled in, human-verified (§9.3) | — |

**Library hours are the one genuine API win.** `lib.berkeley.edu` exposes a fully public, unauthenticated Drupal JSON:API with ~1,068 structured hours records. **Do not use LibCal** for this — `berkeley.libcal.com/hours` contains only 3 locations and omits Doe, Moffitt, and Main Stacks entirely. Two gotchas: times are encoded as **seconds-from-midnight**, and weekday suffixes run **0..6 where 0 = Sunday, not Monday** — an off-by-one here produces plausible-looking but wrong hours. Honor `field_hours_start_date`/`end_date` for term variations.

**Calendar import: ICS only, no OAuth.** The spec asks for Google Calendar and Canvas. Both have an ICS path that avoids all institutional and platform approval:

- **Canvas** publishes a per-user calendar feed at `/feeds/calendars/<code>.ics`, unauthenticated by design, needing zero institutional approval. Critically, **the obvious alternative is prohibited**: Canvas' API Policy explicitly forbids asking users to manually generate an access token and enter it into your application. And a Canvas OAuth developer key at Berkeley must be requested by a staff or faculty member — *explicitly not a student* — so that door is closed to you anyway.
- **Google Calendar** read scopes are classified **sensitive**, which requires OAuth verification (though not the annual CASA security assessment that restricted scopes demand). Worse, unverified Testing mode caps you at 100 users and **expires every user's authorization and refresh token after 7 days** — an unverified integration silently breaks for everyone weekly. Google's "Secret address in iCal format" bypasses the entire regime: no Cloud project, no scopes, no user cap, no expiry.
- **`EventKit`** additionally reads whatever calendars the student already has on their iPhone — one iOS permission prompt, no OAuth at all. If they've added their Google account to iOS, it's already there.

**Security note on those feed URLs:** a Canvas `feed_code` and a Google secret iCal address are **bearer-equivalent credentials in URL form** — anyone holding one reads the user's entire calendar with no login. Encrypt them at rest (`calendar_feeds.feed_url_encrypted`), never log them, never put them in a URL parameter or an error message.

**Course catalog:** the SIS Classes API is effectively unavailable to a non-affiliated developer (CalNet identity plus Data Owner approval; a non-affiliate can't reach the request form). Note `api-central.berkeley.edu` **no longer resolves in DNS** — any tutorial referencing it is stale; the portal is `developers.api.berkeley.edu`. The practical alternative is **Berkeleytime's** open GraphQL API serving the live catalog, but it's student-run and unofficial with no published terms, rate limits, or uptime commitment — treat it as best-effort with caching and graceful degradation, and let students paste their own data as fallback.

**Transit:** AC Transit's GTFS-realtime feeds are genuinely open, though the endpoints return 401 without a token and the working token is published inside the GTFS download URL on their Data API page. 511 SF Bay aggregates BART + AC Transit but its free token allows only **60 requests per hour**, so client-side polling from every install blows it instantly — you'd need server-side caching and fan-out. **Bear Transit is a hard dead end**: no GTFS, no API, PDF-only timetables (the only GTFS that ever existed covers service through 2021). Ship static stop pins and deep-link out.

---

---

## 18. Legal & compliance

### 18.1 The counterintuitive headline: HIPAA probably doesn't apply, and that's worse

HIPAA turns on the **relationship**, not the sensitivity of the data (45 CFR 160.103). A chiropractic clinic that bills electronically is a covered entity — but a consumer wellness app offered to the general student public does not create PHI, because the data isn't created or received in connection with providing care to the clinic's patients. OCR is explicit that an app facilitating access to health data at the individual's request does not by itself create a business associate relationship.

**So the likely answer is: not a HIPAA product.** That sounds like relief. It isn't, because the laws that *do* apply have no size threshold and come with private rights of action:

**California CMIA is the single most important law for this project.** Civil Code **§56.06(b)** deems businesses that offer software or hardware to consumers for managing medical information to be **"providers of health care"** — and a 2022 amendment (AB 2089) separately deems **"mental health digital services"** providers of health care. Cal is squarely both. Consequences:

- **$1,000 nominal damages per violation with no proof of harm required**, plus a private right of action and AG/DA civil penalties up to $250,000.
- Disclosure of medical information requires a **formal written authorization with strict formatting: minimum 14-point type, separate from all other language, its own signature.**
- The California Supreme Court narrowed CMIA entity coverage in *J.M. v. Illuminate Education* (May 14, 2026), but the narrowing helps incidental data holders — not a purpose-built wellness app.

**Washington's My Health My Data Act applies with no revenue or volume threshold** if you collect data from Washington consumers, and it has a genuine private right of action via the Washington Consumer Protection Act. This is arguably the largest litigation risk in the stack. It requires GDPR-grade opt-in that **cannot come from accepting terms of use**, **separate consents for collection and for sharing**, a **standalone consumer-health-data privacy policy with its own homepage link containing nothing beyond what the Act requires**, and **deletion that reaches all parts of your network including backups and cascades to every processor and third party**. It also bans geofences within 2,000 feet of any in-person health care facility. Notably, MHMDA **exempts HIPAA PHI** — so the HIPAA and MHMDA analyses are inversely coupled.

Also in scope depending on where users are: **Nevada SB 370** (near-identical opt-in, no private right of action), **Connecticut CTDPA** (opt-in before selling health data), **Maryland MODPA** (flatly prohibits selling sensitive data).

**CCPA probably does not apply** — its thresholds are $26,625,000 in annual revenue (the indexed figure effective Jan 1 2025, not the commonly-cited $25M), 100,000+ California residents, or 50%+ of revenue from selling personal information. Don't assume it applies; don't assume it never will. If it does, health data is "sensitive personal information," and the CMIA exemption in §1798.146 is **data-level, not entity-level** — a narrower carve-out than it first appears.

**The FTC Health Breach Notification Rule is the one that has actually produced penalties.** Its 2024 amendments took effect July 29, 2024, and a "breach of security" **includes a company's intentional but unauthorized disclosure** — voluntarily sending health data to an ad or analytics platform is a reportable breach. Enforcement is real: **GoodRx, $1.5M plus a permanent ban** on sharing user health data for advertising (Feb 2023); **Easy Healthcare/Premom, $100,000 plus a permanent ban**, where the vector was third-party SDKs (May 2023). California's AG separately settled with **Healthline for $1.55M** under CCPA/UCL (July 2025). Notification runs to individuals without unreasonable delay and no later than **60 calendar days**, and to the FTC contemporaneously for breaches affecting 500+ people.

**This is why §2 has no analytics SDK.** It's not caution; it's the specific conduct that produced every penalty above.

### 18.2 The recommendation

**Design this as a CMIA-and-MHMDA product, not a HIPAA product**, and stop trying to decide whether HIPAA applies. Concretely:

- Keep the app in a **separate legal entity** from the chiropractic clinic. Never ingest or export clinic chart data. Never let clinicians read app content in a care context.
- If Dr. Mia wants it marketed as part of care, or serving her own patients, accept that the whole store becomes PHI and sign BAAs down the entire vendor chain — don't try to segregate PHI by a per-user flag. Mixed-population apps are the highest-risk architecture there is.
- Build the consent flow as a **standalone CMIA-compliant authorization screen** (14-point type, separate, own signature), with **separate opt-ins for collection and for any sharing**, plus a distinct consumer-health-data privacy policy at its own homepage link.
- Design **deletion-through-backups-and-vendors** into the first schema (§5.4). Your LLM provider's 30-day retention window is part of that promise.
- Ship **zero** third-party analytics or advertising SDKs.

### 18.3 If you do end up in PHI scope, price it first

Supabase HIPAA is **Team plan or Enterprise only** — the pricing page lists it as "Not included" on Free and Pro. Rough monthly floor:

| Line | Cost |
|---|---|
| Team plan | $599 |
| HIPAA add-on | from ~$350 **[unverified — a Supabase maintainer's Aug 2025 forum figure, not published pricing; get a live quote]** |
| PITR, 7 days (required by the High Compliance setting) | $100 |
| Small compute (required by PITR) | $15, less a $10 Micro credit |
| **Floor** | **~$1,054–$1,064/month** |

Excludes egress/MAU overage, log drains, advanced MFA, custom domain. Compare that to Pro at $25.

The "High Compliance" project setting requires four controls: PITR, SSL enforcement, network restrictions, and Postgres connection logging. **But as established in §5.3, network restrictions do not apply to PostgREST/Storage/Auth — the very APIs your iOS app uses.** So the HIPAA checkbox does not harden your app's actual data path; RLS still is. Supabase says plainly that "the responsibility of applying the recommended controls falls directly to the customer."

On the LLM side:

- **Anthropic will sign a BAA self-serve**, in the Claude Console under Settings → Privacy → HIPAA compliance, effective immediately, no sales call. That's a real advantage. Two hard constraints: **HIPAA readiness is permanent and organization-wide once enabled and cannot be disabled**, and it **hard-blocks the Batch API, Files API, code execution, computer use, web fetch, MCP connector, and Claude Code with 400 errors.** So (a) provision a separate organization for non-HIPAA work *before* flipping it, and (b) **your 50% batch discount for nightly journal reflections disappears** — move those to the standard API in your cost model.
- **OpenAI signs a BAA**, but zero-data-retention is **sales-gated and requires prior approval**, and BAAs cover only ZDR-eligible endpoints. Start that conversation early if you need it.
- Neither provider trains on API data by default; both default to 30-day retention absent a ZDR arrangement.
- **De-identifying free-text journal entries is not a viable compliance strategy.** Safe Harbor's date-stripping alone would break the product. Don't design around it.

### 18.4 App Store review

**Guideline 1.4.1 is the primary rejection risk.** Reviewers actively reject AI mental-health chat as "medical advice or treatment without appropriate regulatory approval," even for non-clinical empathetic copy. 1.4.1 asks for a reminder to consult a doctor before making medical decisions — include it. Notably, **Apple imposes no crisis-line requirement**; that comes from California SB 243 (§9.1), not Apple.

Other guidelines that apply:

- **5.1.1(ix)** — healthcare apps must be submitted by the legal entity providing the service (§1).
- **5.1.2(i)**, amended 13 Nov 2025 — explicitly requires **disclosure and explicit permission before sharing personal data with third-party AI.** Your onboarding consent covers this; make sure it's specific.
- **1.2 (User-Generated Content)** — reviewers apply its four moderation obligations to AI output. Ship all four: content filtering, a **per-message Report button**, block, and published contact info. Tightened in Feb 2026 and again June 2026.
- **4.3(b) / 4.2** — the sleeper risk. A thin "AI chat wrapper" gets rejected as low-effort. Cal is not that, but the *free tier* needs enough native substance to look it.
- **Age rating: 17+ no longer exists.** Tiers are now 4+, 9+, 13+, 16+, 18+ (12+ also retired), effective with iOS 26. The driving descriptor is "Medical or Wellness": wellness topics = 9+, infrequent medical/treatment information = 13+, frequent = 16+. **Decided: 16+.** That's the honest answer for open-ended AI chat plus frequent wellness/treatment content, and it removes an argument with review rather than inviting one. Guideline 2.3.6 makes an honest answer a review requirement and warns about regulator inquiry. Answer the rating questionnaire to match — the app's actual behavior is the standard, not the marketing.
- **`PrivacyInfo.xcprivacy`** with required-reason API declarations has been mandatory since 1 May 2024; missing declarations are rejected at upload.
- **App Privacy nutrition label:** Health & Fitness > Health, Sensitive Info, User Content, Identifiers, Contact Info — linked to identity, not used for tracking.
- App Review needs a **working demo account and a live backend**, and non-obvious AI features must be described specifically in review notes.

### 18.5 Claim language — FDA general wellness

FDA issued revised **final** general wellness guidance on **January 6, 2026**. Claim language is what determines device status, and no generative-AI mental health tool has been FDA-cleared.

**Safer:** "manage stress," "soothe and relax," "promote self-awareness," "support mental acuity," "live well with…"
**Risky:** "treats," "therapy," "reduces symptoms of," anything naming a condition.

Her spec is mostly on the right side of this — *"allowing your natural coherence to emerge"* is good. But *"designed to actively help create a more coherent nervous system"* is the sentence to run past counsel before it becomes App Store marketing copy. Strip diagnostic, therapeutic, and outcome claims from the app name, subtitle, keywords, screenshots, onboarding, **and the system prompt**.

Related: wrongful-death product-liability litigation against AI chatbots over user suicides is live, and at least one federal court has allowed product-liability theories to proceed **[unverified — reported in practitioner commentary, not read from a docket]**.

### 18.6 Checklist

- [ ] Decide with counsel: separate entity, consumer product, no clinic-data flow (§18.2). **Blocking.**
- [ ] Standalone CMIA authorization screen: 14-point type, separate, own signature.
- [ ] Separate opt-ins for collection and sharing (MHMDA).
- [ ] Standalone consumer-health-data privacy policy at its own homepage link.
- [ ] Deletion cascading to backups, Storage, and the LLM provider's retention window.
- [ ] Data export endpoint.
- [ ] Zero third-party analytics or ad SDKs. Verified by a dependency test.
- [ ] SB 243: AI-generated disclosure, crisis protocol published on the website, `safety_events` queryable for the July 2027 report.
- [ ] Crisis numbers human-verified (§9.3).
- [ ] Claim-language review across app name, metadata, screenshots, onboarding, system prompt.
- [ ] Age rating 13+/16+; honest answers to the rating questionnaire.
- [ ] `PrivacyInfo.xcprivacy`; accurate nutrition label.
- [ ] 1.2 moderation affordances shipped: filter, report, block, contact.
- [ ] Apple Developer **organization** account under BHC (5.1.1(ix)).
- [ ] Berkeley marks resolved or renamed (§1).
- [ ] Breach response plan written before you need it.

---

---

### Dates to put on a calendar

| Date | What |
|---|---|
| **Sep 1, 2026** | Claude Sonnet 5 introductory pricing ends: $2/$10 → $3/$15 |
| **Oct 23, 2026** | `gpt-4o-2024-05-13` snapshot shutdown |
| **Dec 11, 2026** | Entire gpt-5 generation shuts down |
| **Jul 1, 2027** | First SB 243 annual report to the CA Office of Suicide Prevention |
