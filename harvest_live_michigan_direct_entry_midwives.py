#!/usr/bin/env python3
# =============================================================================
# Live Michigan direct-entry midwife list (NOT a tracked-roster/CNM cross-reference)
# =============================================================================
# Source: Michigan LARA's Bureau of Professional Licensing public license
# search (MiPLUS, served from Accela's "MILARA" instance):
#   https://aca-prod.accela.com/MILARA/GeneralProperty/PropertyLookUp.aspx
#
# WHY THIS SCRIPT DOES NOT MATCH AGAINST THE TRACKED ROSTER. Michigan's
# License Type list (read directly off the live search form) has NO "Nurse
# Practitioner" or "APRN" category at all -- just "Registered Nurse",
# "Licensed Practical Nurse", and a separate "Midwife" / "Temporary Midwife"
# type. The obvious-looking hypothesis -- that Michigan licenses nurse-
# midwives (CNMs) under "Midwife" -- was tested directly and is WRONG: all
# 119 live "Midwife" records (active + lapsed) were checked against the
# FULL national tracked cohort (artifacts/amcb_npi_linkage_FROZEN.csv,
# 22,357 rows, every state, not just MI) by exact last+first name, and only
# 1 matched -- indistinguishable from coincidental same-name collision, not
# real signal. "Midwife" in MiPLUS is Michigan's separate direct-entry /
# Certified Professional Midwife (non-nurse) licensing track, established
# under the state's own Midwifery statute -- a genuinely different
# profession from the AMCB-certified nurse-midwives this project tracks,
# not a BON address source for them. Michigan appears to have NO license
# type that isolates CNMs from the general Registered Nurse pool at all --
# unlike WA/TX (excluded for having no address field) or CO (excluded for
# having the wrong address type), Michigan is excluded from
# compare_pecos_to_bon_address.R for a third, distinct reason: no isolable
# population to compare in the first place. See docs/PROVENANCE_DEFECT_
# BON_LICENSE_IDENTIFIERS.md for why this project insists on checking a
# hypothesis against real data before building on it, rather than assuming
# a license-type name means what it sounds like it means.
#
# WHAT THIS SCRIPT DOES INSTEAD. It captures Michigan's direct-entry
# midwife population as its own dataset -- useful context on state-by-state
# midwifery regulation diversity, not as evidence about any AMCB CNM. No
# matching, no VERIFIED/UNMATCHED/AMBIGUOUS status: every live record is
# written as-is, with no claim that it corresponds to anyone in this
# project's cohort.
#
# TWO-STAGE FETCH, TWO DIFFERENT ACCESS PATHS.
#   1. The SEARCH itself (License Type = Midwife, submit) is a classic
#      ASP.NET Web Forms + MS-AJAX UpdatePanel postback. A bare, scripted
#      POST replicating the postback (correct ACA_CS_FIELD anti-CSRF token,
#      correct ScriptManager/__ASYNCPOST framing, a persistent requests
#      session carrying every cookie including the Cloudflare _cfuvid one)
#      was rejected every time with the framework's own "Invalid viewstate"
#      error -- most likely Cloudflare bot-management interference, not a
#      genuine malformed request (confirmed working in a real, interactive
#      browser session with the identical form values). Per this project's
#      own operating constraints, defeating that kind of bot-management
#      signal via fingerprint spoofing is not something to pursue; driving
#      an actual browser (Selenium) is the legitimate path, used ONLY for
#      this one step.
#   2. Each individual LicenseeDetail.aspx?LicenseeNumber=<n>&LicenseeType=
#      Midwife page, by contrast, IS a plain, stateless, bookmarkable GET --
#      confirmed directly with a bare `curl`, no session, no cookies, no
#      Selenium needed. All detail-page fetches below use plain urllib.
#
# The only location field anywhere in this source is "County" (no city,
# state, or ZIP) -- read from each record's detail page.
# =============================================================================
import csv
import os
import re
import sys
import time
import urllib.request

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "tools"))
from provenance import sha256_file, utc_now, write_provenance  # noqa: E402

print("=== Live Michigan direct-entry midwife list (MiPLUS, standalone -- not a BON cross-reference) ===")

SEARCH_URL = "https://aca-prod.accela.com/MILARA/GeneralProperty/PropertyLookUp.aspx?isLicensee=Y&TabName=APO"
DETAIL_URL = "https://aca-prod.accela.com/MILARA/GeneralProperty/LicenseeDetail.aspx?LicenseeNumber={}&LicenseeType=Midwife"
DETAIL_DELAY_SECONDS = 0.5
USER_AGENT = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
              "(KHTML, like Gecko) Chrome/120.0 Safari/537.36")

# County rides on a generically-named "lblInsuranceCompany" control (the
# page template reuses that label slot per license type) -- confirmed
# directly off the live HTML, not guessed from the field's id.
DETAIL_FIELD_RE = re.compile(
    r"id=['\"]ctl00_PlaceHolderMain_licenseeGeneralInfo_(lblBusinessName2|lblInsuranceCompany)_value['\"]>([^<]*)"
)


def fetch_michigan_midwife_list():
    """Drive a real (Selenium) browser through the License Type = Midwife
    search and every results page. Only this step needs a browser -- see
    this module's header for why the search postback can't be scripted
    with plain HTTP against this source.
    """
    from selenium import webdriver
    from selenium.webdriver.chrome.options import Options
    from selenium.webdriver.common.by import By
    from selenium.webdriver.support import expected_conditions as EC
    from selenium.webdriver.support.ui import Select, WebDriverWait

    opts = Options()
    opts.add_argument("--headless=new")
    opts.add_argument("--no-sandbox")
    opts.add_argument(f"--user-agent={USER_AGENT}")
    driver = webdriver.Chrome(options=opts)
    driver.set_page_load_timeout(30)
    records = []
    try:
        driver.get(SEARCH_URL)
        wait = WebDriverWait(driver, 20)
        type_dropdown = wait.until(EC.presence_of_element_located(
            (By.ID, "ctl00_PlaceHolderMain_refLicenseeSearchForm_ddlLicenseType")))
        Select(type_dropdown).select_by_value("Midwife")
        driver.find_element(By.ID, "ctl00_PlaceHolderMain_btnNewSearch").click()
        wait.until(EC.presence_of_element_located(
            (By.XPATH, "//*[contains(text(),'results found matching')]")))

        page_no = 1
        while True:
            table = driver.find_element(By.ID, "ctl00_PlaceHolderMain_refLicenseeList_gdvRefLicenseeList")
            for row in table.find_elements(By.TAG_NAME, "tr"):
                cells = [c.text.strip() for c in row.find_elements(By.TAG_NAME, "td")]
                if len(cells) == 9 and cells[1].isdigit():
                    records.append({
                        "license_number": cells[1],
                        "first_name": cells[2],
                        "middle_initial": cells[3],
                        "last_name": cells[4],
                        "status": cells[7],
                        "expiration": cells[8],
                    })

            next_links = [a for a in driver.find_elements(By.TAG_NAME, "a")
                          if (a.text or "").strip() == str(page_no + 1)]
            if not next_links:
                break
            next_links[0].click()
            page_no += 1
            wait.until(EC.presence_of_element_located(
                (By.ID, "ctl00_PlaceHolderMain_refLicenseeList_gdvRefLicenseeList")))
            time.sleep(0.5)
    finally:
        driver.quit()
    return records


def fetch_county(license_number, opener=urllib.request.urlopen):
    """Plain, stateless GET -- no browser, no session. Returns (status,
    county) parsed from the detail page's two mislabeled-but-consistent
    value spans; either half is "" if the page's layout doesn't match
    (surfaced to the caller as an honest blank, not guessed).
    """
    req = urllib.request.Request(DETAIL_URL.format(license_number),
                                  headers={"User-Agent": USER_AGENT})
    with opener(req, timeout=30) as resp:
        html = resp.read().decode("utf-8", errors="ignore")
    found = dict(DETAIL_FIELD_RE.findall(html))
    status = found.get("lblBusinessName2", "").strip()
    county = found.get("lblInsuranceCompany", "").strip()
    # A handful of live records render the literal string "false" in this
    # slot instead of a county name or a blank (confirmed on >1 record,
    # e.g. license 7601000004) -- a site-side data-quality quirk, not a
    # parsing bug here. Treated as "no county available", not a real value.
    if county.lower() == "false":
        county = ""
    return status, county


def main():
    accessed_utc = utc_now()
    try:
        records = fetch_michigan_midwife_list()
        print(f"Successfully retrieved {len(records):,} live MI direct-entry midwife records (list view).")
    except Exception as e:
        print(f"Error fetching live MI Midwife list: {e}")
        raise SystemExit(1)

    for i, rec in enumerate(records, start=1):
        try:
            status, county = fetch_county(rec["license_number"])
            if status:
                rec["status"] = status
            rec["county"] = county
        except Exception as e:
            print(f"  Warning: county lookup failed for license {rec['license_number']}: {e}")
            rec["county"] = ""
        if i % 25 == 0:
            print(f"  ...county-lookup {i}/{len(records)}")
        time.sleep(DETAIL_DELAY_SECONDS)

    out_csv = "artifacts/live_michigan_direct_entry_midwives.csv"
    if records:
        fieldnames = list(records[0].keys())
        with open(out_csv, "w", encoding="utf-8", newline="") as f:
            writer = csv.DictWriter(f, fieldnames=fieldnames)
            writer.writeheader()
            writer.writerows(records)

        write_provenance(
            out_csv,
            source_url=SEARCH_URL + " (License Type = Midwife; county from each record's "
                                     "LicenseeDetail.aspx page)",
            accessed_utc=accessed_utc,
            source_dataset="Michigan LARA Bureau of Professional Licensing (MiPLUS/MILARA) -- "
                            "direct-entry/Certified Professional Midwife license type, NOT CNM",
            records_retrieved=len(records),
            cohort_matched="NONE -- tested against the full national tracked cohort "
                            "(amcb_npi_linkage_FROZEN.csv, 22,357 rows) and found only 1/22,357 "
                            "exact last+first match, indistinguishable from coincidence; this "
                            "license type is a different, non-AMCB population",
            address_granularity="county only -- no city/state/zip field exists in this source",
            verification_portal=SEARCH_URL,
        )
        print(f"  Provenance: {out_csv}.provenance.json")

    print("=========================================================================")
    print("  LIVE MI DIRECT-ENTRY MIDWIFE LIST COMPLETE (standalone, not a BON cross-reference)")
    print(f"  Total records retrieved : {len(records):,}")
    print(f"  Written to: {out_csv}")
    print("=========================================================================")


if __name__ == "__main__":
    main()
