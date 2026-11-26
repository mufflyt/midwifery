# Handoff: HHS Medicaid provider-spending warehouse

**Updated:** 2026-11-25
**Status:** source and verified local warehouse recovered; not tracked in Git

The earlier handoff said the fact-table download had failed. That is no
longer true. The scratch directory now contains the complete source archive
and a DuckDB warehouse:

| Local file | Size | Role |
|---|---:|---|
| `scratch/medicaid_provider_spending/medicaid-provider-spending.csv.zip` | 3.5 GB | Source archive; one 11.55 GB uncompressed CSV |
| `scratch/medicaid_provider_spending/medicaid_provider_spending_verified.duckdb` | 4.0 GB | Queryable local warehouse |

Both remain ignored by Git. They must not be committed.

## Verified provenance

The warehouse `_provenance` table records:

- source URL: `https://stopendataprod.blob.core.windows.net/datasets/medicaid-provider-spending/2026-02-09/dataset/medicaid-provider-spending.csv.zip`
- version date: `2026-02-09`
- ZIP SHA-256: `3387c48ea9600c15e8e6b43e68599b814cc66b24723e8d7aba2f556a8136f149`
- ZIP bytes: `3,761,921,469`
- loaded rows: `238,015,729`
- loaded table: `spending`
- load timestamp: `2026-11-19 05:58:35.770986`

The `spending` table has seven character columns:
`BILLING_PROVIDER_NPI_NUM`, `SERVICING_PROVIDER_NPI_NUM`, `HCPCS_CODE`,
`CLAIM_FROM_MONTH`, `TOTAL_PATIENTS`, `TOTAL_CLAIM_LINES`, and `TOTAL_PAID`.
Numeric/date conversion must be explicit in downstream queries; the current
warehouse intentionally preserves source strings.

## Safe verification

```sh
unzip -l scratch/medicaid_provider_spending/medicaid-provider-spending.csv.zip
duckdb -readonly scratch/medicaid_provider_spending/medicaid_provider_spending_verified.duckdb \
  -c "SELECT * FROM _provenance;"
duckdb -readonly scratch/medicaid_provider_spending/medicaid_provider_spending_verified.duckdb \
  -c "SELECT COUNT(*) FROM spending;"
```

## Remaining work

1. Add a tracked rebuild script before treating the warehouse as a
   reproducible pipeline input.
2. Validate typed casts for month, patients, claim lines, and paid amount.
3. Define a manuscript question and denominator before joining to the AMCB
   cohort; do not mine the warehouse for an unregistered headline.
4. Move the two large files to the repository's data-vault location only
   under the documented vault procedure. The scratch copies are currently
   the only recovered local copies and should not be deleted casually.
