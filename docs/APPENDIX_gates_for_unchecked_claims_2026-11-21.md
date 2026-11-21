# Appendix: gates for claims nothing was checking (2026-11-21)

Three suites were added in one session, 31 saboteurs and 97 assertions, each
one wired to a claim this repository already made and nothing read back.

| suite | prefix | saboteurs | assertions | runtime | what its claims are about |
|---|---|---|---|---|---|
| [`tests/test_claim_integrity_saboteurs.R`](../tests/test_claim_integrity_saboteurs.R) | `R` | 10 | 31 | 31s | what the repository says about **itself** |
| [`tests/test_doc_integrity_saboteurs.R`](../tests/test_doc_integrity_saboteurs.R) | `D` | 10 | 35 | 25s | what its **documentation** says about the tree |
| [`tests/test_provenance_integrity_saboteurs.R`](../tests/test_provenance_integrity_saboteurs.R) | `M` | 11 | 31 | 16s | what the **pipeline** says about the data it moves |

The premise is the one the previous appendix ended on. That one
([APPENDIX_checks_that_cannot_fail_2026-11-20.md](APPENDIX_checks_that_cannot_fail_2026-11-20.md))
was about assertions that could not fail. This one is about claims with no
assertion at all: a badge, a figure caption, a status table, a line-number
citation, a provenance sidecar. Each reads as true, each is mechanically
checkable, and each was checked by nothing.

## What the three batches gate

### Batch 1 — the repository about itself (`R`)

| | claim | surface |
|---|---|---|
| R1 | a job that globs `tests/test*.R` installs every package those tests load unguarded | 1 globbing job |
| R2 | naming a test in a job installs its packages too | 20+ named tests |
| R3 | every file the README links to exists | 148 links |
| R4 | no testthat-dispatched test resolves its root from the working directory | 5+ files |
| R5 | no two figures carry the same number, and the numbering is dense | 20 figures |
| R6 | the scientific-laws badge matches `tests/science_law_registry.tsv` and the prose beside it | 13 laws |
| R7 | no Python helper is defined twice outside a 26-name baseline | 77 files |
| R8 | no suite heads two saboteurs with the same label | 13 suites |
| R9 | every baselined path is tracked or deliberately ignored | 374 entries, 11 files |
| R10 | every suite's declared saboteur count matches the saboteurs it runs | 13 suites |

Plus a check inside [`tests/ci_law_coverage.R`](../tests/ci_law_coverage.R),
placed there because the numbers exist only in that run: the README's badge
**and** its prose must both state the law count and the planted-defect count
that the mutation run actually measured.

### Batch 2 — the documentation about the tree (`D`)

| | claim | surface |
|---|---|---|
| D1 | a status table's DONE / NOT DONE verdict matches the tree | 22 rows, 41 paths |
| D2 | a `file.R:123` citation points inside that file | 77 of 89 resolvable |
| D3 | a markdown link resolves to something git knows | 463 links, 99 files |
| D4 | an in-document anchor names a heading in its own file | 33 anchors |
| D5 | the law registry's gate and mutation files are tracked | 13 laws, 10 files |
| D6 | a table row has as many cells as its header | 396 tables |
| D7 | every fence the corpus opens is closed | 878 fenced lines |
| D8 | every baseline, budget and exception ledger is opened by a script | 15 ledgers |
| D9 | no action is used at two different versions | 43 uses, 5 actions |
| D10 | a script a documented command runs exists | 178 commands |

### Batch 3 — the pipeline about its data (`M`)

| | claim | surface |
|---|---|---|
| M1 | every tracked artifact is named somewhere in the tree | 354 artifacts, 978 tokens |
| M2 | a sidecar's `artifact` field names the file it sits beside | 304 sidecars |
| M3 | a repository-relative input path is tracked or deliberately ignored | 834 entries |
| M4 | the documented count of null `code_sha256` equals the measured count | stated twice |
| M5 | no sidecar outlives its artifact | 304 sidecars |
| M6 | a sidecar's timestamp is well-formed and not in the future | 302 of 304 |
| M7 | a recorded input hash is 64 lowercase hex digits | 954 hashes |
| M8 | loading every `tests/helper-*.R` in testthat's order raises no error | 9 helpers |
| M9 | every literal `source()` target exists, read from the parse tree | 105 targets |
| M10 | the numbered pipeline has no duplicate and no gap | 15 stages, 1–15 |
| M11 | every suite `RUN_REGRESSION_TESTS.R` names is tracked | 26 suites |

## Defects found and fixed

The verdicts below are quoted unbolded on purpose: `D1` reads a **bolded**
status token in a table row as a live claim about the path beside it, so an
appendix that recorded them in bold would assert the very things it is
reporting as corrected. The gate caught that on this file's first draft.

| where | the claim | the measurement |
|---|---|---|
| `README.md` badge area | **37** planted defects detected | the run measures **39**; the badge said 39, the prose said 37 |
| `README.md` figure captions | Figures 16–19 | two pictures numbered 16; renumbered 17–20, and the in-text pointer with them |
| `tests/ci_frozen_staleness_baseline.txt` | 112 forgiven paths | one was deleted in `0703513`; the file's own rule is that it may only shrink |
| `docs/spec-completion-matrix.md` §11 | `longitudinal_reconstruction_audit.csv` read "NOT DONE / MISSING" | tracked, built by `build_longitudinal_reconstruction_audit.R`, 63 source-years × 12 columns |
| `docs/spec-completion-matrix.md` §12 | `longitudinal-reconstruction-changelog.md` read "NOT DONE", section "3 of 4" | tracked, 92 lines; the section is 4 of 4 |
| `docs/spec-completion-matrix.md` row 13 | **79** sidecars carry `code_sha256: null`, stated twice | **80** — 75 under `artifacts/`, 5 under `data/`; the population was never stated, so neither reading matched |
| `artifacts/dac_hospital_affiliation_summary.csv.provenance.json` | an input at `data/facility_affiliation_refresh/…` | neither tracked nor ignored; it is a CMS download, now deliberately uncommitted |

## Candidates measured and dropped

The record of what **not** to gate is the more useful half, because each of
these looked obvious and was wrong. Thirteen were measured and dropped.

| candidate | measurement | why it was dropped |
|---|---|---|
| dead `ENV` feature flags | — | the honest version of the check is too weak to be worth a gate |
| all 216 tests named in `ci.yml` | 83 named | overstated: ~130 are night-only by design |
| package-list drift between jobs | — | `ci.yml` may legitimately install for a test nightly excepts from its glob |
| a gate no workflow invokes | — | nightly's `suite-coverage` already asserts it |
| duplicate `chk()` message text | 19 suites | most repeats are legitimate |
| every commit SHA a doc cites resolves | 1 of 11 does not | `CI_BEST_PRACTICES.md:1405` cites `a631aa226` in `mufflyt/isochrones`, naming that repo in the same sentence |
| every path `DEBT.md` cites exists | 11 do not | a debt ledger is where they should not: one names an upstream file, another an artifact deliberately deleted on withdrawal |
| every `docs/*.md` is linked from another doc | 14 are not | drift, not a claim the repository makes anywhere |
| every `*_detect.R` is in the law registry | 6 are not | correctly: they detect for gates, and the registry is for laws |
| every tracked `ci_*.R` is named in a workflow | 6 looked unrun | all six are run by `nightly.yml` under a path form the first scan missed |
| dead `.gitignore` rules | 447 of 463 "dead" | the scan was wrong, not the rules: ignore patterns apply recursively, and there is no reverse `check-ignore` |
| duplicate top-level constants | 180 in 2+ files | `ci_hygiene` H4 forbids that for FUNCTIONS, where copies diverge in behaviour; a per-script path constant is this pipeline's idiom |
| every recorded input hash still matches its file | 97 of 280 do not | almost all `live_*_bon_ingested_*.csv`, re-ingested every run: a sidecar records the hash its artifact was BUILT FROM |
| every function under `R/` is called somewhere | 15 are not | dead code is a complexity finding, not a false claim |

## Eight errors the gates caught in their own first drafts

Every one of these was a gate failing on correct code, found by running it
rather than by reading it. They are the reason the suites carry the comments
they do.

1. **A text scan for `[A-Za-z.]+::`** reported `CA` and `TX` as packages.
   `"CA::012345"` is a license-key string literal. R's parser
   (`SYMBOL_PACKAGE` tokens) is exact; a regex over source text is not.
2. **A parse-tree walker read the first argument as a package name.** For
   `tibble::tibble(x)` the head of the call is itself a `::` call, so
   `as.character(e[[1]])[1]` is `"::"`. Guard with `if (is.name(e[[1]]))`.
3. **The same walker crashed on `x[, 1]`** — `for (k in as.list(e))` binds the
   missing argument, and binding an empty symbol errors. Recursion goes
   through `lapply`, which never binds. This mistake was made **twice**, four
   hours apart, in two different walkers.
4. **A guard detector missed the symbol form.** `vapply(c(...),
   requireNamespace, ...)` never calls `requireNamespace`, so a clean skip was
   reported as two missing packages.
5. **A slug function collapsed runs of spaces** and called two correct README
   anchors broken. GitHub drops the `&` in "Key Visualizations & Data Gallery"
   and keeps **both** its spaces: `key-visualizations--data-gallery`.
6. **A DONE predicate of "tracked or gitignored" failed on eight true
   claims.** Four of those CSVs are real outputs of tracked producers that no
   `.gitignore` rule happens to name. Source files and data artifacts need
   different predicates, because this repository never generates a `.R`.
7. **A negative control named its sentinel in plain text** inside the file the
   gate itself reads. It passed while untracked and failed the moment it was
   staged. The sentinel is now assembled from pieces.
8. **A markdown cell counter split on pipes inside code spans**, reporting
   four ragged tables that were all `%||%` written in backticks.

## Two defects this session introduced, and what caught them

Neither was caught by re-reading. Both were caught mechanically.

**`tests/helper-repo-scan.R` silenced all 16 testthat files in `tests/`.**
testthat sources every `tests/helper-*.R` **alphabetically** before it runs
any test file in the directory. The new helper sorted before
`helper-saboteur.R` and read `SAB_ROOT` at load time: `object 'SAB_ROOT' not
found`. Nothing reported an error. The files reported *no testthat summary
line at all*, and [`tests/ci_skip_budget.R`](../tests/ci_skip_budget.R) —
which counts skips by parsing that line — called 16 gates over budget with
"produced no testthat summary line, so its skips could not be counted".

The fix is the name. [`tests/lib_manuscript_numbers.R`](../tests/lib_manuscript_numbers.R)
already set the convention: a file that suites source explicitly is `lib_`,
not `helper-`. Making the helper self-sufficient instead would run
`git ls-files` once per testthat file — 213 subprocesses to serve two callers
that source it directly. `M8` is now that defect's gate, and it loads all
nine helpers in one process in alphabetical order, because an ordering defect
is only reproducible in order.

**A `git add` that staged nothing, silently.** The rename commit landed the
file move and nothing else — `1 file changed, 0 insertions(+), 0 deletions(-)`
— because `git add` was given a pathspec list that still named the old path.
Git refuses the whole command when one pathspec matches nothing, and a
`2>/dev/null` on it hid the refusal. Both suites went on sourcing a file the
same commit had renamed away. Silence from a staging command is not success,
which is the same shape as the defect above.

## Mutation proof

Every one of the 31 saboteurs was proved by breaking the claim it gates,
watching the gate fire, restoring the tree, and confirming the suite came
back clean. A gate that has never been seen to fail is a guess about a guess.

```
R1..R10   10 of 10 KILLED      (batch 1)
D1..D10   10 of 10 KILLED      (batch 2)
M1..M11   11 of 11 KILLED      (batch 3)
```

Two of those runs are worth recording, because the mutation was wrong rather
than the gate.

**`R3`'s first mutation was a no-op.** It replaced a README mention of
`(tests/ci_hygiene.R)` that does not appear in the README at all, so the gate
stayed green for the right reason and the run proved nothing. The grep used
to confirm firing was also wrong: `FAIL` is followed by one space in this
harness's output, not three, so silence read as success.

**`M9`'s first mutation broke syntax instead of a path.** It inserted a
`source()` call after the shebang's `#!`, which split
`/usr/bin/env Rscript` onto its own line. That is a parse error, so `M9a`
("every tracked R file parses", 654 of 655) fired and `M9c` ("every sourced
file exists") never got the chance. Appending the call at end of file proved
`M9c` directly, with `M9a` still green. The accident did prove `M9a`.

## Design rules these suites follow

- **Measure before writing.** Thirteen of the 44 candidates considered were
  dropped after measurement. A gate written from a plausible premise fires on
  correct code, gets ignored, and then fires on a real defect.
- **Every scan asserts what it found.** `R1a`, `D1a`, `M1a` and their
  siblings assert the surface is non-empty, so a clean result can never be an
  empty one. This is the lesson of the previous appendix restated: a check
  that cannot fail is not a check.
- **Prove each gate by mutation.** Break the claim, watch the gate fire,
  restore the tree, confirm it is clean again. All 31 were proved this way.
- **A positive control for every rule that bit.** `D4d` asserts the `&` slug
  rule, `M6e` asserts the `generated_at` field is read, `D6c` asserts a pipe
  in a code span is text. Each one encodes a mistake that was actually made.
- **A baseline may only shrink, and must be checked for staleness.** `M6d`
  fails if either named timeless sidecar ever gains a timestamp, so the list
  cannot outlive its reason.
- **A gate's verdict must not depend on the runner.** `BASE_PKGS` is a static
  list rather than `installed.packages(priority = …)`, which answers with
  whatever the machine happens to hold.
- **State what the gate does not claim.** `M2` checks that a sidecar names
  the file beside it, not that its hashes describe that file's contents. The
  narrow claim honestly stated is worth more than the wide one implied.

## Known-unresolved

- `README.md:1790` cites "(Figure 20)" for an NDH exclusion-flag figure;
  Figure 20 is the CONSORT flow. The pointer was already wrong before the
  renumbering and was carried, not corrected.
- Two sidecars, `nppes_license_concordance.csv.provenance.json` and
  `nursys_qa_sample.csv.provenance.json`, record no time at all. The fix is
  for their producers to record one on the next write; backfilling from a
  commit date would be inventing provenance to satisfy a gate.
- Three timestamp spellings are in use across producers — `written_utc`,
  `accessed_utc`, `generated_at`. `M6` reads all three. Unifying them is a
  producer-side change and a different task.
- `ci_artifact_contracts` A5 still reports `table1_csv_n=12171` against
  `canonical_n=12170`.
- The §12 row stating the 80-character, `base::message()` and qualified-call
  conventions still reads **PARTIAL** and still names
  `audit_source_series_independence.R`, which does still use unqualified
  `read_csv` and `filter`. `D1` checks a row's cited paths, not whether its
  prose about them is current.
- The 26-name Python duplicate baseline in `R7` is honest but large. Two
  clusters dominate: `download_medicaid_provider_enrollment_segments.py` and
  `hhs_opendata_csv_pipeline.py` share nine functions, and
  `verified_tls_context` exists in four BON harvesters in two distinct
  bodies. The TLS one is security-adjacent and wants a correctness review
  rather than a complexity cut.
