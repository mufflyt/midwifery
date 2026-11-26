# Appendix — one fix, four wrappers, two repositories

**2026-11-21.** `R/join_safety.R` wraps four dplyr joins so that every join in
the pipeline validates its keys, reports coverage, and refuses to proceed when
the match rate collapses. On 2026-04-05 a fix added key type harmonization to
those wrappers. It reached three of them.

`safe_anti_join()` did not get the call, and its own documentation said it had:
the `@section Algorithm` block read "Validates keys, harmonizes types, then
calls `dplyr::anti_join()`", and `harmonize_join_key_types()` was listed in its
`@section Calls`. Both statements were false for seven months.

This appendix records the shape, because the shape recurred twice while it was
being fixed: once inside the file, once across the two repositories that carry
the file. It is a companion to
[`APPENDIX_units_of_analysis_2026-11-21.md`](APPENDIX_units_of_analysis_2026-11-21.md),
which covers the statistics found in the same review, and to
[`APPENDIX_checks_that_cannot_fail_2026-11-20.md`](APPENDIX_checks_that_cannot_fail_2026-11-20.md),
which covers gates that pass for the wrong reason.

## The defect, measured

A character join key against an integer join key is the normal state of this
project's data: a comma separated values file reads a provider identifier as
character, a parquet or serialized R object round trip gives integer or double.
Three of the wrappers coerce both sides and continue. The fourth aborted.

Probed against a clean worktree at `6cb96e0`, with a character key on the left
and an integer key on the right:

```
safe_left_join   ok, 3 rows
safe_inner_join  ok, 2 rows
safe_semi_join   ok, 2 rows
safe_anti_join   ERROR: Can't join `x$npi` with `y$npi` due to incompatible types.
                 i `x$npi` is a <character>.
                 i `y$npi` is a <integer>.
```

The fix is three lines, placed where the three siblings place them, after key
existence validation and before the empty table warnings:

```r
harmonized <- harmonize_join_key_types(left, right, by, label_left, label_right)
left  <- harmonized$left
right <- harmonized$right
```

## Why it survived seven months

Nothing in this repository called `safe_anti_join()` from production code. The
only callers were `tests/test-join-safety.R` and a reference in
`tests/test_cycle9_joins.R`, both of which pass matching key types, so the one
input shape that triggers the abort was never presented. In `~/isochrones` the
production joins route through `safe_left_join()` by convention, which had the
call.

That is the uncomfortable part. The defect was not latent because it was hard
to reach; it was latent because the wrapper nobody used was the wrapper that
lost the call, and a wrapper nobody uses is exactly where documentation drifts
from behaviour without consequence. The complexity audit that found it did not
read the documentation at all: it measured the semi and anti pair at 0.78
structural similarity, flagged them as near duplicates, and the diff between
two near duplicates is where the missing call became visible.

## The same shape, one level up

`R/join_safety.R` is vendored. This repository and `~/isochrones` each carry a
copy, and the copies had diverged by roughly 250 lines of local history. The
anti join fix was applied to the isochrones copy first. The midwifery copy
still had the missing call and the false `@section Algorithm` sentence, so the
act of fixing one of four wrappers immediately produced one fixed copy of two.

## The two copies got different answers, and that is correct

The three-line fix was written for both. Only one of them kept it.

While this branch was being prepared, `main` merged the other half of the same
complexity audit, which asked a question one rung higher than "does this
function do what it says": does it need to exist here at all. In this
repository, `safe_inner_join()`, `safe_semi_join()` and `safe_anti_join()` had
**zero production call sites**. Every caller was a test, and one of those tests
was 500 lines exercising `safe_inner_join()` alone. `main` deleted all three
wrappers, and `tests/test_complexity_cuts_saboteurs.R` now holds the deletion
in place: C1a refuses a tracked file that redefines a deleted wrapper, C1b
refuses a call to one, and **C1c kills a wrapper copied back from the upstream
isochrones copy**, which is exactly the move a reader of this appendix might
otherwise make.

So the resolution is asymmetric, and the asymmetry is the point:

| | midwifery | isochrones |
|---|---|---|
| Production callers of `safe_anti_join()` | none | none |
| Taught to readers | no | yes, `vignettes/joins-that-cannot-fan-out.Rmd` recommends it for seeing unmatched rows |
| Other wrappers used | `safe_left_join()` only | `safe_left_join()` by convention (#6), the others available |
| Resolution | the three uncalled wrappers deleted | the three-line fix, plus a parity gate |

Repairing the documentation of a function nobody calls is work that produces
nothing. Deleting it removes the divergence, the false documentation and the
maintenance surface in one move, and it is why this repository now has one join
wrapper rather than four. The fix belongs where the function is reachable by
something other than its own test suite.

## The gate, and the hole found while wiring it

The test asserts **parity across all four wrappers**, not the behaviour of
`safe_anti_join()`. Testing only the function that broke would reproduce the
defect: the bug was that one of four diverged, so the assertion has to be that
four of four agree. It lives at
`~/isochrones/tests/ci/test-safe-join-key-harmonization.R`, named by
`fast-gates.yml` as gate 3c. It was written here first and is deleted here,
because three of the four functions it names no longer exist in this
repository.

The isochrones path was not the obvious one. The test was first written at
`tests/test_safe_join_key_harmonization.R` in that repository, which is
tracked, passes locally, and **is executed by nothing**: no isochrones workflow
globs that directory. The repository has a ratchet for precisely this failure,
`scripts/ci/check_governed_test_reachability.R`, which refuses to let the set
of tests no workflow runs grow. It did not fire, because its governed corpus is
`tests/validation`, `tests/retirement`, `tests/documentation`, `tests/ci` and
`tests/step67`. A test at `tests/` root is outside the corpus, so the ratchet
cannot see that it is unreachable: the gate against unreachable gates has an
unreachable region of its own.

Moving the file into `tests/ci/` under the governed `test-` prefix and naming
it on a `run:` line resolved it for this test. It is recorded here because the
general case is open: either the corpus widens to include `tests/` root, or
every new gate has to be written inside the corpus by convention, and
conventions are what the ratchet exists to replace.

## Related, same family

Three more findings in `R/join_safety.R` from the same review are of this
family, a declared check that nothing performs, and are recorded in
[`NEWS.md`](../NEWS.md) rather than here:

- `require_complete_keys` was accepted, defaulted to `TRUE`, documented as
  validating key completeness, and read in exactly one branch that cannot run,
  so probing it `TRUE` against `FALSE` over a frame with missing join keys gave
  byte identical results. Removed rather than silently switched on, because
  enforcing it is a behaviour change for every call site and needs its own
  commit and its own test.
- `agree_on` / `agree_map`, `max_right_dup_keys` and `max_duplication` were
  accepted on paths that never read them. The branch made them refuse with a
  message naming what is enforced; `main` got there by deleting the wrappers
  that took most of them and reducing the survivor's unreachable branch to a
  single `stop()`. The merged result is `main`'s.
- `join_coverage_report()` was called positionally, and its signature ends in
  validation thresholds (`min_coverage`, then `verbose`), so inserting a formal
  ahead of `min_coverage` would have slid a threshold into `verbose` silently.
  The surviving call names its arguments, and
  `tests/test_review_fixes_saboteurs.R` R14/R15 parse the file for the shape
  and sabotage it back.
- The `safe_left_join()` documentation stated that `use_enhanced_metrics`
  defaults to `TRUE` and delegates to a richer validation path. The default is
  `FALSE`, and `TRUE` stops, because the module it delegates to has never
  existed in this repository. A reader of `?safe_left_join` was told a
  validation path runs that cannot run.

## What this does not claim

The parity test, in the repository that still has four wrappers, proves that
they coerce a character key against an integer key, on one key column, in one
direction of mismatch. It does not prove
that coercion to character is the right harmonization for every type pair, and
it does not test a named `by` vector or a `dplyr::join_by()` specification,
where `harmonize_join_key_types()` resolves column names differently and
degrades to doing nothing. That degradation is shared by all four wrappers, so
it is not a divergence, and it is not covered.
