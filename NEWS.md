# Changelog

Notable changes to the pipeline, newest first.

Two conventions worth stating before you read it:

**The version numbers are retrospective.** This repository has no git tags. The
releases below were reconstructed from 280 commits between 2026-08-06 and
2026-08-13 and grouped by what actually changed about the *estimates*, not by
when someone decided to cut a release. Reproducing a specific number should be
done from the commit SHA recorded in that artifact's `.provenance.json` sidecar,
not from a version string here. Tagging `v0.7.0` at the current HEAD would make
these real; until then treat them as chapter headings.

**Entries record what a change did to the numbers.** A fix that moved county
ascertainment from 30.6% to 98.9% is a different kind of event from a fix that
renamed a helper, and this file says which. Where a change *retracted* a
published figure, it is filed under **Retracted** and the wrong number is
printed alongside the right one. Those entries are the point of the file.

Format loosely follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

---

## [Unreleased]

### Added
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

### Fixed
- `ci_hygiene.R` carries a baseline of 9 grandfathered duplicate definitions
  (`tests/ci_hygiene_baseline.txt`) so the check can block *new* duplicates
  today while the existing ones are retired one at a time.

---

## [0.7.0] — 2026-08-13 — State licensure, and identity that does not need a name

The first linkage evidence in this project that does not depend on comparing
two spellings of a human name.

### Added
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

### Security / privacy
- Untracked the PPV review sample, the Doximity public-profile artifacts and
  the person-level outputs of the attribute layers. Each carried certification
  numbers or NPIs. All are gitignored and rebuildable.
- Tests now confine their artifacts to `tempdir()`.

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

[Unreleased]: https://github.com/mufflyt/midwifery/compare/main...HEAD
