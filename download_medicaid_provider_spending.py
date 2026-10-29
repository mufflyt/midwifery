#!/usr/bin/env python3
"""Download HHS Open Data's Medicaid Provider Spending by HCPCS and load it
into a standalone, verified DuckDB file on the external volume.

Source: https://opendata.hhs.gov/datasets/medicaid-provider-spending/
Monthly claim-line aggregates by billing/servicing NPI and HCPCS code,
January 2018 - December 2024, cell-suppressed (rows with fewer than 12 claim
lines AND fewer than 12 beneficiaries are not published). Per the dataset
page's own documented schema and Query Logic, the official release has
EXACTLY these seven columns and nothing else:

    BILLING_PROVIDER_NPI_NUM   SERVICING_PROVIDER_NPI_NUM   HCPCS_CODE
    CLAIM_FROM_MONTH   TOTAL_PATIENTS   TOTAL_CLAIM_LINES   TOTAL_PAID

Deliberately NOT included here: provider name, provider state, or any other
demographic field -- the official source is NPI-keyed only. This is a
MATERIAL DIFFERENCE from the pre-existing, unverified
/Volumes/MufflySamsung/DuckDB/medicaid_provider_spending.duckdb, whose
billing_providers/servicing_providers tables carry name/state/address columns
this official release does not have. Per docs/HANDOFF_hhs_medicaid_provider_
spending.md, those two dimension tables were pulled from a third-party
HuggingFace mirror (cfahlgren1/medicaid-provider-spending), not from
opendata.hhs.gov -- they are a separate, differently-sourced enrichment, not
a verified part of this official download. This script writes to a
DIFFERENT file (see DB_PATH below) specifically so it never overwrites that
existing file or implicitly re-brands its unverified dimension tables as
verified; whether/how to reconcile the two is a decision for whoever reads
this, not something this script makes unilaterally.

Shares its download/verify/extract/load pipeline with
download_medicaid_provider_enrollment_segments.py via
hhs_opendata_csv_pipeline.py -- see that module's docstring for why the
pipeline is a single shared definition, and for the general shape every
opendata.hhs.gov dataset follows (stable unauthenticated Azure Blob Storage
URL, x-ms-meta-sha256 as the only integrity oracle, verified live against the
server rather than a hardcoded constant).

Output: /Volumes/MufflySamsung/DuckDB/medicaid_provider_spending_verified.duckdb
    table `spending`        one row per (billing NPI, servicing NPI, HCPCS, month)
    table `_provenance`     one row per successful load, append-only
"""
import argparse
import os
import sys
import urllib.error

import hhs_opendata_csv_pipeline as pipeline

DEFAULT_VERSION_DATE = "2026-02-09"
BLOB_BASE = "https://stopendataprod.blob.core.windows.net/datasets/medicaid-provider-spending"
ZIP_FILENAME = "medicaid-provider-spending.csv.zip"
TABLE_NAME = "spending"
WORK_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                         "scratch", "medicaid_provider_spending")
DB_PATH = "/Volumes/MufflySamsung/DuckDB/medicaid_provider_spending_verified.duckdb"


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                      formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--version-date", default=DEFAULT_VERSION_DATE,
                         help="dataset version-date path segment (default: %(default)s)")
    parser.add_argument("--force-download", action="store_true",
                         help="re-download even if a matching cached zip exists")
    parser.add_argument("--force-reload", action="store_true",
                         help="rebuild the DuckDB table even if it already has rows")
    parser.add_argument("--keep-csv", action="store_true",
                         help="keep the extracted CSV after loading (default: delete it)")
    args = parser.parse_args()

    try:
        result = pipeline.run_pipeline(
            blob_base=BLOB_BASE, version_date=args.version_date,
            zip_filename=ZIP_FILENAME, table_name=TABLE_NAME,
            work_dir=WORK_DIR, db_path=DB_PATH,
            force_download=args.force_download, force_reload=args.force_reload,
            keep_csv=args.keep_csv)
    except (pipeline.DownloadVerificationError, pipeline.ZipContentError, RuntimeError,
            urllib.error.URLError) as e:
        print(f"ERROR: {e}", file=sys.stderr)
        sys.exit(1)

    print(f"\n{result['row_count']:,} rows in {result['table_name']} "
          f"({result['db_path']})")


if __name__ == "__main__":
    main()
