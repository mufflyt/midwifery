# Technical Appendix: State Board of Nursing Portal Survey

**Repository**: `midwifery`
**Related**: [`docs/PROVENANCE_DEFECT_BON_LICENSE_IDENTIFIERS.md`](PROVENANCE_DEFECT_BON_LICENSE_IDENTIFIERS.md) (why every claim below had to be re-verified live rather than trusted from this project's own prior history), [`docs/TECHNICAL_APPENDIX_MULTI_SOURCE_ADDRESS_AGREEMENT.md`](TECHNICAL_APPENDIX_MULTI_SOURCE_ADDRESS_AGREEMENT.md) §4 (what the 8 working states' address fields are actually worth for address-agreement measurement)
**Investigation date**: 2026-09 through 2026-10-26
**Status**: 18 states individually investigated. 10 produced a working harvester or dataset of some kind; 2 of those 10 turned out not to be usable as CNM/BON data at all (Michigan is a different credential; Colorado's address field was later removed as the wrong address *type*, not missing). 8 states hit a hard wall or an explicit scope exclusion, with no usable result, across the most recent 8 states checked in a row. **The state-by-state sweep is not a reliably scaling strategy** — see §4.

---

## 1. Why this exists

Every new state added to the live BON cross-reference came from the same
three-part bet: (a) does the state publish a reachable, non-login license
lookup at all, (b) can it be queried without defeating bot detection, and
(c) does it carry a city/state/zip field worth anything for address-level
work. This appendix is the honest ledger of that bet across every state
actually checked — not just the ones that worked. A state that failed (a)
or (b) was never coded against; a state that passed both but failed (c)
still got a harvester, because license-verification and match-rate data
has value on its own, separate from the address-agreement work in the
appendix linked above.

**The point of writing this down**: after the first 10 states (built over
several weeks, each adding real data), the next 8 states checked
*in a row* — North Carolina, Ohio, Georgia, Minnesota, Arizona, Tennessee,
Wisconsin, Oregon — produced zero new usable datasets. That is a strong
enough signal on its own that it belongs in the record, not just in
session scrollback.

## 2. What "usable" means, and the line this project will not cross

A state counts as usable only if its data can be retrieved the same way a
person could retrieve it by hand: a public search form or API that returns
results to an ordinary request, with no login and no bypassing of a
site's own bot defenses. Every wall recorded in §4 was confirmed, then
left alone — not patched around with headless-browser fingerprint
spoofing, CAPTCHA-solving, or any other evasion technique, regardless of
whether a technical workaround was visible. This line was applied
identically every time it came up (§4's "detection tech" column shows five
materially different technologies, all treated the same way).

The one exception worth naming: Georgia's Cloudflare check explicitly let
a real, interactively-driven browser session through while blocking a
freshly-launched Selenium session (`navigator.webdriver` flag) on the
identical request. That is Cloudflare distinguishing a real browser from a
scripted one — not a bypass performed here — and it still could not be
turned into an unattended harvester, since nothing in this project runs as
a standing interactive session. It is recorded in §4 as a wall for that
reason: usable means *scriptable*, not merely *reachable once, by hand*.

## 3. States with a working harvester or dataset (10)

| State | Mechanism | Bot defense | Location fields | Outcome |
|---|---|---|---|---|
| WA | `data.wa.gov` Socrata open-data API (`qxh8-f4bd`) | none | **none** — confirmed by querying the live API's full field list directly, not assumed | 369 of 443 WA-state cohort matched; no address value possible |
| CO | `data.colorado.gov` Socrata open-data API (`7s5z-vewr`) | none | `mailzipcode` — a **mailing** address, not practice | 486 of 557 matched; **removed from the address-agreement comparison outright (2026-10-23)** once the field was confirmed to be mailing, not practice — see linked appendix §4. The license/RXN match itself is still valid and kept. |
| TX | `data.texas.gov` Socrata open-data API (`jnzg-cr4w`) | none | `county_of_residence` (county, not city; residence, not practice) + `place_of_employment` (free text, no reliable zip) | 469 of 536 matched; no clean city/zip usable, free-text field rejected rather than regex-scraped |
| CA | CA Dept. of Consumer Affairs public Box-hosted roster (tab-delimited, monthly) | none | city + county; **no state, no zip** (every row already scoped to CA by construction) | 1,342 of 1,501 matched (89.4%) by name — the largest BON sample in this project; city-only, 24.7% agreement against PECOS/DAC |
| IL | State open-data API, full APRN population (no CNM-specific filter exists) | none | structured city/state/zip | only 4% match rate (mostly AMBIGUOUS, common-name collisions in an 82k-row pool); contributes 1 comparable row |
| CT | State open-data API, full APRN population (no CNM-specific filter exists) | none | structured city/state/zip | 13% match rate (mostly genuine non-presence, spot-checked); 14 comparable rows |
| DE | State open-data API, exact `license_type=Certified Nurse Midwife` filter | none | structured city/state/zip | 0 DE-state cohort members currently exist to match against — an honest zero, wired up for whenever one does |
| FL | Florida DOH License Verification (`mqa-internet.doh.state.fl.us`), detail-page HTML | none on the search/detail pages | full city/state/zip, but only on a per-record detail page | 813 of 1,035 matched (78.6%) — required a Qualifications-field CNM screen since FL has no CNM-specific category (APRN covers NPs/CRNAs/CNSs/CNMs together); 224 comparable rows, the largest single BON contributor |
| PA | PALS (`pals.pa.gov`) clean JSON `POST` endpoint | reCAPTCHA v3 script loads on the page but is **not wired to the endpoint** — confirmed with a bare `curl`, no cookies, no token, succeeding directly | City, State, County, zipcode on every record — no detail-page fetch needed | only 87 of 642 matched (13.6%), confirmed correct on hand spot-checks — a genuine, surprising coverage gap, not a matching bug; CNM-specific by construction (Board of Medicine LicenseTypeId 234, separate from Nursing's list, which has no midwife entry at all) |
| MI | MiPLUS public license lookup | none | — | **not CNM/BON data at all** — Michigan's "Midwife" license type was hypothesized to be the state's CNM category (no separate APRN type exists there), but checking all 119 live records against the full 22,357-person national cohort found only 1 coincidental name match. It is Michigan's separate direct-entry/Certified Professional Midwife track. Kept as a labeled reference dataset, not wired into the BON comparison. |

Two patterns inside this table matter more than the row count: every
state that worked with **no bot defense at all** was a state publishing an
actual open-data API (Socrata, in three of the ten cases) or a
plain-HTML/JSON endpoint never designed to resist scripted access. Nothing
here required defeating anything. The one state with any bot-defense
script present (PA's reCAPTCHA v3) still worked, specifically because that
script was decorative — not wired to the endpoint actually serving data.
That distinction is the entire reason §4's states did not get harvesters:
their defenses *were* wired to the endpoint.

## 4. States that were a dead end (8 in a row, most recent first)

| State | What was tried | Wall | Category |
|---|---|---|---|
| Wisconsin | `online.drl.wi.gov` / `licensesearch.wi.gov` / `app.wi.gov/licensesearch` | The canonical name-search domain (`licensesearch.wi.gov`) does not resolve — confirmed via `curl`, Python `socket.gethostbyname`, Chrome, and two independent public DNS resolvers (Google `8.8.8.8`, Cloudflare `1.1.1.1`), all consistent with a genuine, non-local outage rather than a block | **Infrastructure outage**, not a block. A different, working host (`online.drl.wi.gov`) does reveal a promising distinct "Nurse - Midwife (32)" profession code, but only via a multi-license-number lookup tool, not a name search — no working single-person search entry point was found. |
| Tennessee | State license verification portal | BotDetect CAPTCHA (ASP.NET, "Enter the code shown") | CAPTCHA wall |
| Arizona | `boardsofnursing.org` | No APRN/CNM search category exists on the portal at all — out of scope, not a wall. The site also states explicitly: *"We request that data extraction tools not be used"* — honored regardless of technical feasibility. | Scope exclusion + explicit anti-scraping policy |
| Minnesota | State license lookup | Radware Bot Manager + hCaptcha ("ANOMALY DETECTED", "Please solve this CAPTCHA to request unblock") | CAPTCHA/bot-manager wall |
| Oregon | `osbn.oregon.gov` (dead; replacement found at `osbn.boardsofnursing.org/licenselookup` via a fresh, more specific search) | No address field of any kind on the license-lookup results — same category as Washington's exclusion in §3, not a wall | No usable location data |
| Georgia | GOALS (Salesforce LWC site) | Cloudflare explicit `navigator.webdriver` detection — let a real Claude-in-Chrome session through, blocked a freshly-launched Selenium session on the identical request (see §2) | Bot-fingerprint wall |
| Ohio | eLicense Ohio | Generic WAF block page: *"The requested URL was rejected. Please consult with your administrator."* | WAF wall |
| North Carolina | NC Board of Nursing license lookup | reCAPTCHA v2 checkbox ("I'm not a robot") | CAPTCHA wall |

Every wall above was confirmed directly (page content, console state, or
response headers), not inferred from a search-engine snippet, consistent
with this project's standing rule to re-verify rather than trust a claim
about a BON source's shape or availability.

## 5. What this does and does not establish

- **This is not a statement that these 8 states' data is unreachable by
  any means.** A human filling out a CAPTCHA by hand, or a state agency
  granting a bulk-data or API partnership, would work. What failed here is
  specifically *unattended scripted retrieval without defeating a site's
  own bot defenses* — the only method this project uses.
- **The pattern is not "small states fail, big states work."** States of
  very different size appear on both sides (WA/CO/TX/CA/FL are large;
  DE/IL had near-zero cohort presence; NC/OH/GA/MN/TN/WI are all
  mid-to-large states with no usable result).
- **The decisive variable, across all 18 states checked, is whether the
  state treats its license lookup as public open data (a Socrata API, or
  a plain unprotected search) versus as a service to be defended against
  automated traffic.** Every state in §3 falls in the first category.
  Every CAPTCHA/WAF/bot-manager wall in §4 falls in the second. There is no
  known way to tell which category a new state falls into without trying
  it — this project found no proxy signal (state size, the word
  "modernized" on the agency's own site, platform vendor) that predicted
  it in advance.
- **Diminishing returns are real and now documented, not just felt.** The
  first 10 states checked (over several weeks) produced 8 usable datasets.
  The next 8 states checked (in one continuous pass) produced 0. That is
  not proof the 19th state would also fail, but it is a reasonable basis
  for treating future blind state-by-state expansion as a low-probability
  bet rather than a default next step — check a specific state only when
  there is a concrete reason to expect it falls in the open-data category
  (e.g., a known Socrata/CKAN open-data portal, or a state agency already
  publishing other licensure data in bulk), rather than working through
  the list by cohort size alone.

## 6. Where each state's code actually lives

Not every harvester script in the table above is present in this
worktree's current `HEAD`. WA, CO, TX, and the CA/IL/CT/DE/FL/PA scripts
were built and committed across several different session worktrees and
branches (some merged directly into `main`, some pushed to a feature
branch and pulled in via an isolated temp branch, some copied in from a
branch opened by a separate, parallel session before that branch had its
own PR — see each commit message, e.g. `50f6b97`, `f0a00b4`, `9232b4d`,
for the specific provenance). Anyone adding a 19th state should expect to
find the prior state's script either in this directory, in `tests/`, or
need to retrieve it from `git log --all` by commit message before writing
a new one from scratch — several of the state names in §3 do not currently
have a `.py` file checked out alongside this appendix despite their output
artifact and `.provenance.json` being tracked.
