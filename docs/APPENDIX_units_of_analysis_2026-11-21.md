# Appendix — statistics whose unit of analysis is not the one they claim

**2026-11-21.** Three defects found reviewing the Green Journal rewrite. They
look unrelated — a SQL aggregate, a bootstrap, a dplyr join — and they are one
error: **a number computed over one population, printed under a claim about a
different one.** None raised a warning. None produced an implausible value.
Two were published.

This appendix records the three shapes, because the shapes recur and the
individual fixes do not generalise. It is a companion to
[`APPENDIX_checks_that_cannot_fail_2026-11-20.md`](APPENDIX_checks_that_cannot_fail_2026-11-20.md),
which covers the other half of the problem: the gate that was supposed to
notice.

## Why this family is hard to see

A unit-of-analysis error is arithmetically valid. Every quantity involved is a
real count of something; the division executes; the result lands in a
plausible range. Nothing in the type system, the test suite or the rendered
output distinguishes "73% of segments carry an NPI" from "there are 0.73
distinct providers per segment" — the two are the same `double`, and only the
column name says which one was meant.

That is why all three shapes below are caught by comparing a statistic to its
**own inputs** rather than by range checks, and why
[`tests/test_npi_rate_and_cluster_saboteurs.R`](../tests/test_npi_rate_and_cluster_saboteurs.R)
states each law as a function and then runs it against the defect as it
actually shipped.

---

## Shape 1 — a share of records whose numerator counts entities

`build_medicaid_npi_population_by_state.R` published, as
`pct_segments_with_npi`:

```sql
ROUND(100 * COUNT(DISTINCT NPI) / COUNT(*), 2)
```

`COUNT(DISTINCT NPI)` counts **providers**. `COUNT(*)` counts **enrollment
spells**. Their ratio is distinct-providers-per-segment. The column name, the
figure axis and the Results sentence all said share-of-segments.

The consequence is not a small bias. It is a function of how many spells a
state files per provider, which varies by two orders of magnitude:

| state | published | true (`COUNT(NPI) / COUNT(*)`) |
|---|---|---|
| North Dakota | 1.04% | **96.83%** |
| Missouri | 1.09% | **96.51%** |
| Colorado | 1.21% | **71.89%** |
| Kentucky | 94.00% | 98.67% |
| New York | 94.60% | 94.60% |

Supplemental Figure S6 showed a file that was empty nearly everywhere. It is
full nearly everywhere, with a genuine low tail (Illinois 28%, Minnesota 34%,
Michigan 43%) and 26 of 54 jurisdictions below the 90% implied by CMS's
10%-missing threshold — which the prose cited and did not apply.

**Why nobody caught it by looking.** The two formulas agree in exactly **3 of
54** states: New Mexico and Oregon, where both are 0 because the file carries
no NPI at all, and New York, where the file happens to hold about one segment
per provider. The prose quoted the minimum — New Mexico and Oregon. The
script's header comment named the top as "New York and Kentucky". **Every
state either document named was drawn from the three where the defect is
undetectable.** Reading the extrema was not insufficient; it was precisely
blind.

**The tell:** a `DISTINCT` in the numerator of a ratio whose denominator has
none. If the denominator counts rows, the numerator must count rows.

---

## Shape 2 — a clustered estimator at a scope where clusters are singletons

`build_f2_f3_uncertainty_denominators.R` existed to correct an independence
assumption: the same midwife appears in up to 14 cells, so Wilson understates
the interval. It resampled NPIs — inside `group_by(source, year)`.

Within one source-year, `agree_cell` holds exactly one row per NPI. Every
cluster had one member. Resampling singleton clusters *is* the i.i.d.
bootstrap, so the correction reproduced the thing it was introduced to
replace.

Two facts in the committed artifact said so plainly, and neither was read:

- `n_npi_years == n_npis` in **all 30 rows**. A clustered design in which the
  cluster count equals the observation count has no clustering.
- `boot_width` averaged **0.98×** `wilson_width` — *narrower* in 23 of 30
  rows. Positive intracluster correlation can only widen an interval. The
  direction was evidence, and it pointed the wrong way for a year.

A midwife is only in several cells once years are **pooled**, so the clustered
interval now reports at `scope = "pooled"`, one row per source, where a
cluster carries 2.4–5.7 NPI-years. Design effects: **1.09× to 2.31×**. The
per-year rows keep Wilson and withhold the bootstrap columns rather than print
a singleton resample as though it meant something.

A second, independent unit error sat inside the same function. The estimator
was a mean of per-NPI means, which weights every midwife equally;
`pct_agree`, printed beside it, weights every NPI-year equally. They differ
whenever cluster size correlates with agreement, so the interval was centred
on a quantity its own point estimate did not report. It is now a ratio
estimator, and the interval brackets its point estimate on all four sources.

**The tell:** a grouped bootstrap whose grouping variable is also unique
within the group. Assert `n_units > n_clusters` before trusting any clustered
width.

---

## Shape 3 — a conditional count that never applied its condition

`n_lost_visible_in_nppes` was built by joining the source records to the
registry at `t + 1`. It never excluded the providers still present in the
source at `t + 1` — the condition its name asserts. For
`medicaid_enrollment` 2018 it reported **9,013** of 9,770 observed
provider-years as "lost" where **106** had left.

Its correctly conditioned sibling, `n_lost_source_but_in_nppes`, is the same
join with the `anti_join` against `followed` that the first one omitted, and
reports 98. The two differ by two orders of magnitude and sat in adjacent
columns of one committed CSV.

Supplemental Table S4 happened to read the correct column, so nothing printed
wrong. That is luck, not design: the stats catalog was already aggregating the
broken one, and it carried the more obvious name. The column is removed at the
producer rather than renamed — `n_lost_source_but_in_nppes` is the quantity
anyone actually wants.

**The tell:** a count whose name contains a condition (`lost_`, `unmatched_`,
`missing_`) and whose value is close to the unconditioned total. Assert that
every such count is bounded by the group it conditions on.

---

## What was added

[`tests/test_npi_rate_and_cluster_saboteurs.R`](../tests/test_npi_rate_and_cluster_saboteurs.R)
— 22 checks, 3 laws, 4 planted defects, 3 near misses, wired into `ci.yml`.
Validated in both directions: 22/22 on the fixed tree, **13 failures against a
clean worktree at `6cb96e0`**, which is the only evidence that a new suite
catches anything.

Two of its checks initially passed *vacuously* against the pre-fix artifact,
because the column they read did not exist yet and `all()` of nothing is
`TRUE` — Shape 4 of the companion appendix, committed while writing the gate
for it. Both now require their columns before asserting.

[`audit_medicaid_npi_coverage.R`](../audit_medicaid_npi_coverage.R) covers
what the gate structurally cannot. The suite checks that the artifact is
consistent with **itself**; it never reads the parquet, and no CI runner can,
because the segments file lives on an external volume. An artifact can be
perfectly self-consistent and describe a file that has since been re-released.
The audit recomputes both formulas from source, prints them beside the
committed values, and exits non-zero on disagreement.

## The gates were unwired in the same branch that fixed the defects

The worst instance in this sequence is not a gate that failed, aborted or
passed vacuously. It is three gates that stopped existing.

`579950c`, the merge of #336, took `main`'s `.github/workflows/ci.yml`
wholesale. Three steps lived only on this feature branch, so there was nothing
to conflict with and nothing to report:

| step | at `afad4c2` | at `579950c` |
|---|---|---|
| `ci_denominator_contracts` (D1-D5) | wired | **gone** |
| `test_denominator_contracts_detect` (its gate-of-gates) | wired | **gone** |
| `test_npi_rate_and_cluster_saboteurs` | wired | **gone** |

`bef401e` closed DEBT D14 immediately afterwards. So for that span the branch
had fixed five denominator defects **and stopped running the gates that police
them** — and CI went green, because the checks were gone rather than because
they passed.

This is the limiting case of the family. A red gate is read as "one thing is
wrong". A gate that aborts is read the same way and means more. A gate that
is *not wired at all* is read as success, by CI and by anyone looking at the
badge, and the only trace is an absence in a file nobody diffs during a merge.

**The tell:** a merge that touches a workflow file. Diff the *step names* out
of `ci.yml` before and after, not the file. Steps that exist only on a feature
branch are invisible to conflict detection, which is exactly the set most
likely to be new gates.

A gate's wiring deserves the same proof as its logic: the step list is now
checked by name in the job log after the first push of any branch that adds
one, because a wired step and a running step are not the same thing, and this
branch has now demonstrated three distinct ways they diverge.

## A note on the reproducibility defect found while verifying the fix

Rebuilding the artifact twice over an unchanged input produced two different
files. `ORDER BY pct_segments_with_npi` had no tie-breaker, and Florida and
Maryland both sit at 87.11%, so the parallel scan's row order leaked into a
committed artifact and its provenance sidecar. Fixed with `ORDER BY
pct_segments_with_npi, state`; two consecutive rebuilds now agree byte for
byte.

It is worth recording because of *how* it surfaced: not from reading the
query, but from regenerating an artifact that should have been identical and
diffing it. The same rebuild also caught a stale `code_sha256` in the sidecar,
left behind because a comment edit postdated the artifact it documents.
