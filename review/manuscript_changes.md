# Federal Database Accuracy Manuscript Changes

## Starting state

The worktree already contained uncommitted revisions to `manuscript/federal_database_accuracy.qmd`. They were preserved rather than reset or recreated. Before this remediation run, those edits had:

- changed the title and abstract to include certified nurse-midwives and certified midwives;
- replaced categorical geographic-validity claims with evidence-limited agreement language;
- renamed NPPES as a common comparison source;
- changed legal-name accuracy to certified-name agreement;
- exposed the 14,956 + 1,819 = 16,775 cohort arithmetic;
- added Wilson intervals, unresolved-record sensitivity bounds, a research-use table, and a pooled cluster-bootstrap supplement;
- distinguished comparable source records from unique clinicians in Table 4;
- qualified causal explanations and corrected the 63.1% persistence contradiction; and
- added a simple inline cohort-flow figure.

Those changes were useful but had not yet been supported by the required ledgers, adversarial gates, dependence-aware trend analysis, timestamped render, or independent review.

## Remediation decisions

1. The existing QMD remains the authoritative manuscript source.
2. Numerical claims are registered in `review/denominator_ledger.csv` with numerator, denominator, unit, years, inclusion rule, and artifact.
3. Medicaid's 85,190-row classification universe and 107,386-row set-membership universe remain separate; they are not forced into one flow.
4. The 27,175 concordant classification observations are explicitly the sum of 20,125 single-state and 7,050 multistate-concordant provider-years.
5. A new dependence-aware trend artifact is required before retaining inferential language about the annual clinician-directory trend.
6. No automatic commits will be made because the requested work began in a dirty main worktree containing prior manuscript edits.

## Verification record

The implementation log and final F01-F12 status are maintained in `review/manuscript_findings_ledger.csv`. Successful Quarto rendering alone is not considered scientific verification.

## Independent-audit correction — 2026-11-25

The independent review in `review/independent_reviewer_audit.md` overturned
the earlier assumption that green manuscript gates resolved every P0 item.
The manuscript and ledgers now:

- use 4,267/5,877 as the exact any-variable disagreement count;
- describe state-board fractions as verification yield in selected listings,
  not federal license-status-field accuracy;
- retain 563/892 only as invalid historical endpoint arithmetic and remove it
  from manuscript conclusions;
- separate Medicaid any-time state sets from same-date enrollment and actual
  practice;
- mark the 44,806-NPI-year clustered trend unresolved because 991 NPIs fall
  outside the frozen cohort and the series differs from the plotted series;
  and
- state explicitly that the manuscript remains blocked on P0 reanalysis.

The durable disposition is
`docs/TECHNICAL_APPENDIX_FEDERAL_DATABASE_ACCURACY_REVIEW_2026-11-25.md`.
