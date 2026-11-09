#!/usr/bin/env python3
# =============================================================================
# Live Illinois BON cross-reference, using the TRACKED roster as the cohort
# =============================================================================
# Fourth real state added after the 2026-08-17/2026-09-11 fabrication findings
# (docs/PROVENANCE_DEFECT_BON_LICENSE_IDENTIFIERS.md). Follows
# harvest_live_co_bon_from_tracked_roster.py's pattern exactly -- a real HTTP
# request to a real state open-data API, honest failure on error, and
# name-based matching against the tracked cohort.
#
# Source: Illinois Department of Financial and Professional Regulation
# (IDFPR), "Professional Licensing" (illinois-edp.data.socrata.com /
# data.illinois.gov, dataset pzzh-kp68) -- every IDFPR-regulated profession in
# one table, not a nursing-specific one. Confirmed via direct API query
# (2026-10-23).
# https://data.illinois.gov/resource/pzzh-kp68.json
#
# NO CNM-SPECIFIC FILTER EXISTS AT THE API LEVEL, unlike Colorado
# (subcategory=CNM) or Texas (apn_category=NURSE MIDWIFE). IDFPR's
# license_type for nursing is "ADV PRACTICE NURSE" -- one bucket covering
# nurse practitioners, CRNAs, clinical nurse specialists AND certified
# nurse-midwives together, with no further specialty breakout in this
# dataset's `description` field (checked directly: only generic values like
# "ADVANCED PRACTICE REGISTERED NURSE" and "FULL PRACTICE AUTHORITY APRN").
# This script therefore pulls the ENTIRE IL "ADV PRACTICE NURSE" population
# (~82,500 records as of 2026-10-23, one request, no pagination needed) and
# relies on name-matching against the IL-state tracked cohort to find this
# project's midwives within it -- the same honest match/ambiguous/unmatched
# logic as every other state here, just against a much larger raw candidate
# pool, which raises (not lowers) the chance of a common-name collision
# landing in AMBIGUOUS rather than a false match.
#
# "MIDWIFERY BOARD" (license_type) IS DELIBERATELY EXCLUDED. IDFPR licenses
# Certified Professional Midwives (CPMs, certified by NARM) under a SEPARATE
# license_type ("MIDWIFERY BOARD" / description "CERTIFIED PROFESSIONAL
# MIDWIFE") from Certified Nurse-Midwives. CPM is not the AMCB/CNM credential
# this project's cohort holds; matching against it would risk a false
# "verified" result for a different, non-overlapping certification.
#
# ADDRESS. city/state/zip/county are captured. IDFPR's own documentation does
# not say whether this is a mailing or practice address (unlike Colorado,
# whose field is explicitly named "mailzipcode") -- labeled here as
# board-reported, not asserted to be either.
#
# Matched by last+first name (same key scheme as the WA/CO/TX scripts)
# against nppes_state == "IL" in the tracked cohort -- NOT a license-number or
# NPI join, because IDFPR's dataset carries neither an AMCB nor an NPI
# identifier. Name matching is imperfect (misses a hyphenated or maiden-name
# mismatch, can over-match a common name); this script reports what it found
# as its own result, not a confirmation of AMCB/NPPES identity.
#
# COHORT: artifacts/tracked_roster_active_primary_linked.csv (tracked; built
# by build_tracked_roster.R), the same source the WA/TX scripts use.
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

print("=== Live Illinois BON cross-reference (tracked-roster cohort) ===")

IL_API = "https://data.illinois.gov/resource/pzzh-kp68.json"
IL_QUERY = {
    "license_type": "ADV PRACTICE NURSE",
    "$limit": "100000",
}
il_url = IL_API + "?" + urllib.parse.urlencode(IL_QUERY)
req = urllib.request.Request(il_url, headers={"User-Agent": "Mozilla/5.0"})


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
live_il_records = []
try:
    with urllib.request.urlopen(req, context=verified_tls_context(), timeout=60) as response:
        live_il_records = json.loads(response.read().decode("utf-8"))
    print(f"Successfully streamed {len(live_il_records):,} live IL advanced-practice-nurse license records.")
except Exception as e:
    print(f"Error fetching live IL BON data: {e}")
    raise SystemExit(1)

# Index live IL records by Last_First name -- same key scheme as the other scripts.
il_lookup = {}
for r in live_il_records:
    fn = (r.get("first_name") or "").upper().strip()
    ln = (r.get("last_name") or "").upper().strip()
    if fn and ln:
        il_lookup.setdefault(f"{ln}_{fn}", []).append(r)

# Cross-reference against the TRACKED roster, filtered to IL.
roster_file = "artifacts/tracked_roster_active_primary_linked.csv"
matched_il = []
unmatched_il = []

with open(roster_file, "r", encoding="utf-8", errors="ignore") as f:
    reader = csv.DictReader(f)
    for r in reader:
        st = r.get("nppes_state", "").upper().strip()
        if st != "IL":
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
        candidates = il_lookup.get(key, [])
        if len(candidates) == 1:
            il_info = candidates[0]
            out["live_bon_license_number"] = il_info.get("license_number", "")
            out["live_bon_status"] = il_info.get("license_status", "")
            out["live_bon_description"] = il_info.get("description", "")
            out["live_bon_city"] = il_info.get("city", "")
            out["live_bon_state"] = il_info.get("state", "")
            out["live_bon_zip"] = il_info.get("zip", "")
            out["live_bon_county"] = il_info.get("county", "")
            out["live_bon_match_status"] = "VERIFIED_LIVE_BON"
            matched_il.append(out)
        else:
            # 0 candidates: no name match at all. >1: an ambiguous common name
            # -- reported as unmatched rather than guessed, same as the
            # CO/TX scripts' handling of name collisions. More likely here
            # than in CO/TX since there is no CNM-specific pre-filter.
            out["live_bon_license_number"] = "NA"
            out["live_bon_status"] = "UNMATCHED_BON" if not candidates else "AMBIGUOUS_BON"
            out["live_bon_description"] = "NA"
            out["live_bon_city"] = "NA"
            out["live_bon_state"] = "NA"
            out["live_bon_zip"] = "NA"
            out["live_bon_county"] = "NA"
            out["live_bon_match_status"] = "UNMATCHED" if not candidates else "AMBIGUOUS"
            unmatched_il.append(out)

out_csv = "artifacts/live_illinois_bon_ingested_midwives_from_tracked_roster.csv"
out_provenance = out_csv + ".provenance.json"
rows = matched_il + unmatched_il
if rows:
    fieldnames = list(rows[0].keys())
    with open(out_csv, "w", encoding="utf-8", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)

    write_provenance(
        out_csv,
        source_url=il_url,
        accessed_utc=retrieved_at.strftime("%Y-%m-%dT%H:%M:%SZ"),
        source_dataset="Illinois IDFPR, Professional Licensing (data.illinois.gov pzzh-kp68), license_type=ADV PRACTICE NURSE -- not CNM-specific, no API-level specialty filter exists",
        records_retrieved=len(live_il_records),
        cohort=roster_file,
        cohort_sha256=sha256_file(roster_file),
        cohort_rows_il=len(rows),
        cohort_matched_rows=len(matched_il),
        match_key="last_name + first_name (upper, trimmed); ambiguous names reported unmatched",
        verification_portal="https://online-dfpr.micropact.com/lookup/licenselookup.aspx",
        address_fields="live_bon_city/state/zip/county, board-reported -- IDFPR does not document whether this is mailing or practice address",
        excluded="license_type=MIDWIFERY BOARD (Certified Professional Midwife, a NARM/CPM credential, not AMCB/CNM)",
    )
    print(f"  Provenance: {out_provenance}")

n_total = len(matched_il) + len(unmatched_il)
print("=========================================================================")
print("  LIVE IL BON CROSS-REFERENCE COMPLETE (tracked-roster cohort)")
print(f"  Total IL-state rows in tracked roster : {n_total:,}")
if n_total:
    print(f"  Live State BON Matched                : {len(matched_il):,} ({len(matched_il)/n_total*100:.1f}%)")
print(f"  Written to: {out_csv}")
print(f"  Provenance: {out_provenance}")
print("=========================================================================")
