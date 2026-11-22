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
copy, and the copies have diverged by roughly 250 lines of local history. The
anti join fix was applied to the isochrones copy first. The midwifery copy
still had the missing call and the false `@section Algorithm` sentence, so the
act of fixing one of four wrappers immediately produced one fixed copy of two.

Both copies now carry the fix and a parity test, and each file's test names the
other in a `TWIN FILE` header. No mechanism keeps them synchronized. The
options were a shared package, a continuous integration gate diffing the two
working trees, or a comment in each file. A package is the right answer and is
not justified by one function; a cross repository diff gate cannot run in
either repository's continuous integration, because neither checks out the
other. The comment is what is deployed, and it is deliberately weak: it tells
the next person where the twin is, and nothing enforces that they look.

## The gate, and the hole found while wiring it

The test asserts **parity across all four wrappers**, not the behaviour of
`safe_anti_join()`. Testing only the function that broke would reproduce the
defect: the bug was that one of four diverged, so the assertion has to be that
four of four agree.

- midwifery: `tests/test_safe_join_key_harmonization.R`, named by `ci.yml`,
  registered in the `ci_entrypoints` list in `tests/ci_repo_integrity.R` so the
  package gate follows its `source()` chain, and also swept by the
  `tests/test*.R` glob in `nightly.yml`.
- isochrones: `tests/ci/test-safe-join-key-harmonization.R`, named by
  `fast-gates.yml` as gate 3c.

The isochrones path was not the obvious one. The test was first written at
`tests/test_safe_join_key_harmonization.R`, which is tracked, passes locally,
and **is executed by nothing**: no isochrones workflow globs that directory.
The repository has a ratchet for precisely this failure,
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
- `agree_on` / `agree_map`, `max_right_dup_keys` on the left join path, and
  `max_duplication` and `max_right_dup_keys` on the semi join path were
  accepted and never read. They now stop with a message naming what is actually
  enforced instead of returning a silent pass that reads as agreement.
- The `safe_left_join()` documentation stated that `use_enhanced_metrics`
  defaults to `TRUE` and delegates to a richer validation path. The default is
  `FALSE`, and `TRUE` stops, because the module it delegates to has never
  existed in this repository. A reader of `?safe_left_join` was told a
  validation path runs that cannot run.

## What this does not claim

The parity test proves that four wrappers coerce a character key against an
integer key, on one key column, in one direction of mismatch. It does not prove
that coercion to character is the right harmonization for every type pair, and
it does not test a named `by` vector or a `dplyr::join_by()` specification,
where `harmonize_join_key_types()` resolves column names differently and
degrades to doing nothing. That degradation is shared by all four wrappers, so
it is not a divergence, and it is not covered.
