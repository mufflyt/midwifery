#!/usr/bin/env python3
# =============================================================================
# Direct State Board of Nursing (BON) License Verification URL Generator
# =============================================================================
# Constructs direct, 1-click state license verification permalinks for every
# scraped Certified Nurse-Midwife across all 20 State Boards of Nursing.
# =============================================================================
import csv
import urllib.parse

print("=== Generating Direct State Board of Nursing (BON) Profile Permalinks ===")

v4_file = "artifacts/scraped_20_state_bons_midwives_master.csv"

# State BON Direct Permalink Base URLs
bon_url_templates = {
    "WA": "https://fortress.wa.gov/doh/providercred/CredentialDetail.aspx?credential={lic}",
    "FL": "https://mqa-internet.doh.state.fl.us/MQASearchServices/HealthcareProviders/LicenseVerification?LicInd={lic}",
    "TX": "https://www.bon.texas.gov/texasbon/Verification/Search.aspx?lic={lic}",
    "NY": "http://www.op.nysed.gov/opsearches.htm?lic={lic}",
    "NC": "https://www.ncbon.com/verify-license?lic={lic}",
    "VA": "https://dhp.virginiainteractive.org/Lookup/Detail/{lic}",
    "OH": "https://elicense.ohio.gov/OH_VerifyLicense?id={lic}",
    "IN": "https://mylicense.in.gov/Everification/Details.aspx?lic={lic}",
    "MA": "https://checkalicense.hhs.state.ma.us/Verification/Details.aspx?lic={lic}",
    "OR": "https://osbn.oregon.gov/OSBNLicenseVerification/LicenseDetail.aspx?lic={lic}",
    "AZ": "https://www.azbn.gov/verification/details?lic={lic}",
    "CO": "https://apps.colorado.gov/dora/licensing/lookup/licenselookup.aspx?lic={lic}",
    "MT": "https://ebiz.mt.gov/pol/LicenseDetail.aspx?lic={lic}",
    "GA": "https://gbn.georgia.gov/verify-license?lic={lic}",
    "TN": "https://apps.health.tn.gov/Licensure/Details.aspx?lic={lic}",
    "MD": "https://mbon.maryland.gov/Pages/license-verification.aspx?lic={lic}",
    "CA": "https://search.dca.ca.gov/details/{lic}",
    "IL": "https://idfpr.illinois.gov/LicenseLookup/Details.aspx?lic={lic}",
    "MI": "https://www.michigan.gov/lara/verification?lic={lic}",
    "PA": "https://www.pals.pa.gov/verify?lic={lic}"
}

updated_records = []
with open(v4_file, "r", encoding="utf-8", errors="ignore") as f:
    reader = csv.DictReader(f)
    fieldnames = list(reader.fieldnames) + ["bon_direct_profile_url"]
    
    for r in reader:
        st = r.get("scraped_bon_state", r.get("nppes_state", "")).upper().strip()
        lic = r.get("scraped_license_num", r.get("certification_number", "")).strip()
        lic_clean = urllib.parse.quote(lic)
        
        if st in bon_url_templates:
            r["bon_direct_profile_url"] = bon_url_templates[st].format(lic=lic_clean)
        else:
            r["bon_direct_profile_url"] = f"https://www.nursys.com/LVC/LVCVerification.aspx?npi={r.get('npi', '')}"
            
        updated_records.append(r)

out_csv = "artifacts/scraped_20_state_bons_with_direct_urls.csv"
with open(out_csv, "w", encoding="utf-8", newline="") as f:
    writer = csv.DictWriter(f, fieldnames=fieldnames)
    writer.writeheader()
    writer.writerows(updated_records)

# Case Study Check for Elisabeth Thumm
thumm_url = [r.get("bon_direct_profile_url") for r in updated_records if r.get("npi") == "1306048970"]

print(f"\n=========================================================================")
print(f"  DIRECT STATE BON PROFILE URL GENERATION COMPLETE")
print(f"  Total Midwives Updated with Direct BON URLs : {len(updated_records):,}")
if thumm_url:
    print(f"  CNM Elisabeth Thumm Direct DORA URL        : {thumm_url[0]}")
print(f"  Written to: {out_csv}")
print(f"=========================================================================")
