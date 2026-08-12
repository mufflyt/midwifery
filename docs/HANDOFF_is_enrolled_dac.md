# Handoff: live semantic defect in `is_enrolled_dac`

For the session that owns `R/lib/match_npi_to_hospitals.R`. Written here
because the two sessions cannot message each other directly.

## The defect

`is_enrolled_dac` derives Medicare enrollment from the **facility-affiliation**
file. That file lists only clinicians who have a facility affiliation, so a
Medicare-enrolled clinician with no hospital or facility privilege is labelled
**not enrolled**.

Current location — `R/lib/match_npi_to_hospitals.R` (origin/main), lines 138,
226, 259:

```r
is_enrolled_dac = npi %in% enrolled_npis   # enrolled_npis comes from dac_filtered
```

`dac_filtered` is the facility-affiliation file, not the DAC national file.

**Estimated affected: 3,319 midwives** — enrolled in Medicare with no recorded
hospital privilege. They are currently counted as not enrolled.

Any Table 1 row or downstream comparison using this flag is wrong today.

## Requirements

1. Identify the authoritative DAC/PECOS field establishing individual Medicare
   enrollment **independently of facility affiliation**. The DAC national
   downloadable file (`DAC_NationalDownloadableFile_2026-06.csv`) is the
   enrollment register; the facility-affiliation file is not.
2. Redefine `is_enrolled_dac` from that source.
3. Keep facility affiliation as a **separate** variable. Do not let either
   imply the other.
4. Add semantic regression tests proving:
   - enrolled + no facility affiliation → `TRUE`
   - enrolled + facility affiliation → `TRUE`
   - not enrolled → `FALSE`
   - missing enrollment evidence is **not** silently converted to `FALSE`
5. Report old vs new counts for: enrolled, not enrolled, unknown, and enrolled
   without facility affiliation.
6. Emit the exact affected records (~3,319).
7. **Do not rebuild Table 1 or downstream artifacts yet.**
8. Stage only files intentionally changed. **Do not use `git add -A`.**

**Stop and report before committing.**

## Why this matters beyond one flag

Table 1 already distinguishes three states deliberately:

- not enrolled in Medicare (absent from the DAC)
- enrolled, no hospital privilege recorded
- hospital privilege recorded

Deriving enrollment from the affiliation file collapses the first two, which
is what the three-state row exists to prevent.

**Medicare enrollment != facility affiliation != organization affiliation.**
None of the three may be inferred from another.

## Naming note

In this session's copy the field was renamed `appears_in_affiliation_file`,
which is what the current logic actually measures. That rename was **not**
pushed — origin/main still carries `is_enrolled_dac` with the original
semantics, deliberately left alone so this session's active work is not
overwritten. Rename or redefine as you prefer, but the two concepts need
separate variables.
