# Appendix: what year is each side of a comparison from?

**2026-11-16.** Every agreement number this repository publishes is a
comparison between two records. A comparison only means something if both
records are talking about the same time, and until this change not one of the
places that paired them could say what years it had paired.

This appendix documents the contract that now governs that, because the
machinery is not obvious from any single file and because one of its findings
is still in a shipped artifact.

## The three pairing sites, and what each let through

### 1. A current-snapshot comparison could not see the registry's year

`state_agreement_current_only()` joins on `npi` alone. That is the only option
for a source carrying no year of its own — a scrape, a board roster, a FHIR
pull — and it is correct. What was not correct is that the caller passed the
registry with its `year` column already selected away, and an `as_of_label` of
free text that nothing checked.

So the function was structurally incapable of knowing which registry snapshot
it had been handed. Given a 2019 source and the 2026 registry it returned a
row stamped `year = 2026` with 0% agreement — and 0% reads as *the source
disagrees*, not as *seven years of drift*.

It now requires the source's year, reads the registry's from the data, and
refuses a pairing it cannot justify. The free-text label stays, because
`"2026-11 (6 boards harvested; 4 publish a state: CO/CT/FL/IL)"` says more
than a year does. It is now a caption on a pairing that has been verified
rather than the only evidence for it.

### 2. A source sharing no year with the registry vanished

`state_agreement_same_year()` joins on `(npi, year)` and therefore *cannot*
mismatch — that is the point of it. But when the two year sets did not meet at
all, the inner join yielded zero rows, the function returned a zero-row
tibble, `bind_rows()` in the audit dropped the source, and
`state_source_audit_agreement.csv` came out one source shorter than
`state_source_audit_coverage.csv`.

The source did not look wrong. It looked *absent* — which is how a truncated
or re-keyed input publishes a smaller study. It now refuses, naming both year
sets.

### 3. A claim's year was a literal, and its values were a bare vector

This is the one that reached a published artifact.

`remake_oig_07_09_00440_midwifery.R` builds the OIG rebuild out of claims: one
row per `(npi, year, source, attribute, value)`. The builder took the year as
a literal argument and the values as an unrelated vector, so nothing connected
the two:

```r
nppes_2026_gender <- nppes_2026 %>% select(npi, gender)
nppes_2019 <- nppes_2019_panel %>% left_join(nppes_2026_gender, by = "npi")
...
make_parent_field_claims(nppes_2019, 2019L, "nppes", "gender", ...)
```

`midwife_panel.csv` at `snapshot_year == 2019` carries no sex code, so `gender`
was borrowed from the **February 2026 NPPES dissemination** and then stamped
2019. The row `2019,nppes,pecos,gender` in
`artifacts/oig_remake/oig_table4_consistency_2019_and_2026.csv` is therefore
2026 NPPES values compared against 2019 PECOS values, in a table whose entire
purpose is to compare two records of the same vintage.

**Sex is near-immutable, which is the only reason the number survives the
borrow.** On `practice_state` the same mechanism would have produced a wrong
number with nothing to notice. The mechanism was the defect, not the value.

The builder now lives in `R/lib/vintage_claims.R`, where it can be called
without a 91 GB DuckDB warehouse attached, and `value_year` is **required and
not defaulted**. A default is precisely what let this through: whoever wrote
that line was never asked what year the values were from. Where the years
genuinely differ a reason must be given, and the borrow is announced on every
run.

> **Still open, and a labelling decision rather than a patch.** The 2019
> gender row is still published as a 2019 claim. The code can no longer make
> that borrow silently, but whether the row should be dropped or relabelled
> cross-vintage is a scientific call.

## The guard already existed and nothing called it

`assert_vintage_gap()` was written for exactly this, tested, and called by
**nothing in production**. The reason is mundane: the comparisons hold *years*
and the guard wanted *dates*, and nobody wanted to invent January 1st at the
call site to use it — so the guard sat unused while 2019 values were compared
against 2026 ones.

`assert_same_vintage_year()` is the missing adapter. A year becomes an instant
by the convention `R/lib/source_vintage.R` already uses for Open Payments — the
**midpoint** of the year, not January 1st — so adjacent years are 12 months
apart and the same year is 0. It is not a second opinion about what counts as
too far apart; it defers to `assert_vintage_gap()` for that.

Two kinds of time, and conflating them is the trap the midpoint convention
exists to avoid: a **snapshot** source is true "as of" one instant; an
**interval** source covers a span. Open Payments PY2025 is every payment in
calendar 2025, published mid-2026. It is not a 2026 source because that is
when CMS posted it, and not a single day in 2025 either.

## What is NOT refused

Measuring *across* a gap is legitimate — the fitted-trend figure is exactly
that. What must not happen is measuring across one by accident. So the limit
is a parameter (`max_months`, default 6) and widening it is a visible, written
decision at the call site rather than a silent default.

A declared year that is present, complete and holds zero qualifying records is
also not a gap. It contributes no rows and therefore cannot appear among the
analysed years, and an earlier version of this check refused exactly that
valid-absence case. Presence with zero records is evidence of absence;
a missing file is evidence of nothing.

## Still unguarded: the pairwise matrix

`build_cross_source_comparison.R` takes each source at
`filter(year == max(year))` and publishes pairs more than six months apart on
purpose, with the gap annotated. That is a documented tradeoff and this change
does not alter it.

What is worth fixing is subtler: the gap column comes from
`source_vintage_table()`, which dates `pecos_revalidation` from the newest
monthly file on the external volume, while the join uses `max(year)` of
`artifacts/pecos_revalidation_cohort_state_by_year.csv`. **The annotation and
the comparison are computed from two different facts**, so the column can read
"3 months" over a join that is seven years wide. They agree today — both 2026 —
which is exactly why nothing has caught it.

## Verification

`tests/test_cross_vintage_pairing_saboteurs.R` — 10 saboteurs, 33 checks, four
of them inverted so the suite cannot be satisfied by refusing every
comparison.

Mutation testing ran 13 mutations and caught 13. Two survived the first pass:
one a verified equivalent mutant (removing a `select(-"year")` gave
byte-identical output even when the source frame carried its own year, so that
guard was inconsequential and was deleted rather than kept untestable), and one
a real blind spot — an **unknown** vintage was untested, which matters because
an undated source is the normal case here and "probably current" is how a gap
gets published as a same-day comparison.

No published number moved: `state_source_audit_agreement.csv` and
`state_source_audit_coverage.csv` are byte-identical before and after.
