# Technical Appendix: The PUBLIC/PRIVATE-OK Data Regression Guard

**Repository**: `midwifery`
**Primary script**: [`tests/ci_data_regression_guard.R`](../tests/ci_data_regression_guard.R)
**Ported from**: `mufflyt/isochrones`, `tests/testthat/test-data-regression-daily-guard.R` (2026-08-27/28)
**Enforcing job**: `r-checks` ("R hygiene and join keys") in [`.github/workflows/ci.yml`](../.github/workflows/ci.yml)
**Skip budget entry**: [`tests/skip_budget.tsv`](../tests/skip_budget.tsv)
**Added**: 2026-08-31
**Status**: every check below reads a committed artifact and is exercised on every push and pull request.

---

## 1. Why this exists

`tests/ci_artifact_contracts.R` already asks whether one published table is
internally coherent — Table 1's blocks sum to the cohort, a suppressed cell is
not a zero. This guard asks a different, complementary question: does the
data *committed to the repository* still say what it said, and do two
*independently-generated* artifacts that describe the same fact still agree
with each other. A join that fans out, a filter that flips, or a rebuild that
silently drops a disposition can leave every existing gate green while the
number a reader actually cites has moved. Neither ratio check nor internal
consistency check catches that — only comparing today's committed data
against yesterday's, and against a second artifact deriving the same fact by
a different route, does.

`mufflyt/isochrones` wrote exactly this guard the same weekend, after `#147`
in that repository silently moved a cohort count by touching only one
matching-rule file, with no sidecar or gate able to say so. The design —
classify every input as **PUBLIC** or **PRIVATE-OK**, and never let a skip on
a PUBLIC input read as a pass — transfers directly, since this repository has
the same shape of gitignored person-level data sitting behind committed
aggregate artifacts.

## 2. PUBLIC vs. PRIVATE-OK

**PUBLIC** — committed to the repository, must be present on any checkout
that has `tests/ci_data_regression_guard.R` at all. A missing PUBLIC artifact
is `ci_fail()`, never `ci_skip()`: the whole point of this guard is that a
committed file going missing between one commit and the next is itself the
regression, and a check that quietly skips when its input vanishes is
indistinguishable from a check that never ran.

**PRIVATE-OK** — gitignored by design (certification numbers, names, NPIs —
person-level). Genuinely absent on CI and on a fresh checkout; present only
on a machine that has run the real linkage pipeline. A skip here is the
correct, expected outcome, and is registered in `tests/skip_budget.tsv` (two
skips expected in the `lean`/bare-checkout environment, zero in `full`) so
that budget's own SB1/SB2 checks hold this guard to the same standard as
every other gate in the repository.

## 3. What each check pins, and what would have to break for it to fire

| # | Check | Fires when |
|---|---|---|
| D1 | `linkage_manifest.json`'s 7 dispositions sum to its own `total_rows` (22,309) | The manifest was hand-edited, or regenerated without updating `total_rows` |
| D2 | Those same 7 dispositions agree **exactly** with the independently-written `linkage_completeness_by_status.csv` | A rebuild of one script moved without the other — two artifacts describing different linkages under one shared name |
| D3 | `amcb_npi_linkage_FROZEN.csv.manifest.json`'s `class5_candidates_held_out` (156) agrees with `linkage_manifest.json`'s count of the same disposition; `artifact_rows` stays in a 20,000–25,000 band | A refreeze silently dropped or duplicated the class-5 accounting, or produced an implausible roster size |
| D4 | Every `composition_*.csv` group's `n` sums to its own `N`; `pct` closes to 100 | A code change drops a level, double-counts a row, or divides by the wrong denominator, generalized across all 5 composition files |
| D5 | Every Manski bound triple in `linkage_selection_bounds.csv` is ordered lower ≤ observed ≤ upper | A swapped min/max, a flipped filter, or a wrong-direction denominator produces a numerically valid but logically inverted bound |
| D6 | README.md's cited "22,309" roster count matches `linkage_manifest.json` | Doc-vs-data drift: the data moved and the prose did not |
| D7 | The frozen 16,892 (`INPUT_FINGERPRINT.json`, geography-guard freeze) stays pinned and distinct from the FROZEN manifest's 16,898 (a later refreeze) | Either point-in-time record moved, or the two were silently collapsed into one number — the isochrones "retired cells" pattern, applied here to two of this repository's own frozen counts |
| D8 | *PRIVATE-OK.* `amcb_npi_linkage_FROZEN.csv`, if present: `certification_number` unique, `npi` values 10-digit | Only checked on a machine with the real person-level crosswalk |
| D9 | *PRIVATE-OK.* `frozen_cohort/analytic_cohort.csv`, if present: plausible row count, no duplicate certificants | Same as D8 |
| D10 | A 20-file sample of the 97 tracked `.provenance.json` sidecars is valid JSON with the `write_with_provenance()` schema and 64-hex-char sha256 hashes | A change to `write_with_provenance()` drops a field or writes a malformed hash |

## 4. Two defects found while building it, unrelated to its own purpose

Building D6 and D7 required directly re-verifying the numbers they pin
against the currently-committed artifacts, which surfaced two stale figures
already in `README.md` that this guard does not itself check (they are not
the roster total D6 pins, but nearby prose citing the same underlying
linkage): "65.8%" (three occurrences) and "78.0%/18.6%" (ACTIVE/DECEASED
cohort resolution), both corrected to the currently-true 66.2% and 78.4%/
18.8% — see `NEWS.md`, 2026-08-31.

A larger block of detailed worked-example counts further down `README.md`
(built around an `11,920`-primary-tier ACTIVE figure, which the current
committed data gives as 11,981) was **not** re-verified or corrected in this
pass. Fixing it correctly requires re-deriving several interdependent
sub-calculations (RETIRED/LAPSED breakdowns, an NPPES-geography count), which
is a larger, separate task than this guard's own scope — flagged here rather
than fixed under time pressure with a real risk of introducing a new,
harder-to-spot error.

## 5. What this does not establish

Same limitation as `ci_artifact_contracts.R`'s own A3 (provenance coverage):
this guard reads whatever is currently committed and cross-checks it against
itself and against a second artifact. It cannot detect a defect present
**identically** in both artifacts being compared (a shared upstream bug that
both D2's two files inherit, for instance), and it cannot detect a defect
introduced and then correctly propagated everywhere at once — only a defect
that leaves two things that used to agree, disagreeing, or a thing that used
to exist, absent.
