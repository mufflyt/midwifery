#!/usr/bin/env python3
# =============================================================================
# Live Connecticut BON cross-reference, using the TRACKED roster as the cohort
# =============================================================================
# Fifth real state added after the 2026-08-17/2026-09-11 fabrication findings
# (docs/PROVENANCE_DEFECT_BON_LICENSE_IDENTIFIERS.md). Follows
# harvest_live_co_bon_from_tracked_roster.py's pattern exactly -- a real HTTP
# request to a real state open-data API, honest failure on error, and
# name-based matching against the tracked cohort.
#
# Source: Connecticut Department of Public Health (DPH), "Advanced Practice
# Registered Nurse Licenses (All statuses: active and inactive)"
# (data.ct.gov, dataset f4xa-y96m). Confirmed via direct API query
# (2026-10-23). This is a DIFFERENT, cleaner source than
# artifacts/ct_licensed_nurse_midwife.csv (a Playwright scrape of CT's
# eLicense search portal, carrying only `city`, no ZIP) -- this Socrata feed
# carries a full ZIP code on every row. Both may be kept; they are not the
# same pull and this script does not overwrite the older one.
# https://data.ct.gov/resource/f4xa-y96m.json
#
# NO CNM-SPECIFIC FILTER EXISTS AT THE API LEVEL, same situation as Illinois.
# CT DPH's `credentialtype` is "12" / "Advanced Practice Registered Nurse" for
# every APRN regardless of specialty -- nurse practitioners, CRNAs, clinical
# nurse specialists and certified nurse-midwives all share this one bucket,
# with no further breakout field in this dataset. This script therefore pulls
# the ENTIRE CT APRN population (~20,000 records including inactive, as of
# 2026-10-23, one request, no pagination needed) and relies on name-matching
# against the CT-state tracked cohort, same honest match/ambiguous/unmatched
# logic as every other state here.
#
# ADDRESS. city/state/zip are captured. CT DPH does not document whether this
# is a mailing or practice address -- labeled here as board-reported, not
# asserted to be either. Spot-checked directly: at least one sampled record
# carries an out-of-state (NY) address for a CT-licensed APRN, so this is not
# reliably a Connecticut practice location even for a CT license.
#
# Matched by last+first name (same key scheme as the WA/CO/TX/IL scripts)
# against nppes_state == "CT" in the tracked cohort -- NOT a license-number or
# NPI join, because CT DPH's dataset carries neither an AMCB nor an NPI
# identifier. Name matching is imperfect; this script reports what it found
# as its own result, not a confirmation of AMCB/NPPES identity. CT DPH's
# `name` field is a single combined string ("Lynn M NUSSBAUM"), not separate
# first/last columns -- split on whitespace, first token as first name, last
# token as last name, which will mis-split a multi-word last name (rare, not
# corrected here; such rows simply fail to match rather than matching wrong).
#
# COHORT: artifacts/tracked_roster_active_primary_linked.csv (tracked; built
# by build_tracked_roster.R), the same source the WA/TX/IL scripts use.
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

print("=== Live Connecticut BON cross-reference (tracked-roster cohort) ===")

CT_API = "https://data.ct.gov/resource/f4xa-y96m.json"
CT_QUERY = {
    "$limit": "50000",
}
ct_url = CT_API + "?" + urllib.parse.urlencode(CT_QUERY)
req = urllib.request.Request(ct_url, headers={"User-Agent": "Mozilla/5.0"})


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


def split_name(full_name):
    """CT DPH's `name` field is one combined string. First/last token split."""
    parts = (full_name or "").strip().split()
    if len(parts) < 2:
        return "", ""
    return parts[0].upper(), parts[-1].upper()


retrieved_at = datetime.now(timezone.utc)
live_ct_records = []
try:
    with urllib.request.urlopen(req, context=verified_tls_context(), timeout=60) as response:
        live_ct_records = json.loads(response.read().decode("utf-8"))
    print(f"Successfully streamed {len(live_ct_records):,} live CT APRN license records.")
except Exception as e:
    print(f"Error fetching live CT BON data: {e}")
    raise SystemExit(1)

# Index live CT records by Last_First name -- same key scheme as the other scripts.
ct_lookup = {}
for r in live_ct_records:
    fn, ln = split_name(r.get("name"))
    if fn and ln:
        ct_lookup.setdefault(f"{ln}_{fn}", []).append(r)

# Cross-reference against the TRACKED roster, filtered to CT.
roster_file = "artifacts/tracked_roster_active_primary_linked.csv"
matched_ct = []
unmatched_ct = []

with open(roster_file, "r", encoding="utf-8", errors="ignore") as f:
    reader = csv.DictReader(f)
    for r in reader:
        st = r.get("nppes_state", "").upper().strip()
        if st != "CT":
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
        candidates = ct_lookup.get(key, [])
        if len(candidates) == 1:
            ct_info = candidates[0]
            out["live_bon_credential_num"] = ct_info.get("credentialnumber", "")
            out["live_bon_status"] = ct_info.get("status", "")
            out["live_bon_status_reason"] = ct_info.get("statusreason", "")
            out["live_bon_city"] = ct_info.get("city", "")
            out["live_bon_state"] = ct_info.get("state", "")
            out["live_bon_zip"] = ct_info.get("zip", "")
            out["live_bon_match_status"] = "VERIFIED_LIVE_BON"
            matched_ct.append(out)
        else:
            # 0 candidates: no name match at all. >1: an ambiguous common name
            # -- reported as unmatched rather than guessed, same as the
            # IL script's handling of name collisions. More likely here than
            # in CO/TX since there is no CNM-specific pre-filter.
            out["live_bon_credential_num"] = "NA"
            out["live_bon_status"] = "UNMATCHED_BON" if not candidates else "AMBIGUOUS_BON"
            out["live_bon_status_reason"] = "NA"
            out["live_bon_city"] = "NA"
            out["live_bon_state"] = "NA"
            out["live_bon_zip"] = "NA"
            out["live_bon_match_status"] = "UNMATCHED" if not candidates else "AMBIGUOUS"
            unmatched_ct.append(out)

out_csv = "artifacts/live_connecticut_bon_ingested_midwives_from_tracked_roster.csv"
out_provenance = out_csv + ".provenance.json"
rows = matched_ct + unmatched_ct
if rows:
    fieldnames = list(rows[0].keys())
    with open(out_csv, "w", encoding="utf-8", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)

    write_provenance(
        out_csv,
        source_url=ct_url,
        accessed_utc=retrieved_at.strftime("%Y-%m-%dT%H:%M:%SZ"),
        source_dataset="Connecticut DPH, Advanced Practice Registered Nurse Licenses (data.ct.gov f4xa-y96m) -- not CNM-specific, no API-level specialty filter exists",
        records_retrieved=len(live_ct_records),
        cohort=roster_file,
        cohort_sha256=sha256_file(roster_file),
        cohort_rows_ct=len(rows),
        cohort_matched_rows=len(matched_ct),
        match_key="last_name + first_name, split from CT's single combined name field (upper, trimmed); ambiguous names reported unmatched",
        verification_portal="https://www.elicense.ct.gov/Lookup/LicenseLookup.aspx",
        address_fields="live_bon_city/state/zip, board-reported -- CT DPH does not document whether this is mailing or practice address, and at least one sampled record carries an out-of-state address",
    )
    print(f"  Provenance: {out_provenance}")

n_total = len(matched_ct) + len(unmatched_ct)
print("=========================================================================")
print("  LIVE CT BON CROSS-REFERENCE COMPLETE (tracked-roster cohort)")
print(f"  Total CT-state rows in tracked roster : {n_total:,}")
if n_total:
    print(f"  Live State BON Matched                : {len(matched_ct):,} ({len(matched_ct)/n_total*100:.1f}%)")
print(f"  Written to: {out_csv}")
print(f"  Provenance: {out_provenance}")
print("=========================================================================")
