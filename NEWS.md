# Changelog

Notable changes to the pipeline, newest first.

Two conventions worth stating before you read it:

**Only `v0.7.0` is a real tag.** It points at commit `335d245`. Everything
below it was reconstructed after the fact from 280 commits between 2026-08-06
and 2026-08-14, grouped by what actually changed about the *estimates* rather
than by when someone decided to cut a release — treat 0.1.0 through 0.6.0 as
chapter headings, not as anything you can check out. Reproducing a specific
number should be done from the commit SHA recorded in that artifact's
`.provenance.json` sidecar, not from a version string here.

**Entries record what a change did to the numbers.** A fix that moved county
ascertainment from 30.6% to 98.9% is a different kind of event from a fix that
renamed a helper, and this file says which. Where a change *retracted* a
published figure, it is filed under **Retracted** and the wrong number is
printed alongside the right one. Those entries are the point of the file.

Format loosely follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

---

## [Unreleased] — Laws about the science, and a population that escaped its frame

No published estimate changed in this section. That is the finding, not an
omission: the defect it opens with was caught before it reached anything, and
the rest is machinery for catching the next one. Where a number *could* have
moved and did not, this says so explicitly.

### Fixed — a study frame that resolved more people than it held

`resolve_amcb_by_state_license()` reported **`3 of 2 AMCB certificants
(150.0%)`**. `deterministic_matches` was built from every qualifying id in the
state-license file, and the roster it was asked about was consulted only
afterwards in a left join — so a person outside the declared study population
was resolved, counted, and written to the artifact as a finding about it.

Four of the six audit metrics were counts drawn from the external universe over
a roster denominator:

| metric | n | pct_of_amcb |
|---|---|---|
| amcb_roster | 2 | 100% |
| amcb_with_state_license | 8 | **400%** |
| deterministically_resolved | 3 | **150%** |
| license_quarantine_rows | 5 | **250%** |

**Impact on published estimates: zero, and this was checked rather than
assumed.** No `amcb_deterministic_license_matches_*` or license-resolution
summary artifact has ever been committed, and the function has no production
caller — only the test suite reaches it. Nothing needed regenerating. The defect
was latent and would have corrupted the first real run.

The full A1–A8 roster still reports **3 of 8 (37.5%)**, unchanged. A frame fix
must not move a legitimate estimate.

The restriction is applied to the **claim**, never to the evidence, and the
existing fixture is why. A6 and A7 share board key CO 31313, so the key
identifies nobody and neither resolves. Filtering the license file to a roster
holding only A6 would drop A7's row, the key would look unique, and A6 would
resolve — certainty manufactured by deleting the evidence that contradicted it.
Narrowing a study frame must never widen its answer. Out-of-frame resolutions
are retained as a labelled diagnostic rather than discarded.

### Added — ten laws about the science, each proven able to fail

`tests/science_law_registry.tsv` is the machine-readable list of what this
repository claims to enforce; `tests/ci_law_coverage.R` refuses to pass unless
every declared law was exercised, was non-vacuous, and had a planted defect
killed. A law that never ran is indistinguishable, in a green build, from a law
that passed.

- **L1** cohort provenance is single-vintage
- **L2** population is conserved — in two shapes. The parts-sum rule cannot see
  a single share of 150%, because that breaks no addition, so L2 also holds that
  no share may exceed its declared denominator (checked on the 8 tracked
  artifacts carrying a `pct_of_*` column; none currently violate)
- **L3** missing geography stays missing — the frozen Alaska regression
- **L4** more travel time cannot reduce access
- **L5** every routed provider is in the union
- **L6** masking evidence cannot invent geography — 400 real Census ZIPs masked
  16 ways; its planted defect *is* the historical Yukon-Koyukuk bug, rebuilt
- **L7** contradictory identity evidence cannot increase certainty
- **L8** identical inputs produce identical outputs
- **L9** a cache may change runtime, not the answer
- **L10** every mutable scientific input has a declared vintage

30 planted defects, 30 detected.

### Added — the geocoding cache is a declared input

Coordinates decide counties, and counties decide rurality, which is a headline
of this study. Across 112 provenance sidecars there were 105 distinct declared
inputs and **not one was a cache**, so the pipeline computed `Y = f(X, whatever
the cache holds now)` while recording only `X`. Walking the provenance graph:
**14 artifacts are transitively cache-dependent, 0 declared a cache identity**,
and `midwives_geography_FROZEN.csv` has no sidecar at all.

`R/lib/cache_vintage.R` gives the cache a content-derived identity — nine
scientific fields, sorted in SQL, coordinates at 6 dp, with `created_at` /
`last_accessed` / `access_count` excluded **by name** because a fingerprint that
moved when someone *read* the cache would be useless as an identity. Live cache:
55,843 entries, sha `95d9837f9197291d`.

This is **not** an argument for an immutable cache. A cache that resolves more
addresses next month is better evidence; a later snapshot is a *new declared
input* — visible, attributable, a reason for a number to move — rather than
drift.

The 14 existing artifacts are **baselined, not back-filled**. They were built
against a snapshot nobody recorded, and stamping them now would assert a vintage
that is not the one that produced them. The baseline can only shrink.

### Fixed — replayed evidence is now bound to what it is evidence for

Coverage re-runs every gate and every mutation harness, and at ten laws that
took it past its own 600s budget — a checker that stops finishing is an absent
checker, arriving through the checker of checkers. Replay fixed the runtime and
introduced a custody hole: a log was accepted because it had the right filename,
and its contents were then trusted.

The gap is measurable. Replaying evidence against a tree that had moved
underneath it reported **10/10 laws exercised, 0 unexpected skips**; direct
execution of the same registry against the same tree reported **1/10 and 9**.

Every gate now stamps its output with its own source hash, the registry hash,
the commit and a run identity, and coverage recomputes all of it. Content
hashes, not timestamps — an mtime says when a file was touched, which is the
mistake L10 exists to reject. **Mismatch fails closed**; absence still falls
back to executing the gate. Verified on a pinned worktree: identical exit status
and identical scoreboard both ways, 303s versus 0s.

### Known — L5 does not run on a clean checkout

Logged as **[D7](DEBT.md)** rather than fixed, because the fix is a policy
choice. L5's dissolved-surface input lives under gitignored `artifacts/maps/`
while L5 is registered `public`, where a skip is defined as a failure — so on
any runner, coverage reports 9/10 and fails.

Every `10/10, 0 unexpected skips` reported while this suite was being built was
produced in a working tree holding that untracked file. The gate was right; the
environment used to check it was not.

---

## [0.7.0] — 2026-08-14 — State licensure, and identity that does not need a name

Tagged `v0.7.0` at commit `335d245`. The first linkage evidence in this project
that does not depend on comparing two spellings of a human name — and the first
release to carry a license, citation metadata and a changelog.

### Added — repository metadata
- Continuous integration (`.github/workflows/ci.yml`): repo hygiene (every
  tracked R file parses, no foreign home-directory paths, no duplicate
  `.gitignore` rules, no function defined at top level in two files) and the
  hermetic join-key and address-key unit tests. Deliberately small — it runs in
  about a minute on two Linux runners and installs `stringr` and nothing else.
  A green tick means the keys and the syntax are sound, **not** that the
  pipeline is correct; almost every real test needs artifacts or the private
  `isochrones` checkout, neither of which exists on a runner.
- `LICENSE` (MIT), with an explicit scope note: the code is MIT, the AMCB
  roster and the scraped third-party profiles are not, and person-level derived
  tables are not distributed at all.
- `CITATION.cff`, including structured citations for all twelve upstream data
  sources.
- This file.

- `NEWS.md` itself.

### Added — Table 1 hospital affiliation
- Five blocks built from the CMS facility affiliation file, keyed on CCN:
  whether a privilege is recorded, how many hospitals, acute vs critical-access,
  ownership, and birthing-friendly designation. They reconcile — 1,435 + 189 +
  41 = 1,665 with a privilege; + 3,319 enrolled without one = 4,984 in the DAC;
  + 6,936 absent from it = the 11,920-member active cohort. "Not enrolled in
  Medicare" stays a separate row from "enrolled, no privilege recorded",
  because collapsing them would invent 6,936 midwives with no hospital.
- Supporting artifacts, all aggregate and carrying no NPI, name or address:
  HCRIS FY2023 nursery and bed counts for the affiliated hospitals, the
  per-rule organization resolution PPV table, and the before/after organization
  distribution shift.

### Added — linkage and licensure
- **Deterministic AMCB → NPI resolution by state license number**
  (`amcb_license_bridge.R`). A license number matched against the NPPES
  `provider_license_number` field is an identifier-to-identifier join: it
  cannot fail the way token comparison fails on hyphenated, transliterated or
  post-marital surnames, which is the failure mode cycle 12 documented.
- **State Board of Nursing ingestion across all 50 states**, in tiers by how
  the state publishes: Tier 1 (11 bulk open-data states) → 5,120 midwives
  verified; Tier 2 (25 Nursys compact states) → 2,972; combined 8,092, then
  9,037 across 20 boards at 74% national coverage. Washington was harvested
  through a live streaming API (374 CNMs, 83.3% match rate, 341 active
  licenses confirmed).
- A state-by-state acquisition matrix classifying every state BON dataset by
  ingestion method, plus a dynamic acquisition manifest.
- Former- and maiden-surname candidate expansion, with tests.
- Age-at-certification validator and covariate.

### Changed
- The national BON tier now defaults **off**. It was defaulting on, which meant
  a stage could silently reach for a source the caller had not asked for.
- Roxygen completed across `R/lib`; the attribute layers documented in the
  README.
- One CABC parser and one set of address keys — the `v2`/`v3` duplicates are
  gone. The ZIP join key is now named rather than inlined, and a test that was
  shadowing `pad5()` no longer does.

### Fixed
- **The stage ledger could not answer its own question.**
  `geocoding_completeness_by_stage.csv` exists to show whether each enrichment
  stage improves *geographic* ascertainment or merely adds metropolitan sample.
  It was 42 lines with 7 unique: `COMPLETENESS_STAGE` defaulted to
  `"unlabelled"` and the write is append-only, so every ad-hoc rerun added
  another identical, unattributable row — 26 reached the committed artifact,
  86% noise in a file whose whole purpose is per-stage attribution. The default
  is removed (an unset stage now warns and writes nothing) and the unlabelled
  rows are dropped. Nothing is lost: all of them were exact copies of the
  `2_completed_nppes_matcher` numbers, which remain.
- `ci_hygiene.R` carries a baseline of 9 grandfathered duplicate definitions
  (`tests/ci_hygiene_baseline.txt`) so the check can block *new* duplicates
  today while the existing ones are retired one at a time.

### Security / privacy
- Untracked the PPV review sample, the Doximity public-profile artifacts and
  the person-level outputs of the attribute layers. Each carried certification
  numbers or NPIs. All are gitignored and rebuildable.
- Tests now confine their artifacts to `tempdir()`.

### Known limitation
- `org_resolution_ppv.csv` ships with `meets_threshold = FALSE` for both review
  strata (cross_source 0.96, multi_key 0.84). It is published as a measured
  result, not a passing check, and is consistent with organization affiliation
  being the weakest attribute layer in the repository (see 0.5.0).

---

## [0.6.0] — 2026-08-12 — The map becomes the interface

### Added
- National CNM interactive Leaflet map: clustering, practice-setting filters,
  state scope-of-practice autonomy borders, a drive-time tool, and popups that
  hyperlink each claim to the source that supports it — NPI Registry, AMCB
  verification, CMS Care Compare by 6-digit CCN, CPT claims, Open Payments.
  Certification year, age band and training school appear in the popup.
- Three-way federal address-recency audit (NPPES × Open Payments × DAC PECOS),
  which identified **400 practice addresses more current than the one NPPES
  carried**, with a benchmark suite over the updates.

### Fixed
- One case study worth naming because it is the general problem in miniature: a
  CNM carried a Seattle, WA address in NPPES while practising at Trinity
  Hospital in Wolf Point, MT — a 1,000-mile error that would have placed her in
  the wrong state, county, RUCC stratum and access band.

---

## [0.5.0] — 2026-08-11 — Attribute layers: where a midwife works

Everything in this release answers "what do we know about this person beyond a
point on a map", and every layer reports **absence separately from zero**.

### Added
- **Organization / employer resolution.** Type 2 organization NPI linkage from
  primary *and* secondary practice locations, with a deliberately conservative
  resolver for ambiguous matches and per-rule PPV machinery. Final coverage
  39.7%.
- **Hospital affiliation** via CCN matched to the DAC vintage:
  `match_npi_to_hospitals()`, self-contained down to downloading its own CMS
  inputs. 1,667 enrolled midwives, 1,958 privilege links, 908 hospitals.
  A street-level attribution pass prevents false spatial assignment in
  multi-hospital cities (Cleveland was the reproducer).
- **Freestanding birth centers**: 221 midwives matched across 111 CABC-accredited
  centers.
- **CPT delivery claims**: Part B claims filtered to 59400/59409/59410 confirm
  7,470 midwives (62.67%) actively attending deliveries — an *observed
  behaviour* layer, not a credential layer.
- **Open Payments**: 3,996 midwives linked; 819 resolved directly to Type 2
  organization NPIs and legal employer names.
- **Training institution** recovered structurally, from which university
  repository holds a person's DNP or thesis rather than from any parsed
  affiliation string: 34 repositories, 35,038 author-records, 25 institutions.
- Physical building taxonomy: MOB, hospital campus, birth center, outpatient
  clinic.
- USPS CASS–style address standardization (`postmastr`, `scourgify`), which
  **doubled** Open Payments facility match yield to 1,466 midwives (20.83%).

### Fixed
- Names are parsed with `humaniformat` on **both** sides and compared as token
  sets. Substring matching had been producing real false matches. Geography was
  dropped as a linkage gate at the same time; that pair of changes recovered
  722 certificants.
- Missing addresses normalize to empty and can never match — previously a blank
  could join to another blank and assert a shared campus.

### Known limitation
- Two independent implementations of organization resolution agree on only
  **16.4%** of cases. This is reported, not resolved, and the 20 residual
  cross-method disagreements are classified by cause. Treat organization
  affiliation as the weakest attribute layer in the repository.

---

## [0.4.0] — 2026-08-10 — Age, Table 1, and provenance that a stranger can verify

### Added
- **Empirical age calibration.** AMCB certification dates alone are a weak age
  proxy, so the model was calibrated against verified ground truth from state
  license files and public voter registration DOBs (Ohio N=3,962, Florida,
  Washington), through a three-stage disambiguation engine. Final strict
  state-blocked model: R² = 0.550, RSE = 7.71 years, N = 1,225. Every imputed
  age carries a provenance flag; see
  `docs/TECHNICAL_APPENDIX_AGE_IMPUTATION.md`.
- **Table 1** for the ACTIVE cohort, rendered with `gt` to HTML and markdown:
  NPPES taxonomy, cross-state practice concordance, Medicare Part B/D
  participation, HPSA shortage-area status, DAC practice structure, training
  institution, certification tenure.
- `write_with_provenance()` wired across every pipeline write, emitting
  `.provenance.json` sidecars.
- Cohort membership became an explicit allowlist rather than "has an NPI".

### Changed
- **Cohort re-freeze**: 16,892 → 16,898 members, done deliberately after the
  previous pin's payload no longer existed. An earlier accidental re-freeze
  (cycle 18) was reverted.
- 164 class-5 matches — ones that had been *not ruled out* rather than *ruled
  in* — were enumerated, corroborated against the registry's own name history,
  and quarantined.

### Fixed
- Compound surnames match on components, and the matching NPPES name variant is
  now recorded with the link.
- Every "Unknown" row was renamed to say what it actually is.

---

## [0.3.0] — 2026-08-09 — Twenty-three adversarial cycles

An adversarial loop ran against the finished pipeline looking for defects that
were *silent* — producing plausible output. The cycles below each retracted or
corrected something that had been published.

### Retracted
- **651 counties were described as having no obstetric care.** They did not;
  the check was wrong (cycle 15).
- **Suppressed WONDER cells were published as zero**, in three places,
  including a Connecticut county rendered as a true zero (cycles 3–4).
- **The fertility denominator counted women 15–49 in a variable named
  `women_15_44`**, and separately the numerator counted births the denominator
  excluded (cycles 16–17).
- A superlative in the county prose named the **noisiest** county rather than
  the highest (cycle 7).
- A rural-biased filter was withdrawn — it was more biased than the noise it
  was introduced to fix (cycle 8).
- Colorado carried **Alabama's** redistricting warning (cycle 20).

### Fixed
- **Row order was deciding midwife coordinates** (cycle 5).
- A linkage key that failed only on non-Anglo names (cycle 12).
- A naive coordinate bounds check would have deleted Guam (cycle 11).
- A pipeline stage that aborts was leaving its previous output in place, so a
  failed run looked like a successful one (cycle 18).
- Five helpers defined twice, one already divergent (cycle 9) — the origin of
  the standing rule to search for a canonical function before writing one.
- A provenance record no clone could verify (cycle 21).
- Water masks: an inverted mask could erase whole states, and water inside
  coverage areas had inflated the published access figures. DC's clip exception
  is recorded.

### Added
- The midwifery access map, county/CD/national birth profiles, five README
  figures generated from committed artifacts, and the first Table 1.
- `docs/DECISIONS_CONTRACT.md` — nine estimand questions the loop is not
  allowed to answer on its own — and `docs/HALL_OF_SHAME.md`.
- Healthgrades enrichment swept to completion rather than a single snapshot
  pass.

---

## [0.2.0] — 2026-08-08 — Freeze the linkage, then find the geography

### Added
- **Frozen AMCB–NPI linkage on ranked evidence classes**, with A/B
  reconciliation, an identity-flip audit and provenance. Geography is rebuilt
  from the linkage SHA, so the two can never drift.
- Healthgrades scraper for the unmatched.
- CMS Doctors & Clinicians as a matching source; historical panel surnames
  wired into the matcher; match tiers and a spatial anchor.
- Cross-state discordance diagnostic and the Connecticut planning-region
  vintage crosswalk.

### Fixed
- **County ascertainment 30.6% → 98.9%.** Two separate defects: county was
  being read from an empty cache column instead of derived from coordinates,
  and a mixed-row point-in-polygon bug was capping `county_exact` at 30.6%
  (→ 89.7% once fixed). Geocoding the 1,624 residual addresses closed the rest.

### Reported as negative
- **Isochrone reuse does not work here.** Reusing the existing OB/GYN isochrone
  library for midwives is reported as a *negative validation result* rather
  than quietly used. A subsequent recovery search over existing polygons took
  coverage 71.5% → 80.9% with no new routing, and access figures computed on
  that subset are labelled a **lower bound only**.
- The workforce framing was retracted and the maps split by certification
  status until the status accounting closed.

---

## [0.1.0] — 2026-08-06 → 2026-08-07 — The scraper

### Added
- AMCB certification directory scraper (cursor-based; the directory paginates
  by cursor, not page number), capturing the customer id.
- NPPES candidate fetch and location matching, rebuilt onto the `isochrones`
  matching stack rather than a parallel implementation.
- County covariate base, shared R helpers, the scraper test suite, and
  roxygen/docstring documentation.

### Fixed
- Ten defects across the scrape, fetch, match and check scripts, found by the
  first test pass.

---

[0.7.0]: https://github.com/mufflyt/midwifery/releases/tag/v0.7.0
