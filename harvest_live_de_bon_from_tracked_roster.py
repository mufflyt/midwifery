#!/usr/bin/env python3
# =============================================================================
# Live Delaware BON cross-reference, using the TRACKED roster as the cohort
# =============================================================================
# Sixth real state added after the 2026-08-17/2026-09-11 fabrication findings
# (docs/PROVENANCE_DEFECT_BON_LICENSE_IDENTIFIERS.md). Follows
# harvest_live_co_bon_from_tracked_roster.py's pattern exactly -- a real HTTP
# request to a real state open-data API, honest failure on error, and
# name-based matching against the tracked cohort.
#
# Source: Delaware Division of Professional Regulation, "Professional and
# Occupational Licensing" (data.delaware.gov, dataset pjnv-eaih) -- every
# DE-regulated profession in one table, not a nursing-specific one. Confirmed
# via direct API query (2026-10-23): profession_id=Nursing AND
# license_type="Certified Nurse Midwife" is a genuine, exact CNM filter --
# unlike Illinois or Connecticut, which have no specialty breakout -- and
# returns 186 current records.
# https://data.delaware.gov/resource/pjnv-eaih.json
#
# ZERO DELAWARE MIDWIVES EXIST IN THIS PROJECT'S TRACKED COHORT as of
# 2026-10-23 (0 of the cohort's nppes_state rows are "DE"). This script will
# therefore report 0 total / 0 matched every time it is run against the
# current cohort -- that is the correct, honest result, not a bug. It exists
# so Delaware is already wired up the moment a DE-practicing midwife enters
# the cohort, and because the DE API itself is worth having verified: several
# of its 186 CNM records carry an OUT-OF-STATE address (e.g. Philadelphia PA,
# Frederick MD) for a Delaware license -- a live illustration that a board's
# own state is not the practice state, relevant to every other state script
# here too.
#
# ADDRESS. city/state/zip_code are captured. Delaware's own documentation
# does not say whether this is a mailing or practice address -- labeled here
# as board-reported, not asserted to be either.
#
# Matched by last+first name (same key scheme as the WA/CO/TX/IL/CT scripts)
# against nppes_state == "DE" in the tracked cohort -- NOT a license-number or
# NPI join, because Delaware's dataset carries neither an AMCB nor an NPI
# identifier.
#
# COHORT: artifacts/tracked_roster_active_primary_linked.csv (tracked; built
# by build_tracked_roster.R), the same source the WA/TX/IL/CT scripts use.
#
# TLS: verification stays ON (see harvest_live_tx_bon_from_tracked_roster.py
# for why CERT_NONE is never acceptable here).
# =============================================================================
import csv
import json
import os
import ssl
import sys
import urllib.parse
import urllib.request
from datetime import datetime, timezone

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "tools"))
from provenance import sha256_file, write_provenance  # noqa: E402

print("=== Live Delaware BON cross-reference (tracked-roster cohort) ===")

DE_API = "https://data.delaware.gov/resource/pjnv-eaih.json"
DE_QUERY = {
    "profession_id": "Nursing",
    "license_type": "Certified Nurse Midwife",
    "$limit": "5000",
}
de_url = DE_API + "?" + urllib.parse.urlencode(DE_QUERY)
req = urllib.request.Request(de_url, headers={"User-Agent": "Mozilla/5.0"})


def verified_tls_context():
    """A verifying TLS context, using certifi when the interpreter has no CA store."""
    ctx = ssl.create_default_context()
    if ctx.cert_store_stats()["x509_ca"] > 0:
        return ctx
    try:
        import certifi
    except ImportError:
        raise SystemExit(
            "This Python has no CA certificate store, so HTTPS cannot be verified.\n"
            "Install certifi (python3 -m pip install certifi), or on macOS run\n"
            "'Install Certificates.command' from the Python installation folder."
        )
    ctx.load_verify_locations(cafile=certifi.where())
    return ctx


retrieved_at = datetime.now(timezone.utc)
live_de_records = []
try:
    with urllib.request.urlopen(req, context=verified_tls_context(), timeout=30) as response:
        live_de_records = json.loads(response.read().decode("utf-8"))
    print(f"Successfully streamed {len(live_de_records):,} live DE certified nurse-midwife license records.")
except Exception as e:
    print(f"Error fetching live DE BON data: {e}")
    raise SystemExit(1)

# Index live DE records by Last_First name -- same key scheme as the other scripts.
de_lookup = {}
for r in live_de_records:
    fn = (r.get("first_name") or "").upper().strip()
    ln = (r.get("last_name") or "").upper().strip()
    if fn and ln:
        de_lookup.setdefault(f"{ln}_{fn}", []).append(r)

# Cross-reference against the TRACKED roster, filtered to DE.
roster_file = "artifacts/tracked_roster_active_primary_linked.csv"
matched_de = []
unmatched_de = []

with open(roster_file, "r", encoding="utf-8", errors="ignore") as f:
    reader = csv.DictReader(f)
    for r in reader:
        st = r.get("nppes_state", "").upper().strip()
        if st != "DE":
            continue
        fn = (r.get("nppes_first_name") or r.get("first_name") or "").upper().strip()
        ln = (r.get("nppes_last_name") or r.get("last_name") or "").upper().strip()
        key = f"{ln}_{fn}"

        out = {
            "certification_number": r.get("certification_number", ""),
            "last_name": r.get("last_name", ""),
            "first_name": r.get("first_name", ""),
            "npi": r.get("npi", ""),
            "nppes_state": st,
        }
        candidates = de_lookup.get(key, [])
        if len(candidates) == 1:
            de_info = candidates[0]
            out["live_bon_license_number"] = de_info.get("license_no", "")
            out["live_bon_status"] = de_info.get("license_status", "")
            out["live_bon_city"] = de_info.get("city", "")
            out["live_bon_state"] = de_info.get("state", "")
            out["live_bon_zip"] = de_info.get("zip_code", "")
            out["live_bon_match_status"] = "VERIFIED_LIVE_BON"
            matched_de.append(out)
        else:
            out["live_bon_license_number"] = "NA"
            out["live_bon_status"] = "UNMATCHED_BON" if not candidates else "AMBIGUOUS_BON"
            out["live_bon_city"] = "NA"
            out["live_bon_state"] = "NA"
            out["live_bon_zip"] = "NA"
            out["live_bon_match_status"] = "UNMATCHED" if not candidates else "AMBIGUOUS"
            unmatched_de.append(out)

out_csv = "artifacts/live_delaware_bon_ingested_midwives_from_tracked_roster.csv"
out_provenance = out_csv + ".provenance.json"
rows = matched_de + unmatched_de
if rows:
    fieldnames = list(rows[0].keys())
    with open(out_csv, "w", encoding="utf-8", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)
    write_provenance(
        out_csv,
        source_url=de_url,
        accessed_utc=retrieved_at.strftime("%Y-%m-%dT%H:%M:%SZ"),
        source_dataset="Delaware Division of Professional Regulation, Professional and Occupational Licensing (data.delaware.gov pjnv-eaih), profession_id=Nursing license_type=Certified Nurse Midwife",
        records_retrieved=len(live_de_records),
        cohort=roster_file,
        cohort_sha256=sha256_file(roster_file),
        cohort_rows_de=len(rows),
        cohort_matched_rows=len(matched_de),
        match_key="last_name + first_name (upper, trimmed); ambiguous names reported unmatched",
        verification_portal="https://dpr.delaware.gov/boards/nursing/verification/",
        address_fields="live_bon_city/state/zip, board-reported -- not documented as mailing vs. practice; several of the 186 current DE CNM records carry an out-of-state address",
    )
    print(f"  Provenance: {out_provenance}")
else:
    print("  No Delaware rows in the tracked cohort -- 0 cohort rows to match against.")
    print("  This is an expected, honest result (see header), not an error.")
    # Still write an empty file with headers and a provenance sidecar so a
    # downstream reader sees "checked, found none" rather than "never run".
    fieldnames = ["certification_number", "last_name", "first_name", "npi", "nppes_state",
                  "live_bon_license_number", "live_bon_status", "live_bon_city",
                  "live_bon_state", "live_bon_zip", "live_bon_match_status"]
    with open(out_csv, "w", encoding="utf-8", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
    write_provenance(
        out_csv,
        source_url=de_url,
        accessed_utc=retrieved_at.strftime("%Y-%m-%dT%H:%M:%SZ"),
        source_dataset="Delaware Division of Professional Regulation, Professional and Occupational Licensing (data.delaware.gov pjnv-eaih), profession_id=Nursing license_type=Certified Nurse Midwife",
        records_retrieved=len(live_de_records),
        cohort=roster_file,
        cohort_sha256=sha256_file(roster_file),
        cohort_rows_de=0,
        cohort_matched_rows=0,
        match_key="last_name + first_name (upper, trimmed); ambiguous names reported unmatched",
        verification_portal="https://dpr.delaware.gov/boards/nursing/verification/",
        note="0 DE rows in the tracked cohort as of this run -- expected, not an error",
    )
    print(f"  Provenance: {out_provenance}")

n_total = len(matched_de) + len(unmatched_de)
print("=========================================================================")
print("  LIVE DE BON CROSS-REFERENCE COMPLETE (tracked-roster cohort)")
print(f"  Total DE-state rows in tracked roster : {n_total:,}")
if n_total:
    print(f"  Live State BON Matched                : {len(matched_de):,} ({len(matched_de)/n_total*100:.1f}%)")
print(f"  Written to: {out_csv}")
print(f"  Provenance: {out_provenance}")
print("=========================================================================")
