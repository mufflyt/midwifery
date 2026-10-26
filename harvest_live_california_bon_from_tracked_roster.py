#!/usr/bin/env python3
# =============================================================================
# Live California BON cross-reference, using the TRACKED roster as the cohort
# =============================================================================
# Source: the California Department of Consumer Affairs' public licensee-data
# repository for the Board of Registered Nursing (agency code 0400), hosted
# as a Box-powered public folder, not an authenticated or paywalled system:
#   https://dca.app.box.com/s/oss6hf8jys2bmgxqd2gdz7w4oepm2il9/folder/72555308989
#
# Two files there (RegisteredNursing_Data00.xls, RegisteredNursing_Data01.xls)
# carry the full BRN roster despite the ".xls" extension -- confirmed by
# inspection to be plain TAB-DELIMITED TEXT, not a binary Excel workbook; no
# spreadsheet library is needed or used. RegisteredNursing_Counts.csv (a
# third, tiny file in the same folder) documents the License Type values and
# their current counts, which is how "Nurse Midwife" (2,598 as of this
# writing) was confirmed as the correct filter -- distinct from "Nurse
# Midwife Furnishing" (1,931), the separate prescriptive-authority add-on
# certificate a Nurse Midwife may additionally hold; filtering on the base
# "Nurse Midwife" license type alone does not lose anyone who also holds
# Furnishing authority. All 2,598 current Nurse Midwife records were found in
# Data00 alone (verified against Counts.csv's total); Data01 is not fetched.
#
# WHY THIS URL FORM. Box's shared-folder web UI is a JavaScript app with no
# plain HTML directory listing; the file IDs below were read off that UI
# once (browser-rendered) and are then fetched via Box's legacy direct-
# download redirect endpoint, which neither requires nor accepts a Box
# account:
#   https://app.box.com/index.php?rm=box_download_shared_file
#     &shared_name=<shared_name>&file_id=f_<file_id>
# This 302-redirects to a signed, short-lived public.boxcloud.com URL that
# urllib follows transparently. The shared_name and file_id are stable
# across DCA's monthly content refreshes (Box versions files in place under
# the same IDs); only the bytes behind them change.
#
# Matched by last+first name (same key scheme as the WA/CO/TX scripts)
# against nppes_state == "CA" in the tracked FROZEN linkage -- NOT a
# license-number or NPI join, because this source carries neither an AMCB
# identifier nor an NPI. Name matching is imperfect (misses a hyphenated or
# maiden-name mismatch, can over-match a common name); this script reports
# what it found as its own result, not a confirmation of AMCB/NPPES
# identity. See docs/PROVENANCE_DEFECT_BON_LICENSE_IDENTIFIERS.md for why
# this project insists on a real request against a real source rather than
# a constructed or assumed one.
# =============================================================================
import csv
import io
import os
import sys
import urllib.request

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "tools"))
from provenance import sha256_file, utc_now, write_provenance  # noqa: E402

print("=== Live California BON cross-reference (tracked-roster cohort) ===")

BOX_SHARED_NAME = "oss6hf8jys2bmgxqd2gdz7w4oepm2il9"
BOX_FILE_ID = "2500007521685"  # RegisteredNursing_Data00.xls
CA_DATA_URL = (
    f"https://app.box.com/index.php?rm=box_download_shared_file"
    f"&shared_name={BOX_SHARED_NAME}&file_id=f_{BOX_FILE_ID}"
)
TARGET_LICENSE_TYPE = "Nurse Midwife"


def fetch_ca_bon_rows(url=CA_DATA_URL, opener=urllib.request.urlopen):
    """Download the tab-delimited BRN roster and return every row whose
    License Type is exactly "Nurse Midwife", as dicts keyed by the file's own
    header row. Raises on anything that isn't recognizably this file (wrong
    delimiter, missing expected columns) rather than silently returning zero
    rows for a file that merely changed shape.
    """
    req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
    with opener(req, timeout=120) as resp:
        raw = resp.read()

    text = raw.decode("utf-8", errors="replace")
    reader = csv.DictReader(io.StringIO(text), delimiter="\t")
    if reader.fieldnames is None or "License Type" not in reader.fieldnames:
        raise RuntimeError(
            f"unexpected file shape: columns were {reader.fieldnames} -- "
            f"expected a tab-delimited header including 'License Type'")

    rows = [r for r in reader if r.get("License Type") == TARGET_LICENSE_TYPE]
    return rows, len(text.splitlines()) - 1  # data rows, excluding header


def build_ca_lookup(ca_rows):
    """Index live CA BON records by Last_First name -- same key scheme as
    the WA/CO/TX scripts. A row missing either name half is never indexed
    under a partial key.
    """
    ca_lookup = {}
    for r in ca_rows:
        ln = (r.get("Org/Last Name") or "").upper().strip()
        fn = (r.get("First Name") or "").upper().strip()
        if fn and ln:
            ca_lookup.setdefault(f"{ln}_{fn}", []).append(r)
    return ca_lookup


def match_cohort_to_ca_bon(cohort_rows, ca_rows):
    """Join the CA-filtered cohort rows against live BRN 'Nurse Midwife'
    records by last+first name. Returns (matched, unmatched) lists. A name
    that resolves to more than one live record is reported AMBIGUOUS rather
    than guessed by picking one.
    """
    ca_lookup = build_ca_lookup(ca_rows)
    matched_ca = []
    unmatched_ca = []

    for r in cohort_rows:
        fn = (r.get("nppes_first_name") or r.get("first_name") or "").upper().strip()
        ln = (r.get("nppes_last_name") or r.get("last_name") or "").upper().strip()
        key = f"{ln}_{fn}"

        out = {
            "certification_number": r.get("certification_number", ""),
            "last_name": r.get("last_name", ""),
            "first_name": r.get("first_name", ""),
            "npi": r.get("npi", ""),
            "nppes_state": (r.get("nppes_state") or "").upper().strip(),
        }
        candidates = ca_lookup.get(key, []) if (fn and ln) else []
        if len(candidates) == 1:
            info = candidates[0]
            out["live_bon_license_number"] = info.get("License Number", "")
            out["live_bon_status"] = info.get("License Status", "")
            out["live_bon_city"] = info.get("City", "")
            out["live_bon_county"] = info.get("County", "")
            out["live_bon_match_status"] = "VERIFIED_LIVE_BON"
            matched_ca.append(out)
        else:
            # 0 candidates: no name match at all. >1: an ambiguous
            # common name -- reported as unmatched rather than guessed.
            out["live_bon_license_number"] = "NA"
            out["live_bon_status"] = "UNMATCHED_BON" if not candidates else "AMBIGUOUS_BON"
            out["live_bon_city"] = "NA"
            out["live_bon_county"] = "NA"
            out["live_bon_match_status"] = "UNMATCHED" if not candidates else "AMBIGUOUS"
            unmatched_ca.append(out)

    return matched_ca, unmatched_ca


def load_ca_cohort_rows(roster_file):
    """CA-filtered rows from the tracked-roster linkage freeze, as plain dicts."""
    with open(roster_file, "r", encoding="utf-8", errors="ignore") as f:
        reader = csv.DictReader(f)
        return [r for r in reader if (r.get("nppes_state") or "").upper().strip() == "CA"]


def main():
    accessed_utc = utc_now()
    try:
        ca_rows, total_rows = fetch_ca_bon_rows()
        print(f"Successfully streamed {total_rows:,} total BRN records; "
              f"{len(ca_rows):,} are '{TARGET_LICENSE_TYPE}'.")
    except Exception as e:
        print(f"Error fetching live CA BON data: {e}")
        raise SystemExit(1)

    roster_file = "artifacts/amcb_npi_linkage_FROZEN.csv"
    cohort_rows = load_ca_cohort_rows(roster_file)
    matched_ca, unmatched_ca = match_cohort_to_ca_bon(cohort_rows, ca_rows)

    out_csv = "artifacts/live_california_bon_ingested_midwives_from_tracked_roster.csv"
    rows = matched_ca + unmatched_ca
    if rows:
        fieldnames = list(rows[0].keys())
        with open(out_csv, "w", encoding="utf-8", newline="") as f:
            writer = csv.DictWriter(f, fieldnames=fieldnames)
            writer.writeheader()
            writer.writerows(rows)

        write_provenance(
            out_csv,
            source_url=CA_DATA_URL + " (RegisteredNursing_Data00.xls, tab-delimited "
                                      "despite the extension; License Type = 'Nurse Midwife')",
            accessed_utc=accessed_utc,
            source_dataset="California DCA public licensee data, Board of Registered Nursing "
                            "(agency 0400), via dca.app.box.com/s/oss6hf8jys2bmgxqd2gdz7w4oepm2il9",
            records_retrieved=len(ca_rows),
            cohort=roster_file,
            cohort_sha256=sha256_file(roster_file),
            cohort_rows_ca=len(rows),
            cohort_matched_rows=len(matched_ca),
            match_key="last_name + first_name (upper, trimmed); ambiguous names reported unmatched",
            verification_portal="https://search.dca.ca.gov/",
        )
        print(f"  Provenance: {out_csv}.provenance.json")

    n_total = len(matched_ca) + len(unmatched_ca)
    print("=========================================================================")
    print("  LIVE CA BON CROSS-REFERENCE COMPLETE (tracked-roster cohort)")
    print(f"  Total CA-state rows in tracked roster : {n_total:,}")
    if n_total:
        print(f"  Live State BON Matched                : {len(matched_ca):,} ({len(matched_ca)/n_total*100:.1f}%)")
    print(f"  Written to: {out_csv}")
    print("=========================================================================")


if __name__ == "__main__":
    main()
