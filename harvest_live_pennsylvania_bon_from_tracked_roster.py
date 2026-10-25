#!/usr/bin/env python3
# =============================================================================
# Live Pennsylvania BON cross-reference, using the TRACKED roster as cohort
# =============================================================================
# Source: the Pennsylvania Licensing System (PALS, www.pals.pa.gov), the
# Department of State Bureau of Professional and Occupational Affairs'
# public license-verification service. No login, no API key.
#
# SCOPE NOTE. Pennsylvania regulates nurse-midwives under the STATE BOARD OF
# MEDICINE (ProfessionID 37), not the State Board of Nursing -- confirmed by
# reading both boards' License Type lists directly off the live search form.
# The State Board of Nursing's list has no midwife-related entry at all;
# the State Board of Medicine's list includes "Nurse-Midwife" (LicenseTypeId
# 234) and "Nurse-Midwife Prescriptive Authority" as separate license types.
# This harvester requests ProfessionID=37, LicenseTypeId=234 specifically --
# i.e. it is already CNM-specific by construction, unlike Florida (no CNM
# category exists there at all) or California (a separate LM credential
# exists alongside the CNM one, but is a different board/license type).
#
# REQUEST SHAPE. The search form's "Search" button calls one clean JSON POST
# endpoint, no CAPTCHA token or session cookie required (confirmed directly
# with a bare `curl`, no browser, no cookies at all):
#
#   POST https://www.pals.pa.gov/api/Search/SearchForPersonOrFacilty
#     {"OptPersonFacility":"Person","ProfessionID":37,"LicenseTypeId":234,
#      "State":"","Country":"ALL","County":null,"IsFacility":0,
#      "PersonId":null,"PageNo":<n>}
#
# A reCAPTCHA v3 script IS loaded on the page, but it is not wired to this
# endpoint -- the captured request body carries no token, and the bare curl
# request above succeeds with real data. (A "RecaptchaResponse" field
# appears in the RESPONSE carrying the caller's IP address; that is
# PALS logging metadata, not an enforcement check on the request.)
#
# Each page returns 50 records with TotalRecords in every row; 500 current
# Nurse-Midwife licensees fit in 10 pages. Every record already carries
# City, State, County and zipcode directly -- no separate geocoding or
# detail-page fetch needed, unlike Florida.
#
# Matched by last+first name (same key scheme as every other BON harvester
# here) against nppes_state == "PA" in the tracked FROZEN linkage -- this
# source carries no AMCB or NPI identifier to join on deterministically.
# =============================================================================
import csv
import json
import os
import sys
import time
import urllib.request

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "tools"))
from provenance import sha256_file, utc_now, write_provenance  # noqa: E402

print("=== Live Pennsylvania BON (Nurse-Midwife) cross-reference (tracked-roster cohort) ===")

SEARCH_URL = "https://www.pals.pa.gov/api/Search/SearchForPersonOrFacilty"
NURSE_MIDWIFE_PROFESSION_ID = 37   # State Board of Medicine
NURSE_MIDWIFE_LICENSE_TYPE_ID = 234  # "Nurse-Midwife"
PAGE_DELAY_SECONDS = 0.5


def fetch_pa_nurse_midwives(opener=urllib.request.urlopen):
    """Page through every current Nurse-Midwife record. Raises if the first
    page's response doesn't look like this endpoint's known shape (so a
    silently-changed API surfaces as a clear error, not an empty result).
    """
    all_records = []
    page_no = 1
    total = None
    while True:
        body = json.dumps({
            "OptPersonFacility": "Person",
            "ProfessionID": NURSE_MIDWIFE_PROFESSION_ID,
            "LicenseTypeId": NURSE_MIDWIFE_LICENSE_TYPE_ID,
            "State": "", "Country": "ALL", "County": None,
            "IsFacility": 0, "PersonId": None, "PageNo": page_no,
        }).encode("utf-8")
        req = urllib.request.Request(SEARCH_URL, data=body, method="POST",
                                      headers={"Content-Type": "application/json",
                                               "User-Agent": "Mozilla/5.0"})
        with opener(req, timeout=30) as resp:
            page = json.loads(resp.read().decode("utf-8"))

        if page_no == 1:
            if not isinstance(page, list) or (page and "TotalRecords" not in page[0]):
                raise RuntimeError(f"unexpected response shape on page 1: {str(page)[:300]}")
            total = page[0]["TotalRecords"] if page else 0

        if not page:
            break
        all_records.extend(page)
        if len(all_records) >= total:
            break
        page_no += 1
        time.sleep(PAGE_DELAY_SECONDS)

    return all_records, total


def build_pa_lookup(records):
    """Index live PA Nurse-Midwife records by Last_First name. A record
    missing either name half is never indexed under a partial key.
    """
    lookup = {}
    for r in records:
        ln = (r.get("LastName") or "").upper().strip()
        fn = (r.get("FirstName") or "").upper().strip()
        if fn and ln:
            lookup.setdefault(f"{ln}_{fn}", []).append(r)
    return lookup


def match_cohort_to_pa_bon(cohort_rows, pa_records):
    """Join the PA-filtered cohort rows against live PALS Nurse-Midwife
    records by last+first name. Returns (matched, unmatched). A name
    resolving to more than one live record is AMBIGUOUS, never guessed.
    """
    lookup = build_pa_lookup(pa_records)
    matched, unmatched = [], []

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
        candidates = lookup.get(key, []) if (fn and ln) else []
        if len(candidates) == 1:
            info = candidates[0]
            out["live_bon_license_number"] = info.get("LicenseNumber", "")
            out["live_bon_status"] = info.get("Status", "")
            out["live_bon_city"] = info.get("City", "")
            out["live_bon_county"] = info.get("County", "")
            out["live_bon_zip"] = info.get("zipcode", "")
            out["live_bon_match_status"] = "VERIFIED_LIVE_BON"
            matched.append(out)
        else:
            out["live_bon_license_number"] = "NA"
            out["live_bon_status"] = "UNMATCHED_BON" if not candidates else "AMBIGUOUS_BON"
            out["live_bon_city"] = "NA"
            out["live_bon_county"] = "NA"
            out["live_bon_zip"] = "NA"
            out["live_bon_match_status"] = "UNMATCHED" if not candidates else "AMBIGUOUS"
            unmatched.append(out)

    return matched, unmatched


def load_pa_cohort_rows(roster_file):
    with open(roster_file, "r", encoding="utf-8", errors="ignore") as f:
        reader = csv.DictReader(f)
        return [r for r in reader if (r.get("nppes_state") or "").upper().strip() == "PA"]


def main():
    accessed_utc = utc_now()
    try:
        pa_records, total = fetch_pa_nurse_midwives()
        print(f"Successfully retrieved {len(pa_records):,} of {total:,} live PA Nurse-Midwife records.")
    except Exception as e:
        print(f"Error fetching live PA BON data: {e}")
        raise SystemExit(1)

    roster_file = "artifacts/amcb_npi_linkage_FROZEN.csv"
    cohort_rows = load_pa_cohort_rows(roster_file)
    matched, unmatched = match_cohort_to_pa_bon(cohort_rows, pa_records)

    out_csv = "artifacts/live_pennsylvania_bon_ingested_midwives_from_tracked_roster.csv"
    rows = matched + unmatched
    if rows:
        fieldnames = list(rows[0].keys())
        with open(out_csv, "w", encoding="utf-8", newline="") as f:
            writer = csv.DictWriter(f, fieldnames=fieldnames)
            writer.writeheader()
            writer.writerows(rows)

        write_provenance(
            out_csv,
            source_url=SEARCH_URL + " (ProfessionID=37 'State Board of Medicine', "
                                     "LicenseTypeId=234 'Nurse-Midwife')",
            accessed_utc=accessed_utc,
            source_dataset="Pennsylvania Licensing System (PALS), www.pals.pa.gov",
            records_retrieved=len(pa_records),
            cohort=roster_file,
            cohort_sha256=sha256_file(roster_file),
            cohort_rows_pa=len(rows),
            cohort_matched_rows=len(matched),
            match_key="last_name + first_name (upper, trimmed); ambiguous names reported unmatched",
            verification_portal="https://www.pals.pa.gov/#!/page/search",
        )
        print(f"  Provenance: {out_csv}.provenance.json")

    n_total = len(matched) + len(unmatched)
    print("=========================================================================")
    print("  LIVE PA BON (NURSE-MIDWIFE) CROSS-REFERENCE COMPLETE (tracked-roster cohort)")
    print(f"  Total PA-state rows in tracked roster : {n_total:,}")
    if n_total:
        print(f"  Live State BON Matched                : {len(matched):,} ({len(matched)/n_total*100:.1f}%)")
    print(f"  Written to: {out_csv}")
    print("=========================================================================")


if __name__ == "__main__":
    main()
