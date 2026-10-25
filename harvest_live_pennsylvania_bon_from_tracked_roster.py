#!/usr/bin/env python3
# =============================================================================
# Live Pennsylvania BON cross-reference, using the TRACKED roster as the cohort
# =============================================================================
# Source: the Pennsylvania Licensing System (PALS), Bureau of Professional and
# Occupational Affairs -- a public, no-login JSON API confirmed live
# (2026-10-25):
#   POST https://www.pals.pa.gov/api/Search/SearchForPersonOrFacilty
# Discovered by instrumenting PALS's own search UI (its dropdown selections
# never actually bound into Angular's request -- caught by monkey-patching
# XMLHttpRequest to capture the real outgoing request body) rather than
# guessing field names; every field and behavior documented below was
# confirmed against the live API, not assumed.
#
# NO "CERTIFIED NURSE MIDWIFE" LICENSE TYPE EXISTS IN PA. The State Board of
# Nursing's full license-type list (read directly from the PALS search
# form's own dropdown, 2026-10-25) is: Certified Registered Nurse
# Anesthetist, Certified Registered Nurse Practitioner, Clinical Nurse
# Specialist, Registered Nurse, Practical Nurse, Prescriptive Authority,
# plus temporary/military/volunteer variants of each -- no midwife-specific
# category anywhere. If PA licenses CNMs at all, they are folded into
# "Certified Registered Nurse Practitioner" (ProfessionID=43 Nursing,
# LicenseTypeId=321 CRNP) with no specialty tag this API exposes. Same
# situation as harvest_live_il_bon_from_tracked_roster.py and
# harvest_live_ct_bon_from_tracked_roster.py: this pulls the CRNP
# population, not a CNM-specific one, and relies on name-matching alone.
#
# THE API HARD-CAPS AT 500 RESULTS PER QUERY (confirmed 2026-10-25: an
# unscoped statewide CRNP query returns exactly 10 pages of 50 then 0 at
# page 11 -- while Philadelphia alone returns 250+ on its own, proving the
# true statewide CRNP population is well over 500 and the cap is an
# artificial ceiling, not the real count). A single-character LastName
# filter was tested and found UNRELIABLE (querying "S" returned names
# starting with "MONHEIT" -- the backend appears to silently ignore
# single-character filters rather than apply them); a two-character prefix
# filters correctly (confirmed: "Sm" returned only SMAIL/SMALDONE/SMALE/
# SMALL...). This script therefore queries the first two letters of each
# COHORT member's own last name -- not an exhaustive 26x26 sweep of the
# whole alphabet, since the only records that can ever match the cohort are
# the ones sharing a cohort member's own prefix. 461 PA cohort rows reduce
# to 135 distinct two-letter prefixes (2026-10-25) -- well under the API's
# per-prefix cap for any of them in practice, but fetch_all_for_prefix()
# still paginates and WARNS LOUDLY rather than silently truncating if any
# single prefix ever does hit the 500-row ceiling.
#
# Matched by last+first name (same key scheme as every other state script
# here) against nppes_state == "PA" in the tracked roster -- NOT a license-
# number or NPI join, since PALS carries neither an AMCB nor an NPI
# identifier.
#
# ADDRESS. city/state/zip/county are captured, confirmed as genuine
# separate JSON response fields (City, State, zipcode, County), not a
# parsed display string. PALS does not document whether this is a mailing
# or practice address.
#
# COHORT: artifacts/tracked_roster_active_primary_linked.csv (tracked; built
# by build_tracked_roster.R), the same source every other state script here
# uses.
#
# TLS: verification stays ON (see harvest_live_tx_bon_from_tracked_roster.py
# for why CERT_NONE is never acceptable here).
# =============================================================================
import csv
import json
import os
import ssl
import sys
import time
import urllib.request

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "tools"))
from provenance import sha256_file, utc_now, write_provenance  # noqa: E402

print("=== Live Pennsylvania BON cross-reference (tracked-roster cohort) ===")

PALS_API = "https://www.pals.pa.gov/api/Search/SearchForPersonOrFacilty"
PROFESSION_ID_NURSING = 43
LICENSE_TYPE_ID_CRNP = 321
SLEEP_BETWEEN_REQUESTS = 1.0  # seconds; courtesy rate limit, not required by the API
PAGE_SIZE = 50
MAX_PAGES_PER_PREFIX = 10  # 10 x 50 = the API's own 500-result cap


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


TLS_CONTEXT = verified_tls_context()


def fetch_page(last_name_prefix, page_no):
    body = json.dumps({
        "OptPersonFacility": "Person", "State": "", "Country": "ALL",
        "County": None, "IsFacility": 0, "PersonId": None,
        "PageNo": page_no, "ProfessionID": PROFESSION_ID_NURSING,
        "LicenseTypeId": LICENSE_TYPE_ID_CRNP, "LastName": last_name_prefix,
    }).encode("utf-8")
    req = urllib.request.Request(PALS_API, data=body, headers={
        "Content-Type": "application/json", "User-Agent": "Mozilla/5.0",
    })
    with urllib.request.urlopen(req, context=TLS_CONTEXT, timeout=30) as resp:
        return json.loads(resp.read().decode("utf-8"))


def fetch_all_for_prefix(prefix):
    """Paginate one 2-letter last-name prefix until a short/empty page."""
    records = []
    page_no = 1
    while True:
        page = fetch_page(prefix, page_no)
        records.extend(page)
        if len(page) < PAGE_SIZE:
            break
        if page_no >= MAX_PAGES_PER_PREFIX:
            print(f"  WARNING: prefix '{prefix}' hit the {PAGE_SIZE * MAX_PAGES_PER_PREFIX}-result "
                  f"cap -- results for this prefix are INCOMPLETE. Needs a finer "
                  f"(3-letter) split, not implemented in this script.")
            break
        page_no += 1
        time.sleep(SLEEP_BETWEEN_REQUESTS)
    return records


# Cross-reference against the TRACKED roster, filtered to PA.
roster_file = "artifacts/tracked_roster_active_primary_linked.csv"
with open(roster_file, "r", encoding="utf-8", errors="ignore") as f:
    cohort_rows = [r for r in csv.DictReader(f) if (r.get("nppes_state", "").upper().strip() == "PA")]
retrieved_at = utc_now()

print(f"PA-state rows in tracked roster: {len(cohort_rows):,}")

# Only the 2-letter last-name prefixes actually present in the cohort -- not
# an exhaustive A-Z x A-Z sweep (676 queries) of the whole alphabet. See this
# script's own header for why single-letter prefixes don't filter reliably.
prefixes_needed = sorted({
    (r.get("last_name", "") or "").strip()[:2].upper()
    for r in cohort_rows
    if len((r.get("last_name", "") or "").strip()) >= 2
})
print(f"Distinct 2-letter last-name prefixes to query: {len(prefixes_needed)}")

pa_lookup = {}
retrieved_total = 0
for i, prefix in enumerate(prefixes_needed, 1):
    recs = fetch_all_for_prefix(prefix)
    retrieved_total += len(recs)
    for r in recs:
        fn = (r.get("FirstName") or "").upper().strip()
        ln = (r.get("LastName") or "").upper().strip()
        if fn and ln:
            pa_lookup.setdefault(f"{ln}_{fn}", []).append(r)
    print(f"  [{i}/{len(prefixes_needed)}] '{prefix}': {len(recs)} CRNP records")
    time.sleep(SLEEP_BETWEEN_REQUESTS)

print(f"Total CRNP records retrieved across {len(prefixes_needed)} prefixes: {retrieved_total:,}")

# Index live PA records by Last_First name -- same key scheme as the other scripts.
matched_pa = []
unmatched_pa = []

for r in cohort_rows:
    fn = (r.get("nppes_first_name") or r.get("first_name") or "").upper().strip()
    ln = (r.get("nppes_last_name") or r.get("last_name") or "").upper().strip()
    key = f"{ln}_{fn}"

    out = {
        "certification_number": r.get("certification_number", ""),
        "last_name": r.get("last_name", ""),
        "first_name": r.get("first_name", ""),
        "npi": r.get("npi", ""),
        "nppes_state": "PA",
    }
    candidates = pa_lookup.get(key, []) if (fn and ln) else []
    if len(candidates) == 1:
        info = candidates[0]
        out["live_bon_license_number"] = info.get("LicenseNumber", "")
        out["live_bon_status"] = info.get("Status", "")
        out["live_bon_city"] = info.get("City", "")
        out["live_bon_state"] = info.get("State", "")
        out["live_bon_zip"] = info.get("zipcode", "")
        out["live_bon_county"] = info.get("County", "")
        out["live_bon_match_status"] = "VERIFIED_LIVE_BON"
        matched_pa.append(out)
    else:
        # 0 candidates: no name match at all. >1: an ambiguous common name
        # -- reported as unmatched rather than guessed, same as every other
        # state script here. Likely here than in NPI-filtered states (CO/TX)
        # since there is no CNM-specific pre-filter -- the CRNP population
        # this draws from is much larger than just midwives.
        out["live_bon_license_number"] = "NA"
        out["live_bon_status"] = "UNMATCHED_BON" if not candidates else "AMBIGUOUS_BON"
        out["live_bon_city"] = "NA"
        out["live_bon_state"] = "NA"
        out["live_bon_zip"] = "NA"
        out["live_bon_county"] = "NA"
        out["live_bon_match_status"] = "UNMATCHED" if not candidates else "AMBIGUOUS"
        unmatched_pa.append(out)

out_csv = "artifacts/live_pennsylvania_bon_ingested_midwives_from_tracked_roster.csv"
out_provenance = out_csv + ".provenance.json"
rows = matched_pa + unmatched_pa

fieldnames = ["certification_number", "last_name", "first_name", "npi", "nppes_state",
              "live_bon_license_number", "live_bon_status", "live_bon_city",
              "live_bon_state", "live_bon_zip", "live_bon_county", "live_bon_match_status"]
with open(out_csv, "w", encoding="utf-8", newline="") as f:
    writer = csv.DictWriter(f, fieldnames=fieldnames)
    writer.writeheader()
    writer.writerows(rows)

write_provenance(
    out_csv,
    source_url=PALS_API,
    accessed_utc=retrieved_at,
    source_dataset="Pennsylvania Licensing System (PALS), Bureau of Professional and Occupational "
                    "Affairs, State Board of Nursing (ProfessionID=43), License Type = Certified "
                    "Registered Nurse Practitioner (LicenseTypeId=321) -- not CNM-specific, no "
                    "midwife license type exists in PA's Board of Nursing system at all",
    records_retrieved=retrieved_total,
    prefixes_queried=len(prefixes_needed),
    cohort=roster_file,
    cohort_sha256=sha256_file(roster_file),
    cohort_rows_pa=len(rows),
    cohort_matched_rows=len(matched_pa),
    match_key="last_name + first_name (upper, trimmed); ambiguous names reported unmatched",
    verification_portal="https://www.pals.pa.gov/#!/page/search",
    address_fields="live_bon_city/state/zip/county, board-reported -- PALS does not document whether "
                    "this is mailing or practice address",
    known_limitation="the live API hard-caps any single query at 500 results; this script queries "
                      "only the 2-letter last-name prefixes present in the PA cohort (not an "
                      "exhaustive A-Z sweep) and warns in its own output if any single prefix ever "
                      "hits that cap",
)
print(f"  Provenance: {out_provenance}")

n_total = len(matched_pa) + len(unmatched_pa)
print("=========================================================================")
print("  LIVE PA BON CROSS-REFERENCE COMPLETE (tracked-roster cohort)")
print(f"  Total PA-state rows in tracked roster : {n_total:,}")
if n_total:
    print(f"  Live State BON Matched                 : {len(matched_pa):,} ({len(matched_pa)/n_total*100:.1f}%)")
print(f"  Written to: {out_csv}")
print(f"  Provenance: {out_provenance}")
print("=========================================================================")
