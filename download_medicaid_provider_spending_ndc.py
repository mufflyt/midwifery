#!/usr/bin/env python3
"""Download HHS Open Data's Medicaid Provider Spending by NDC and load it
into a standalone, verified DuckDB file on the external volume.

Source: https://opendata.hhs.gov/datasets/medicaid-provider-spending-ndc/
Monthly claim-line aggregates by billing/prescribing NPI and NDC (drug)
code, same cell-suppression rule as the sibling HCPCS release (rows with
fewer than 12 claim lines AND fewer than 12 beneficiaries are not
published) -- confirmed by the parent docstring in
download_medicaid_provider_spending.py, same HHS Open Data platform, same
release cadence (both datasets show "Updated Jul 24, 2026" on the platform's
listing page).

Blob version-date discovered directly against the live Azure Blob Storage
endpoint on 2026-10-26 (HEAD request, 200 OK, 321,153,465 bytes,
Last-Modified: Fri, 24 Jul 2026) -- not guessed from the HCPCS sibling's
Feb-2026 date, which belongs to a different dataset with its own release
schedule.

Shares its download/verify/extract/load pipeline with
download_medicaid_provider_spending.py and
download_medicaid_provider_enrollment_segments.py via
hhs_opendata_csv_pipeline.py -- see that module's docstring for the shared
Azure Blob URL shape and SHA-256 verification approach.

Output: /Volumes/MufflySamsung/DuckDB/medicaid_provider_spending_ndc_verified.duckdb
    table `spending_ndc`    one row per (billing NPI, prescribing NPI, NDC, month)
    table `_provenance`     one row per successful load, append-only
"""
import argparse
import os
import sys
import urllib.error

import hhs_opendata_csv_pipeline as pipeline

DEFAULT_VERSION_DATE = "2026-07-24"
BLOB_BASE = "https://stopendataprod.blob.core.windows.net/datasets/medicaid-provider-spending-ndc"
ZIP_FILENAME = "medicaid-provider-spending-ndc.csv.zip"
TABLE_NAME = "spending_ndc"
WORK_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                         "scratch", "medicaid_provider_spending_ndc")
DB_PATH = "/Volumes/MufflySamsung/DuckDB/medicaid_provider_spending_ndc_verified.duckdb"


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
