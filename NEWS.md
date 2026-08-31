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

## [Unreleased] — 2026-08-31 — 24-cycle adversarial testing loop; a data-regression guard; a STROBE checklist; two README corrections

### Added — `tests/ci_data_regression_guard.R`: PUBLIC vs PRIVATE-OK data regression guard

Ported from `mufflyt/isochrones`'s `test-data-regression-daily-guard.R`
(2026-08-27/28). Pins concrete numbers and cross-artifact agreements from the
data actually committed to the repo — `linkage_manifest.json`'s dispositions
sum to its own `total_rows`; those same seven dispositions agree **exactly**
against the independently-written `linkage_completeness_by_status.csv`; the
FROZEN crosswalk's own manifest agrees with `linkage_manifest.json`; every
`composition_*.csv` group sums to its own N; every Manski bound in
`linkage_selection_bounds.csv` is ordered lower ≤ observed ≤ upper; README's
cited roster count matches the data; the frozen 16,892 (geography-guard
freeze) stays pinned and distinct from the later 16,898 refreeze; a sample of
provenance sidecars stays schema-valid. Classifies every input explicitly as
**PUBLIC** (committed — a skip on it is itself a regression, not a pass) or
**PRIVATE-OK** (gitignored person-level data — a skip is expected). See
[docs/TECHNICAL_APPENDIX_DATA_REGRESSION_GUARD.md](docs/TECHNICAL_APPENDIX_DATA_REGRESSION_GUARD.md).

### Added — `manuscript/STROBE_checklist.md`

No STROBE checklist previously existed for the geographic-persistence
manuscript. Maps all 22 items (cohort-study wording) to their location in
`manuscript/midwife_persistence.qmd` and its appendices. Building it found and
fixed two real issues: Methods lacked an explicit "no sample-size calculation
was performed" statement (item 10 — the fact existed only in Discussion, the
wrong section for a Methods item), and `references.bib`'s R Core Team citation
was dated 2024 while the manuscript actually renders under R 4.6.1, a 2026
release. The title page's Funding, Financial Disclosure, and Presented-at
fields remain unfilled placeholders — those need the authors, not a
mechanical fix.

### Added — `R/lib/artifact_provenance.R`: code provenance, not just input provenance

`write_with_provenance()` now also records the *code* that produced an
artifact, by content: `.code_closure()` follows `source()`/`sys.source()`
calls transitively from the entry script. Previously, a change to the CODE
left every sidecar unchanged and every artifact validating — not hypothetical,
since a middle-name-parsing fix earlier this file moved the linkage cohort by
19 records while touching only `R/amcb_match_rules.R`, and no sidecar could
have said so. `check_provenance()` now reports `kind = "code"` rows alongside
`kind = "input"` rows.

### Fixed — README.md: three stale linkage percentages

`README.md` cited **65.8%** of the roster resolving to a midwifery-taxonomy
NPI in three places; the currently-committed `linkage_manifest.json` (22,309
total, 14,764 matched) gives **66.2%**. The nearby ACTIVE-vs-DECEASED
cohort-resolution comparison was similarly stale (**78.0%/18.6%** →
**78.4%/18.8%**). Corrected at the top-level summary points; a larger block of
detailed worked-example counts further down the README (the `11,920`-primary-
tier passage and its dependents) was **not** re-verified in this pass and may
carry the same staleness — flagged for a dedicated follow-up rather than
risking a rushed, partial rewrite of interdependent numbers.

### Added — two README gallery figures

`docs/figures/selection_bounds.png` (roster-wide metropolitan share: observed,
sensitivity estimates, worst-case bounds) and `docs/figures/linkage_by_status.png`
(cohort resolution vs. ascertainment by certification status) existed on disk
but were not yet in the README's Key Visualizations gallery.

### Also this session — 24-cycle adversarial testing loop (cycles 24–47)

Twenty-four cycles of boundary-value, semantic, and adversarial testing found
and fixed real defects across the pipeline: order-dependent conflict
resolution in `distinct(.keep_all = TRUE)` (8+ sites — NPI deactivation, Open
Payments facility matching, Table 1/HPSA cohort linkage, DAC education), a
tie-vectorization bug in the geocoding rurality gap statistic and
independently in the manuscript's own CI-interval functions, an RNG-
reproducibility gap in `resolve_org_ambiguity.R`'s sampling, and a fail-open
gap in `analyze_linkage_selection_bias.R`'s reconciliation invariant. Full
per-cycle detail in
[docs/ADVERSARIAL_LOOP_LEDGER.md](docs/ADVERSARIAL_LOOP_LEDGER.md).

---

## [Unreleased] — 2026-08-30 — A credential comma was reversing first and last names

### Fixed — `amcb_parse_person()`: **366 of 35,038 harvested authors (1.0%) had the wrong surname**

The parser tested the **raw** string for a comma to detect `"Last, First"`, so the
comma in `", CNM, MSN"` was read as a name reversal:

| input | before | after |
|---|---|---|
| `Jane Doe, CNM, MSN` | **DOE** / JANE | JANE / **DOE** |
| `Ann M. Barbaccia (Pollack), M.D.` | **M** / BARBACCIA / **ANN** | ANN / M / **BARBACCIA** |
| `St. Marie, P` | last = **ST** | last = **ST MARIE** |
| `Averill Caddeo, MSN, RN, …` | last = **AVERILL** | last = **CADDEO** |
| `Samuel (NMN) Anaya, M.D.` | first = *empty* | SAMUEL / **ANAYA** |

Three defects, and the middle one is the interesting part:

- **the comma test.** Moving it after `amcb_strip_name_noise()` — the obvious
  fix — never fires at all, because that function splits on `[[:space:],]+` and
  deletes every comma before it can be seen. Every genuine `Mróz, Jan` would
  then parse as given name `MROZ`. The decidable question is whether a comma
  separates two stretches that **both still hold a name** once credentials are
  gone. Both wrong answers are pinned by T24.
- **parenthesised alternates reached the parser.** humaniformat assigns whatever
  it is given to a slot, so a maiden name became the *surname* —
  `"Ann M. Barbaccia (Pollack)"` → `last = "(Pollack)"` — which
  `amcb_name_key()` then normalised to `""`, silently emptying the field the
  match depends on. They are now removed *before* parsing.
- **an empty string aborted the vector.** humaniformat throws a C++
  `range_error`; blanks are held out and put back.

Scope: `link_theses_to_amcb.R` only, feeding
`artifacts/amcb_training_institution.csv`. The AMCB→NPPES linkage does not use
this parser, so **no cohort number changes**.

---

## [Unreleased] — 2026-08-30 — The middle-name edit-distance tolerance is gone

### Removed — one-edit tolerance on middle names: **−19 cohort members, accepted**

A rule added earlier the same day returned `uninformative` when two full middle
tokens were within one edit (two from six characters up), so the candidate
survived instead of being vetoed. It is deleted, not merely unreferenced —
`tests/test_amcb_gates.R` asserts `!exists("near_spelling")`.

Measured before removing it: **64 of 30,740** exact-name candidate pairs (0.2%)
depended on it, touching 63 roster records. Measured after: cohort 16,958 →
**16,939**; 25 rows lost an NPI, 2 changed NPI, and 7 previously-tied rows
*resolved* — because a conflict now vetoes a rival and leaves one candidate
standing.

The reason is not that it mismatched often. It is what it admitted:

| pair | edits | |
|---|---|---|
| `LOUSE`/`LOUISE`, `ANGELA`/`ANGLEA` | 1–2 | typos — the case for the rule |
| `ELISABETH`/`ELIZABETH`, `FRANCES`/`FRANCIS` | 1 | spelling variants |
| `JULIA`/`JULIE`, `LEE`/`LEA`, `EDA`/`EDNA`, `ANN`/`ANNE` | 1 | **different given names** |
| `KRISTINA`/`KRISHNA` | 2 | arguable either way |

It is also **not symmetric with fuzzy surname blocking**. Class 4 uses edit
distance to *generate* a candidate that is then ranked below exact evidence and
labelled `sensitivity_fuzzy`. This used it to *suppress a veto*, with no tier
recording that it had happened. 19 records is a cheaper price than an
edit-distance test anywhere in the identity path.

G6 now pins `JULIA`/`JULIE`, `LYN`/`LYNN`, `ELISABETH`/`ELIZABETH` and
`KRISTINA`/`KRISHNA` as **conflicts**, so it cannot return by accident.

---

## [Unreleased] — 2026-08-30 — One middle-initial rule was deleting matches and manufacturing them at the same time

### Retracted — the frozen cohort is not regenerable by the current pipeline

Re-running `match_amcb_to_npi.R` unmodified, on the same roster and panel, does
not reproduce `amcb_npi_linkage_FROZEN.csv`. 249 of 22,309 rows differ, zero of
them a different NPI, and the difference decomposes exactly:

| status | frozen | re-run |
|---|---|---|
| `ambiguous_contested_npi` | 95 | **188** |
| `candidate_class5_held_out_of_cohort` | 156 | **0** |

Neither cause is a change to this repository. `rank_one_to_one()` is imported
from `~/isochrones` and stopped consuming NPIs greedily on 2026-08-08, so a
contested NPI now quarantines both claimants instead of one; and the frozen
artifact's manifest names `amcb_npi_crosswalk_c5guard_…` as its source, meaning
**FROZEN is the base linkage plus a c5guard step this script does not perform**.
`16,892` is reproducible only as base-linkage-at-freeze + c5guard +
pre-2026-08-08 bijection, two of which live outside this repo.
See [`TECHNICAL_APPENDIX_REPRODUCIBILITY.md`](docs/TECHNICAL_APPENDIX_REPRODUCIBILITY.md).

### Fixed — middle names compare as token sets: **+153 cohort members**

The middle-name axis compared `substr(middle, 1, 1)` on each side, so a maiden
surname held in a different slot scored as a disagreement and vetoed the
candidate. Against a like-for-like control run: matched 14,813 → **14,998**,
tied 3,044 → 2,949, contested 188 → 123, cohort 16,805 → **16,958**.

Three separate defects, each found by auditing the identity flips the previous
one caused:

- **position** — `A REINHARD` against `REINHARD` shares a token outright;
  `BETH HARVEY` against `H` is an initial abbreviating a non-first token. 82
  roster rows had their *only* exact first-and-last-name candidate deleted this
  way, 57 of the 88 deleted pairs carrying a CNM credential in NPPES.
- **concatenated initials** — `VL` against `VELMA LAURITZEN` is two characters,
  so the fix's first version scored it as a full *name* token and conflicted.
  Classification ("does this look like initials?") is undecidable — `LYN`,
  `BRY`, `SKY` are vowel-less names — so the rule asks whether the characters
  map, in order, onto distinct tokens on the other side.
- **near spellings** — `JULIA`/`JULIE`, `LYN`/`LYNN`, `KRISTINA`/`KRISHNA` were
  conflicts. A one-edit tolerance was added here and **removed the same day**;
  see the entry above.

Identity flips were audited case by case: **18 moved onto a midwifery-taxonomy
record, 1 moved off** (`LEIGH` against `LYNN`, which are different names and
which the old rule matched on nothing but a shared L).

### Fixed — contested NPIs are awarded on evidence again, not withdrawn wholesale

The upstream change withdrew 93 people from the cohort. Only 37 of those 93 are
genuinely inseparable; for 56 one claimant holds strictly stronger name
evidence. `amcb_award_contested()` awards those and refuses the ties —
**53 awarded in the shipped configuration, contested 188 → 123, zero identities
decided by sort order**. `CONTESTED_RULE=greedy` reproduces the pre-2026-08-08
behaviour and is *not* the default, because 37 of its awards are decided by
certification number.

### Added — both tails of the middle-name veto are now countable

`n_mid_vetoed_c2`, `resolved_by_absence_c2` (**218** rows) and
`unmatched_after_middle_veto` (**73** rows). The class-5 guard already asked
"ruled in, or merely not ruled out?"; class 2 is where the veto is strongest and
it had never been asked there. `match_reason` no longer claims "no NPPES
candidate shared this name" over rows that had one.

### Added — taxonomy scope is a declared dimension, and the ceiling is measured

`PANEL_TAX_SCOPE=wide` builds every specialty in the `363L*`, `163W*` and
`364S*` families — 845,255 NPIs against 443,623. Measured after the veto and
resolver: **163 of the 2,108 "no candidate" rows recovered, 15 of them
midwifery, against 528 resolved rows becoming ties.** The wide pool stays a
**sensitivity artifact**; the hypothesis that taxonomy truncation hid a large
reservoir is refuted — 1,282 of the 2,108 already have their surname in the
narrow pool.

`panel_definition()` was blind to this: both panels returned
`midwifery-plus-nursing`, so the auto-generated artifact name was identical and
a wide run would have silently overwritten the narrow artifact. That is the
third recurrence of the naming defect this scheme exists to prevent (year
window, then taxonomy A/B, now scope). The panel carries a `tax_scope` column,
written by both readers.

### Changed — appendix classes 3 and 4 described rules the code does not implement

The record-linkage appendix said class 3 was "given name equivalent via nickname
dictionary". It is `exact_last & first_init_ok` — surname plus **first
initial**, given names differing. The nickname dictionary exists but belongs to
`match_nppes.R` and is unreachable from the code that produced the frozen
linkage. Class 4 omitted its exact-given-name requirement. This survived
PR #130's appendix refresh verbatim.

Class 3 generates 150,805 of 198,922 candidate pairs — 76% of the universe — and
1,487 of the 3,044 ties, including a 348-way tie on one `SMITH`.

### Added — imported functions are pinned by behaviour (G7), contested awards gated (G8)

`exists(fn)` was the entire import check for five functions from another
repository. `amcb_assert_rank_one_to_one()` asserts the properties this pipeline
relies on against a fixture, and G7 proves the assertion can fail by running it
against greedy, first-row, passthrough and erroring stand-ins.

---

## [Unreleased] — 2026-08-29 — The metropolitan share had three values, and CI had two meanings of green

### Changed — headline rurality estimate: 86.5% → **89.3% metropolitan**

The published figure was 13,277 of 15,347, and two things were wrong with that
denominator at once, which is why it survived so long. It put the 486 members
with **no assignable county** into the denominator of a metropolitan share,
treating "we could not tell" as "not metropolitan". And 15,347 is the *retained
subgroup*, while the sentence around it said "the analytic cohort", which is
16,892.

The frame is now the cohort throughout: **14,861 of 16,892** members have an
assignable county, **13,277 (89.3%)** of those are metropolitan, and 2,031 have
none. 86.5% survives in the stats catalog as
`cohort.metro_pct_retained_with_unknown` so a reader reconciling against an
earlier draft can find where it went.

### Added — the rurality result is now bounded rather than caveated

Linkage is selected on certification status, so the cohort's distribution need
not describe the roster of 22,309. Making no assumption about the missingness
mechanism, the roster-wide metropolitan share is bounded **64.9%–92.2%**.

The most informative number is not a bound. Rurality is missing because a
practice ZIP failed to resolve, **not** because a certificant failed to enter the
cohort — different events, and conflating them discards evidence. **1,358 of the
5,417 non-cohort certificants carry a resolving ZIP, and they are 87.7%
metropolitan against the cohort's 89.3%.** That 1.6-point gap is the only direct
evidence available on the *direction* of the selection, and it points the same
way as the persistence bias. For the roster-wide share to fall to 75%, the 7,448
certificants with no assignable county would have to be 46.4% metropolitan — a
departure of 43.0 points.

### Added — three values for one quantity is now a build failure

86.5% (manuscript), 89.34% (composition artifact) and 89.8% (selection bounds)
were in circulation simultaneously. None was fabricated; each was locally
defensible over a different denominator, and every existing law checked one
artifact against itself, so none could see the three together.

- **L12** checks artifacts against *each other*, and against the value the
  manuscript renders. Twelve laws now, 37/37 planted defects detected.
- **Protected results** — 32 quantities that must be generated, never typed.
  Nothing had to be converted: the manuscript was already clean.
- **Skip budget** — a new skipped test is a regression unless it is written down.

### Fixed — a required CI check reported success in 6, 8 and 10 seconds while evaluating nothing

On three consecutive pull requests the science-law coverage job took a path
filter's fast path, skipped every law step by an `if:`, and exited zero. The tick
was green, the required status was satisfied, and duration was the only external
evidence that anything was wrong.

`Scientific gate` now refuses a pull request unless every component **ran** and
succeeded — skipped, cancelled, missing and exited-zero-having-done-nothing are
each distinguished from PASS. And the laws run unconditionally on every pull
request, because a fast path and a required gate cannot both be right.

## [Unreleased] — 2026-08-29 — Board verification retracted, and the laws start reporting honestly

### Retracted — "11,355 midwives board-verified across 40 states" → 374, in one state

Most purported state Board-of-Nursing licence numbers in this repository were
**synthesized from `certification_number`** rather than observed from a board.
Two templates, `{STATE}-RN-CNM-{cert}` and `{STATE}-RN-APRN-{cert}`, are
re-encodings of the AMCB identifier with a state prefix. Of eleven "Tier 1"
states only Washington and Florida had a Socrata endpoint configured at all; the
other nine were `None`.

| artifact | synthetic | genuine |
|---|---|---|
| `scraped_40_state_bons_midwives_master.csv` | 11,355 / 11,355 | 0 |
| `scraped_20_state_bons_midwives_master.csv` | 9,037 / 9,037 | 0 |
| `tier1_live_bon_all_states_complete.csv` | 4,746 / 5,120 | **374** |
| `tier1_tier2_combined_bon_validated_master.csv` | 4,746 / 5,120 | **374** |

Genuine observed board evidence is **374 Washington DOH `credentialnumber`
records**, corroborated independently by `live_wa_bon_summary_matrix.csv`.

**Identity linkage is not affected and requires no recomputation.** Traced
read-only across the repository: no R code reads `tier1_license_number`,
`scraped_license_num`, `bon_verification_status` or `tier1_verification_source`;
the synthesized values never entered candidate generation, never resolved an NPI
ambiguity, and never changed FROZEN membership. Every `npi_match_method` in the
FROZEN crosswalk is name-derived.

What *is* affected is reported board-verification coverage. The prior debate in
`docs/DECISIONS_CONTRACT.md` D12 — whether 74% state-board coverage is reportable
given non-random state selection — was arguing about the wrong thing: observed
coverage is **3.3%, Washington only**. The availability-sample caveat is not the
issue; the numerator is.

`README.md` is corrected: the Figure 1 caption no longer says "verified", the
header table now separates *permalinks to a board* from *checks against one*, and
a new figure plots claimed against observed. Full account in
`docs/PROVENANCE_DEFECT_BON_LICENSE_IDENTIFIERS.md`; per-path inventory in
`artifacts/bon_contamination_inventory.csv`.

### Fixed — five laws had been crashing, and coverage called it "no subjects"

Every nightly from 2026-08-26 reported L5–L10 as having no subjects. Two causes,
and the second is a defect in the coverage gate rather than in the laws.

L6–L10's gates call dplyr, readr, stringr, readxl, sf, DBI and duckdb, but the
science job deliberately installs no packages, so all five **crashed instantly**
with "no package called X". That crash text matched neither the EXERCISED nor the
SKIPPED marker, so it was counted as a vacuous pass rather than surfaced as the
error it was. A scoped install step for exactly those seven packages was added,
with the deviation from the job's base-R-only design documented: rewriting
spatial, SQL and xlsx logic in base R was judged higher-risk than installing the
packages.

**The gate could not tell a crashed gate from a silent one** — `run_file()`
captured output but discarded the exit status, so both read as "no subjects".
The build failed, correctly, but named the wrong cause. Now fixed: a non-zero
exit *with no `[LAW]` markers* is reported as CRASHED, with the last lines of
output.

A non-zero exit alone is deliberately **not** treated as a crash. A gate that
evaluates its law and finds a violation also exits non-zero, and that is a
working gate reporting a real result — coverage asks whether a law was *checked*,
not whether it passed. Calling that a crash would turn every genuine law failure
into a false diagnosis. Three controls hold both halves of the rule.

### Changed — L5 reclassified `private-ok`, closing D7

L5's dissolved isochrone surface is gitignored, so the law could never run on a
fresh checkout while registered `public`, where a skip is a failure. It is now
`private-ok`.

This closed D7 by the route D7 argued against: `private-ok` means "may skip when
person-level data is absent", and this input is not person-level — it is a
derived surface excluded for size. The build went green and L5 became
unevaluated on every runner, counted as an *expected* skip.

**Now resolved with a fourth state.** `derived-ok` means *pipeline-derived input
excluded from version control for size*, and makes no claim about privacy. L5 is
registered under it, and coverage reports

```
  Laws exercised:              9/10
  Expected private skips:      0
  Expected derived skips:      1   (L5 -- not enforced on any runner; see DEBT.md D9)
  Unexpected skips:            0
```

Rebuilding the surface in CI was ruled out rather than chosen: it is 31 MB and
built from the private `~/isochrones` checkout, which no runner has. **The
enforcement gap is unchanged. What changed is that it is now labelled honestly
and counted in the open**, instead of being absorbed into a category that sounds
unavoidable. Six controls, including one proving `derived-ok` cannot launder a
`public` law's skip.

### Added — CI hardening and a cross-repo checklist

- A FROZEN-dependency check: `verify_osmde_full_cohort_coverage.R` read two
  FROZEN artifacts without being in `REBUILD_ORDER`, so a re-freeze would have
  left it holding a stale cohort.
- `docs/CI_BEST_PRACTICES.md`, merged with the `isochrones` copy into one
  canonical superset.
- The leak guard's exception list split into false positives versus reviewed
  real exceptions (`tests/ci_leak_reviewed_exceptions.txt`).
- A live Washington BON cross-reference using the tracked roster as a substitute
  cohort, and the 50-state + DC scraped roster committed.
- `tests/verify_replay_equivalence.sh`: the replay-equivalence experiment as a
  runnable file. It previously existed only as a scratch script, so the custody
  claim in the previous section could not be re-checked by anyone.

---

## [Unreleased] — 2026-08-25 — Laws about the science, and a population that escaped its frame

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

### Fixed — the Florida voter extract had no gitignore protection at all

`match_florida_voter_ages.R` has looked for a Florida statewide voter file at
`artifacts/fl_voter_extract.{csv,txt,csv.gz,txt.gz}` since it was written, but
none of those paths were gitignored. Name plus full date of birth for every
registrant in the extract — not just the midwives matched out of it — was one
`git add -A` away from being tracked, the same Tier 1a sensitivity as the Ohio
and Washington DOB files already carved out above them in `.gitignore`. Added
before any extract file has ever existed on disk, so nothing was ever at risk;
the gap is closed rather than a leak cleaned up.

### Added — permanent regression coverage for two decades of NPPES format drift

Ten adversarial fixtures — an accented name under an ASCII header, a
whitespace byte, a missing column, a lowercase taxonomy code, an
unrecognisable schema, a duplicate-year file, a renamed-column era, a stale
lock, and a lock genuinely held by a live process — were run by hand against
`build_midwife_panel.R` (2026-08-27) and all ten passed. Promoted to
`tests/test_build_midwife_panel.R`, wired into `ci.yml`, so the next NPPES
format change is not free to break one silently.

The December 2024 NPPES format change ("reshaped" files) that motivated the
bug hunt was itself validated rather than assumed correct: the reshaped-path
extraction of the December 2024 snapshot matches the production panel's
original-path extraction of the same snapshot on all 393,409 rows, zero
mismatches on NPI, `tax_class`, or `last_name`. See
[`docs/TECHNICAL_APPENDIX_PANEL_BUILDER_HARDENING.md`](docs/TECHNICAL_APPENDIX_PANEL_BUILDER_HARDENING.md).

### Documented — AMCB `certification_date` is a renewal date for 0.9% of linked certificants

Joining ACTIVE certificants to their first observed year as a midwife in the
panel, 104 of 11,354 (0.9%) already appear under a midwifery taxonomy in
NPPES *before* their AMCB `certification_date` — by as much as 18 years. All
104 remained continuously observable as a midwife through 2026, which is the
signature of an ongoing practitioner, not a linkage error. The far more
plausible reading is that `certification_date` is, for this subset, a
renewal or recertification date rather than the original one, and the public
verification directory does not distinguish the two.

**Impact: Table 1's "Years Since AMCB Initial Certification" is a slight,
one-directional underestimate for this ~0.9% of the cohort** — it can only
understate tenure, never overstate it. This is a limitation of the AMCB
roster as a source, not an artifact of this project's linkage, and is now
recorded rather than silently absorbed into the tenure variable. Same
appendix as above, §4.

### Changed — geographic-persistence manuscript retargeted to *Midwifery* (Elsevier)

`manuscript/midwife_persistence.qmd` was built for *Obstetrics & Gynecology*
(the Green Journal); Introduction and Materials and Methods are rewritten for
*Midwifery* (Elsevier, impact factor 2.7, Q1) — the highest-impact journal
specifically in the midwifery discipline, as opposed to O&G's higher overall
but discipline-adjacent impact factor. Concretely: the structured abstract
now uses the journal's own Background/Aim/Methods/Findings/Conclusion
headings (verified against real *Midwifery* retrospective-cohort papers via
Europe PMC, not assumed); references switched from the Green Journal's CSL to
`manuscript/midwifery-journal.csl` (Elsevier/Vancouver, numbered); four
citation placeholders in `references.bib` that previously read `[CITATION
NEEDED]` were resolved to real, Europe-PMC-verified sources rather than left
or invented; and `manuscript/highlights.qmd` was added, since *Midwifery*
requires Highlights (3-5 bullets, ≤85 characters) as a separate submission
document in place of the Green Journal's title-page Précis.

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
