# Technical Appendix: Cohort Vintage, and the Assertion That Could Not Fail

**Repository**: `midwifery`
**Primary code**: [`make_cohort_flow_figure.R`](../make_cohort_flow_figure.R),
[`tests/test_cohort_vintage.R`](../tests/test_cohort_vintage.R),
[`repin_frozen_cohort.R`](../repin_frozen_cohort.R)
**Registered as**: [DEBT.md](../DEBT.md) D10
**Found**: 2026-08-31, by reading the cohort flow figure aloud

---

## 1. The symptom

The cohort flow figure drew two boxes merging into a third:

```
Midwifery taxonomy  14,764  ┐
                            ├──>  Analytic cohort  16,892
Nursing taxonomy     2,134  ┘
```

14,764 + 2,134 = **16,898**. The figure said 16,892. Six certificants
disappeared across an arrow labelled *"both enter the cohort"*.

## 2. The cause

The two halves of the figure describe **different freezes**.

| | pinned / declared | cohort |
|---|---|---|
| `artifacts/frozen_cohort/INPUT_FINGERPRINT.json` | 2026-08-10 **05:31** | 16,892 |
| `refreeze_option2_20260810T192207` | 2026-08-10 **19:22** | 16,898 |

The geography snapshot was pinned about fourteen hours before the re-freeze
this repository documents as its own Option 2 decision — class-5 candidates
held out of analytic membership — and was never re-pinned. The re-freeze added
six members (`added_amcb_ids`: 12370, CNM10330, CNM08824, CNM04742, 5850,
5620).

Everything descending from the pin still describes the previous cohort:

```
frozen_cohort/midwives_geography_guarded.csv   16,892   pinned pre-refreeze
  └── analytic_cohort.csv                      16,892
        └── composition_rucc_cat.csv           16,892   REBUILT 2026-08-30
              └── cohort.known_n + unknown_n   16,636 + 256

linkage_completeness_by_status.csv             16,898   post-refreeze
  └── matched + matched_nursing_taxonomy       14,764 + 2,134
```

**Recency is no defence.** `composition_rucc_cat.csv` was rebuilt three weeks
*after* the re-freeze and still carries the old count, because it inherits it
through `analytic_cohort.csv`. A file's modification time says nothing about
the vintage of the cohort inside it.

**Each half is internally consistent**, which is why nothing reported this for
three weeks. 16,636 + 256 = 16,892 exactly. 14,764 + 2,134 = 16,898 exactly.
Only a check that spans the two could see it.

## 3. Why the existing assertion could not see it

`make_cohort_flow_figure.R` carried exactly one check:

```r
unresolved <- NUM("linkage.total") - NUM("linkage.matched") - NUM("linkage.nursing")
stopifnot(NUM("linkage.matched") + NUM("linkage.nursing") + unresolved ==
            NUM("linkage.total"))
```

Substitute the definition of `unresolved` into the assertion and it reads
`total == total`. **It cannot fail for any input.** The residual was derived by
subtraction and then checked for closing, which subtraction guarantees.

This is worth stating plainly because the shape is common and invisible: a
quantity is computed as *"whatever is left over"*, and is then validated
against the identity it was constructed from. The check reads like arithmetic
verification and performs none.

The edge that was actually wrong — the merge — had no check at all. The script
asserted the one thing that could not be false and left the one thing that was.

## 4. What replaced it

Two real identities, both asserted, and the merge one **before** the write:

```r
cohort_derived <- NUM("linkage.matched") + NUM("linkage.nursing")
stopifnot(identical(unresolved, NUM("linkage.total") - cohort_derived))

if (!isTRUE(all.equal(cohort_derived,
                      NUM("cohort.known_n") + NUM("cohort.unknown_n")))) {
  stop("MERGE DOES NOT RECONCILE, refusing to draw the flow. ...")
}
```

The cohort node is now **derived** from the two boxes feeding it rather than
read from `panel.cohort_n_at_panel_build`, so the figure cannot state a total
its own inputs contradict.

**Ordering is load-bearing.** The first version of this change ran the guard
*after* `fd_write()`. It shipped a figure whose halves disagreed by more than
the original — 16,898 above, 16,636 + 256 below — and only then raised the
error. A guard that fires after the write is not a guard; it is a complaint
about a file that already exists.

## 5. The vintage test

[`tests/test_cohort_vintage.R`](../tests/test_cohort_vintage.R) compares four
vintages against the freeze of record, reading only **tracked metadata** — two
JSON sidecars and two aggregate CSVs — so it runs on a clean checkout with no
person-level data present.

```
V1  the manifest declares cohort_members
V2  linkage_completeness_by_status.csv    == the freeze
V3  frozen_cohort/INPUT_FINGERPRINT.json  == the freeze
V4  composition_rucc_cat.csv              == the freeze
```

V3 and V4 fail today, correctly. The test is **deliberately not wired into
CI**: a gate that is red on arrival teaches people to ignore gates. It is wired
in when the re-pin lands, and DEBT.md D10 records that as the decision needed.

## 6. The pin that was misnamed

`panel.cohort_n` was a constant of 16,892 in the stats catalog, labelled in
`protected_results.tsv` as **"the analytic cohort"**. That label is what let the
flow figure read it as the live figure.

It is renamed `panel.cohort_n_at_panel_build`, and its label now says what it
is: *the cohort as it stood when the provider panel was built*.

**Its value is deliberately unchanged.** `panel.observed` (16,891),
`panel.provider_years` (200,873) and `panel.median_years` were all computed
against those 16,892 members. Bumping the denominator alone would make
`observed` a count against a population it was never taken from — a worse
defect than the one being fixed, and a harder one to notice. The three move
together, when the panel is rebuilt, or not at all.

The live cohort is now `linkage.cohort_n`, derived where the other linkage
figures are derived.

## 7. Re-pinning

[`repin_frozen_cohort.R`](../repin_frozen_cohort.R), dry run by default:

```
Rscript repin_frozen_cohort.R                # reports the drift
REPIN_APPLY=1 Rscript repin_frozen_cohort.R  # executes
```

It **refuses to pin a source whose row count does not match the freeze**, which
would swap one vintage mismatch for another. It keeps the previous pin beside
the new one. Then, in order:

1. `Rscript R/07-cohort-composition.R`
2. `Rscript tests/test_cohort_vintage.R`
3. `Rscript make_cohort_flow_figure.R`
4. Rebuild the provider panel, then update `panel.cohort_n_at_panel_build`,
   `panel.observed` and `panel.provider_years` **together**.

It is excluded from the FROZEN rebuild scanner
([`R/frozen_dependency_graph.R`](../R/frozen_dependency_graph.R)) for the same
reason `reconcile_linkage.R` is excluded as a producer: it *writes* the pinned
snapshot, and a runner that re-pins partway through a rebuild regenerates the
thing the rebuild exists to hold fixed. That is the 2026-08-10 failure in a
different costume.

## 8. Scale, stated honestly

Six certificants of 16,898 is **0.035%**. No conclusion in this repository
moves. Every rate, bound and map is unaffected at the precision any of them are
reported to.

It matters because the affected figure is README Figure 3 and the manuscript's
**STROBE item 13** flow diagram, whose entire job is that the numbers
reconcile. A reviewer who adds 14,764 and 2,134 gets a different answer from the
box beneath them, and no caption can repair that.

## 9. What to take from this

- A residual computed by subtraction cannot validate the identity it came from.
  If the only assertion in a script involves a quantity defined as the
  remainder, there is no assertion.
- Internal consistency within each half of a pipeline is not consistency. The
  checks that matter span the seam.
- A pinned snapshot needs its vintage compared to the thing it is a snapshot
  *of*, on every run, not remembered.
- Modification time is not vintage.
