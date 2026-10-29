#!/usr/bin/env python3
# =============================================================================
# Live Florida BON cross-reference, using the TRACKED roster as the cohort
# =============================================================================
# Source: the Florida DOH Division of Medical Quality Assurance's public
# License Verification tool (mqa-internet.doh.state.fl.us/MQASearchServices),
# a plain ASP.NET MVC form -- no login, no API key, no bot-blocking observed.
# The real bulk-download portal (mqa-internet.doh.state.fl.us/downloadnet)
# requires creating an account and was NOT used for that reason (account
# creation is out of scope for an unattended script); this harvester instead
# does one search per tracked-roster name, the same shape the public itself
# uses.
#
# SCOPE NOTE, READ BEFORE TRUSTING A MATCH. Florida has no searchable
# "Certified Nurse Midwife" profession category. The closest category in its
# system, "Midwifery" (profession code 3201), is Florida's separate,
# non-nurse LICENSED MIDWIFE credential under the Council of Licensed
# Midwifery -- a different credential from the AMCB-certified CNM/CM cohort
# this project tracks, parallel to the LM-vs-CNM split already documented
# for California. Confirmed empirically: two real FL cohort members searched
# with no profession filter returned zero or APRN-only results, never a
# Midwifery-profession hit.
#
# AMCB-certified CNMs are instead folded into Florida's generic "Advanced
# Practice Registered Nurse" profession (code 1711) -- the SAME category as
# nurse practitioners, CRNAs, and clinical nurse specialists. A name match
# under that profession code therefore does NOT by itself confirm the person
# is a midwife; it only confirms an APRN license exists under that name.
# Disambiguation uses the one piece of real signal the detail page provides:
# each license's "Qualifications" list, which separately states whether the
# license carries "Certified Nurse Midwife" among its APRN qualifications
# (most records list one or more, e.g. "Certified Nurse Midwife" and/or
# "Nurse Practitioner"). A match is reported ONLY when "Certified Nurse
# Midwife" appears in that list -- an APRN match under the right name whose
# qualifications do NOT include it is reported separately
# (NOT_CNM_QUALIFIED), not silently counted as a midwife.
#
# REQUEST SHAPE. Searching by last+first name together, when it resolves to
# exactly one license, has the server itself redirect straight to that
# license's detail page (which already carries Qualifications) -- no second
# request needed. When more than one license shares that exact name, the
# server instead returns a list of candidates with no qualifications shown
# inline; each candidate's detail page is then fetched separately to check
# Qualifications, and the match is accepted only if exactly one candidate
# qualifies as Certified Nurse Midwife (more than one is reported AMBIGUOUS
# rather than guessed, same discipline as every other BON harvester here).
# A plain POST with a fresh __RequestVerificationToken (ASP.NET's anti-
# forgery token, read off a prior GET of the same page) and that GET's
# session cookie is sufficient; no browser automation is needed here, unlike
# the NM harvester.
# =============================================================================
import csv
import html
import os
import re
import sys
import time
import urllib.error
import urllib.request
from http.cookiejar import CookieJar
from urllib.parse import urlencode

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "tools"))
from provenance import sha256_file, utc_now, write_provenance  # noqa: E402

print("=== Live Florida BON (APRN) cross-reference (tracked-roster cohort) ===")

SEARCH_URL = "https://mqa-internet.doh.state.fl.us/MQASearchServices/HealthCareProviders"
DETAIL_URL = "https://mqa-internet.doh.state.fl.us/MQASearchServices/HealthCareProviders/LicenseVerification"
APRN_PROFESSION_CODE = "1711"
REQUEST_DELAY_SECONDS = 0.5  # courtesy pacing against a shared .gov lookup tool


def make_opener():
    """A urllib opener that persists cookies across requests -- the search
    POST's session must match the cookie set by the earlier token GET.
    """
    jar = CookieJar()
    return urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))


def fetch_search_token(opener):
    """GET the search form once to obtain a fresh anti-forgery token tied to
    this opener's cookie jar.
    """
    req = urllib.request.Request(SEARCH_URL, headers={"User-Agent": "Mozilla/5.0"})
    with opener.open(req, timeout=30) as resp:
        body = resp.read().decode("utf-8", errors="replace")
    m = re.search(r'__RequestVerificationToken"[^>]*value="([^"]+)"', body)
    if not m:
        raise RuntimeError("could not find __RequestVerificationToken on the search page -- "
                            "the form may have changed")
    return m.group(1)


def _unescape(s):
    return html.unescape(s).strip()


def parse_detail_page(body):
    """Extract license number, status, address and Qualifications from a
    detail page's HTML. Returns None if this isn't recognizably a detail
    page (caller should treat that as an error, not an empty match).
    """
    m_lic = re.search(r"License Number:\s*([A-Z0-9]+)\s*</h3>", body)
    if not m_lic:
        return None
    license_number = m_lic.group(1)

    m_status = re.search(r"License Status\s*</dt>\s*<dd>\s*([^<]+?)\s*</dd>", body, re.S)
    status = _unescape(m_status.group(1)) if m_status else ""

    # The detail page renders the address as FOUR <dt>/<dd> pairs after the
    # "Address of Record" label: street, two blank spacer lines, then
    # "CITY, ST ZIP" -- confirmed directly off the live HTML (2026-10-26),
    # not assumed. A practitioner with no address on file instead gets a
    # leading disclaimer paragraph wrapped in its own <dd><p>...</p></dd>
    # under a FIRST "Address of Record" label, with the real (four-line)
    # block repeated right after it; the lazy, zero-width first capture
    # group below can't match through that <p> tag, so re.search already
    # skips past the disclaimer copy to the real block without special
    # casing it.
    m_addr = re.search(
        r"Address of Record\s*</dt>\s*<dd>\s*([^<]*?)\s*</dd>\s*"
        r"<dt>\s*</dt>\s*<dd>\s*([^<]*?)\s*</dd>\s*"
        r"<dt>\s*</dt>\s*<dd>\s*([^<]*?)\s*</dd>\s*"
        r"<dt>\s*</dt>\s*<dd>\s*([^<]*?)\s*</dd>",
        body, re.S)
    address = _unescape(m_addr.group(1)) if m_addr else ""
    city_state_zip = _unescape(m_addr.group(4)) if m_addr else ""
    m_csz = re.match(r"^([^,]+),\s*([A-Z]{2})\s+(\d{5})(?:-\d{4})?$", city_state_zip)
    city = m_csz.group(1).strip() if m_csz else ""
    state = m_csz.group(2) if m_csz else ""
    zip5 = m_csz.group(3) if m_csz else ""

    m_qual_block = re.search(
        r"Qualifications\s*</dt>\s*((?:<dd>[^<]*</dd>\s*)+)", body, re.S)
    qualifications = []
    if m_qual_block:
        qualifications = [_unescape(q) for q in re.findall(r"<dd>([^<]*)</dd>", m_qual_block.group(1))]

    return {"license_number": license_number, "status": status, "address": address,
            "city": city, "state": state, "zip": zip5, "qualifications": qualifications}


def parse_list_page(body):
    """Extract (lic_ind, license_number) pairs from a multi-candidate
    results list page.
    """
    return re.findall(r'LicenseVerification\?LicInd=(\d+)&amp;ProCde=\d+">([A-Z0-9]+)</a>', body)


def search_fl_aprn(last_name, first_name, token, opener):
    """Search by last+first name under the APRN profession. Returns one of:
      {"type": "detail", **parse_detail_page(...)}        -- unique match
      {"type": "list", "candidates": [(lic_ind, lic_no), ...]}  -- ambiguous
      {"type": "none"}                                      -- no match
    Raises on anything that isn't recognizably one of these three shapes.
    """
    data = urlencode({
        "__RequestVerificationToken": token,
        "SearchDto.Profession": APRN_PROFESSION_CODE,
        "SearchDto.LastName": last_name,
        "SearchDto.FirstName": first_name,
    }).encode("utf-8")
    req = urllib.request.Request(SEARCH_URL, data=data, method="POST",
                                  headers={"User-Agent": "Mozilla/5.0",
                                           "Content-Type": "application/x-www-form-urlencoded"})
    with opener.open(req, timeout=30) as resp:
        body = resp.read().decode("utf-8", errors="replace")

    if "No records found" in body:
        return {"type": "none"}

    detail = parse_detail_page(body)
    if detail is not None:
        return {"type": "detail", **detail}

    candidates = parse_list_page(body)
    if candidates:
        return {"type": "list", "candidates": candidates}

    raise RuntimeError(f"unrecognized response shape for {last_name}, {first_name} -- "
                        f"neither a detail page, a candidate list, nor 'No records found'")


def fetch_detail(lic_ind, opener):
    url = f"{DETAIL_URL}?LicInd={lic_ind}&ProCde={APRN_PROFESSION_CODE}"
    req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
    with opener.open(req, timeout=30) as resp:
        body = resp.read().decode("utf-8", errors="replace")
    detail = parse_detail_page(body)
    if detail is None:
        raise RuntimeError(f"could not parse detail page for LicInd={lic_ind}")
    return detail


def resolve_cnm_match(last_name, first_name, token, opener):
    """Search, then resolve to a single CNM-qualified match if one exists.
    Returns a dict with match_status one of VERIFIED_LIVE_BON,
    NOT_CNM_QUALIFIED (an APRN match exists but isn't CNM-qualified),
    AMBIGUOUS, or UNMATCHED.
    """
    result = search_fl_aprn(last_name, first_name, token, opener)

    if result["type"] == "none":
        return {"match_status": "UNMATCHED"}

    if result["type"] == "detail":
        is_cnm = "Certified Nurse Midwife" in result["qualifications"]
        return {
            "match_status": "VERIFIED_LIVE_BON" if is_cnm else "NOT_CNM_QUALIFIED",
            "license_number": result["license_number"],
            "status": result["status"],
            "address": result["address"],
            "city": result["city"],
            "state": result["state"],
            "zip": result["zip"],
            "qualifications": "; ".join(result["qualifications"]),
        }

    # Ambiguous list: check each candidate's qualifications.
    cnm_candidates = []
    for lic_ind, lic_no in result["candidates"]:
        time.sleep(REQUEST_DELAY_SECONDS)
        detail = fetch_detail(lic_ind, opener)
        if "Certified Nurse Midwife" in detail["qualifications"]:
            cnm_candidates.append(detail)

    if len(cnm_candidates) == 1:
        d = cnm_candidates[0]
        return {"match_status": "VERIFIED_LIVE_BON", "license_number": d["license_number"],
                "status": d["status"], "address": d["address"],
                "city": d["city"], "state": d["state"], "zip": d["zip"],
                "qualifications": "; ".join(d["qualifications"])}
    if len(cnm_candidates) == 0:
        return {"match_status": "NOT_CNM_QUALIFIED"}
    return {"match_status": "AMBIGUOUS"}


def main():
    accessed_utc = utc_now()
    opener = make_opener()
    try:
        token = fetch_search_token(opener)
    except Exception as e:
        print(f"Error fetching live FL BON search token: {e}")
        raise SystemExit(1)

    roster_file = "artifacts/amcb_npi_linkage_FROZEN.csv"
    with open(roster_file, "r", encoding="utf-8", errors="ignore") as f:
        reader = csv.DictReader(f)
        fl_cohort = [r for r in reader if (r.get("nppes_state") or "").upper().strip() == "FL"]

    matched = []
    unmatched = []
    n = len(fl_cohort)
    for i, r in enumerate(fl_cohort, start=1):
        fn = (r.get("nppes_first_name") or r.get("first_name") or "").strip()
        ln = (r.get("nppes_last_name") or r.get("last_name") or "").strip()

        out = {
            "certification_number": r.get("certification_number", ""),
            "last_name": r.get("last_name", ""),
            "first_name": r.get("first_name", ""),
            "npi": r.get("npi", ""),
            "nppes_state": "FL",
        }

        if not (fn and ln):
            out["live_bon_match_status"] = "UNMATCHED"
            out["live_bon_license_number"] = "NA"
            out["live_bon_status"] = "NA"
            out["live_bon_address"] = "NA"
            out["live_bon_city"] = "NA"
            out["live_bon_state"] = "NA"
            out["live_bon_zip"] = "NA"
            unmatched.append(out)
            continue

        try:
            resolved = resolve_cnm_match(ln, fn, token, opener)
        except Exception as e:
            print(f"  [{i}/{n}] {ln}, {fn}: ERROR {e}")
            resolved = {"match_status": "UNMATCHED"}

        out["live_bon_match_status"] = resolved["match_status"]
        out["live_bon_license_number"] = resolved.get("license_number", "NA")
        out["live_bon_status"] = resolved.get("status", "NA")
        out["live_bon_address"] = resolved.get("address", "NA")
        out["live_bon_city"] = resolved.get("city", "NA")
        out["live_bon_state"] = resolved.get("state", "NA")
        out["live_bon_zip"] = resolved.get("zip", "NA")

        (matched if resolved["match_status"] == "VERIFIED_LIVE_BON" else unmatched).append(out)

        if i % 100 == 0:
            print(f"  [{i}/{n}] processed, {len(matched)} verified CNM matches so far")
        time.sleep(REQUEST_DELAY_SECONDS)

    out_csv = "artifacts/live_florida_bon_ingested_midwives_from_tracked_roster.csv"
    rows = matched + unmatched
    if rows:
        fieldnames = list(rows[0].keys())
        with open(out_csv, "w", encoding="utf-8", newline="") as f:
            writer = csv.DictWriter(f, fieldnames=fieldnames)
            writer.writeheader()
            writer.writerows(rows)

        write_provenance(
            out_csv,
            source_url=SEARCH_URL + " (Profession=1711 'Advanced Practice Registered Nurse'; "
                                     "matches accepted only when the license's Qualifications "
                                     "list includes 'Certified Nurse Midwife')",
            accessed_utc=accessed_utc,
            source_dataset="Florida DOH Division of Medical Quality Assurance, "
                            "License Verification (mqa-internet.doh.state.fl.us)",
            cohort=roster_file,
            cohort_sha256=sha256_file(roster_file),
            cohort_rows_fl=len(rows),
            cohort_matched_rows=len(matched),
            match_method="last_name + first_name search under the APRN profession code; "
                          "Florida has no separate CNM profession category, so a match is "
                          "accepted only when the license's own Qualifications field lists "
                          "'Certified Nurse Midwife' -- an APRN name match that is NOT so "
                          "qualified is reported NOT_CNM_QUALIFIED, not counted as a midwife; "
                          "more than one CNM-qualified candidate sharing a name is AMBIGUOUS",
            verification_portal=SEARCH_URL,
        )
        print(f"  Provenance: {out_csv}.provenance.json")

    n_total = len(matched) + len(unmatched)
    n_not_cnm = sum(1 for u in unmatched if u["live_bon_match_status"] == "NOT_CNM_QUALIFIED")
    n_ambiguous = sum(1 for u in unmatched if u["live_bon_match_status"] == "AMBIGUOUS")
    print("=========================================================================")
    print("  LIVE FL BON (APRN) CROSS-REFERENCE COMPLETE (tracked-roster cohort)")
    print(f"  Total FL-state rows in tracked roster    : {n_total:,}")
    if n_total:
        print(f"  Verified CNM-qualified matches            : {len(matched):,} ({len(matched)/n_total*100:.1f}%)")
        print(f"  APRN name match but NOT CNM-qualified     : {n_not_cnm:,}")
        print(f"  Ambiguous (multiple CNM-qualified matches): {n_ambiguous:,}")
    print(f"  Written to: {out_csv}")
    print("=========================================================================")


if __name__ == "__main__":
    main()
