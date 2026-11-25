# Dependency reproducibility report (spec Part 5.1 + 5.2)

Date: 2026-11-24. Scope: midwifery repo dependency management.

## 5.1 TEST_COVERAGE.md — already resolved

`TEST_COVERAGE.md` is **not** a live coverage report; it is the 2026-08-07
origin proposal, already relabeled as such at the top of the file ("origin
proposal (historical) ... not a live coverage report"). It preserves the
design rationale, points readers at the real coverage sources
(`tests/ci_*.R` gates wired into ci.yml/nightly.yml, `tests/test*.R|py`),
and no longer masquerades as current. References from `ARCHITECTURE.md` and
`README.md` are accurate. **No action needed; no coverage percentages were
fabricated.**

## 5.2 R dependency manifest — investigation result

### What exists today

| Mechanism | Where | What it pins |
|---|---|---|
| Dated CRAN snapshot | `.Rprofile` (`options(repos = ...)`) | All CRAN packages resolve to Posit Package Manager snapshot **2026-10-19**, with the `__linux__/<codename>/` segment so Linux runners get binaries, not source builds. Applies to CI, nightly, and local installs identically. |
| GitHub SHA pin | `.github/workflows/ci.yml:495`, `nightly.yml:175` | `mysterynpi@03469aed868ea6af1e429b1da033915e49010dc7` (0.11.0, `phrase_key()`), installed via `remotes::install_github`, with an exports assertion (`strip_med_suffix`, `phrase_key`, `compact_name_key`) that fails loudly if the pin moves. |
| Per-test package guards | throughout `tests/` | Tests declare and check their own deps; missing person-level inputs skip rather than fail. |

### Gap analysis vs renv

renv would add: per-package transitive lockfile, `renv::restore()` byte-level
reproducibility, and drift detection on `renv::snapshot()`. What it would
cost here:

- Every workflow's install blocks (ci.yml has ~6 separate
  `install.packages(missing)` sites plus the mysterynpi pin; nightly has
  ~5) would need conversion to `renv::restore()` + activation changes.
- The `.Rprofile` snapshot pin would conflict or need removal — renv and a
  global repos override do not compose cleanly.
- A lockfile must not be committed until `renv::restore()` is verified in an
  isolated environment (spec requirement). That verification has not been
  run; doing it is a half-day-plus task touching every CI job.
- Person-level scripts install ad-hoc packages at runtime; renv's isolated
  library would change behavior for contributors who run scripts outside
  the test suite.

### Recommendation

**Defer renv adoption; it is a workflow decision for the PI, not an
engineering fix.** The dated-snapshot + SHA-pin combination already makes
dependency versions traceable and reproducible at the level this project's
CI actually exercises. The marginal gain (transitive-dep byte precision)
does not justify rewriting six install sites and the activation model
inside this workstream. If adopted later, the snapshot date in `.Rprofile`
is the migration anchor: snapshot it into `renv.lock` at 2026-10-19 so no
package silently upgrades during the transition.

## 5.3 Isochrones path — fixed (this branch)

`R/13-geocode-ob-hospitals.R` hardcoded
`/Users/tylermuffly/isochrones/data/geocoding_cache.duckdb`. It now resolves
the checkout through the existing `isochrones_home()` (`ISOCHRONES_HOME`
env var, else `~/isochrones`) and fails closed inside `run_geocode()` when
the cache is absent — checked lazily so sourcing the file for its
functions never requires the external repo. Covered by
`tests/test_geocode_ob_hospitals_cache_path.R` (temp-dir valid/missing/
next-gate cases), wired into ci.yml. No geographic methodology changed;
`isochrones` repo untouched.

## 5.4 mysterynpi worktree — done

`.worktrees/m1-similarity` was on `master`, clean, **74 behind / 0 ahead**
of `origin/master`. Fast-forwarded to `03469ae` (the pinned `phrase_key`
commit). Other worktrees (`mysterynpi-split-given-fix`, `parity-fix`,
`pr-d`, `release-gate`, `npi-clean`, `nickname-consolidation`) have their
own branches and were not touched.

## 5.5 Stash reconciliation — stash@{0} eligible, awaiting approval

`stash@{0}` ("WIP: amcb-license-bridge edits parked while merging
fix/table1-custodian-sort", base `fd2eca5`) touches 14 files. Every
substantive change is **already in HEAD in evolved form**:

- `amcb_license_bridge.R`, `expand_former_name_candidates.R`,
  `R/build_amcb_state_licenses.R` and their tests: the stash delegated
  `normalize_text()` to a local `normalize_phrase_key()` wrapper; HEAD
  (PR #348, merged `19d27b1`) delegates directly to
  `mysterynpi::phrase_key` — the same change one iteration later.
- `tests/test_expand_former_name_candidates.R` is byte-identical to HEAD.
- The two provenance sidecars are the versions restored to HEAD content by
  `e2413ce` (the stash carried the merge-marker-corrupted copies).
- `ci.yml`, `DEBT.md`, `NEWS.md`, `README.md`,
  `manuscript/R/build_stats_catalog.R`, `federal_database_accuracy.qmd`:
  doc/config edits that landed through the merged PRs in newer form
  (the stash patch does not apply to current HEAD, which is expected — it
  is a parked intermediate, not lost work).

**Verdict: recoverable — nothing unique remains. Eligible for deletion
only with explicit user approval; NOT dropped.**
`stash@{1}` ("provenance sidecars (gate churn)") and `stash@{2}` (cycle-37
WIP) were not audited in this pass.
