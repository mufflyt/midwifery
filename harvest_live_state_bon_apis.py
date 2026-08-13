#!/usr/bin/env python3
# =============================================================================
# Live State Board of Nursing (BON) Open Data API Harvester
# =============================================================================
# Streams live active CNM licensure data from official State Open Data APIs
# (e.g. Washington DOH Socrata API `qxh8-f4bd`).
# =============================================================================
import csv
import json
import urllib.request

print("=== Streaming Live State Board of Nursing (BON) API Data ===")

# 1. Fetch Live Washington State Midwife Credentials via Socrata API
wa_url = "https://data.wa.gov/resource/qxh8-f4bd.json?$where=credentialtype%20like%20%27%25Midwife%25%27&$limit=5000"
req = urllib.request.Request(wa_url, headers={"User-Agent": "Mozilla/5.0"})

live_wa_records = []
try:
    with urllib.request.urlopen(req, timeout=15) as response:
        live_wa_records = json.loads(response.read().decode("utf-8"))
    print(f"Successfully streamed {len(live_wa_records):,} live WA State midwife license records.")
except Exception as e:
    print(f"Error fetching live WA BON data: {e}")

# Index live WA records by Last_First name
wa_lookup = {}
for r in live_wa_records:
    fn = r.get("firstname", "").upper().strip()
    ln = r.get("lastname", "").upper().strip()
    if fn and ln:
        wa_lookup[f"{ln}_{fn}"] = r

# 2. Cross-Reference against National Cohort
v4_file = "artifacts/cohort_midwife_facility_attributions_final_v4.csv"
matched_wa = []
unmatched_wa = []

with open(v4_file, "r", encoding="utf-8", errors="ignore") as f:
    reader = csv.DictReader(f)
    for r in reader:
        st = r.get("nppes_state", r.get("state", "")).upper().strip()
        if st == "WA":
            fn = r.get("first_name", "").upper().strip()
            ln = r.get("last_name", "").upper().strip()
            key = f"{ln}_{fn}"
            
            if key in wa_lookup:
                wa_info = wa_lookup[key]
                r["live_bon_credential_num"] = wa_info.get("credentialnumber", "")
                r["live_bon_status"] = wa_info.get("status", "")
                r["live_bon_exp_date"] = wa_info.get("expirationdate", "")
                r["live_bon_match_status"] = "VERIFIED_LIVE_BON"
                matched_wa.append(r)
            else:
                r["live_bon_credential_num"] = "NA"
                r["live_bon_status"] = "UNMATCHED_BON"
                r["live_bon_exp_date"] = "NA"
                r["live_bon_match_status"] = "UNMATCHED"
                unmatched_wa.append(r)

out_csv = "artifacts/live_washington_bon_ingested_midwives.csv"
if matched_wa or unmatched_wa:
    fieldnames = list((matched_wa + unmatched_wa)[0].keys())
    with open(out_csv, "w", encoding="utf-8", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(matched_wa + unmatched_wa)

print(f"\n=========================================================================")
print(f"  LIVE WA BON MATCHING COMPLETE")
print(f"  Total WA Midwives in Cohort : {len(matched_wa) + len(unmatched_wa):,}")
print(f"  Live State BON Matched      : {len(matched_wa):,} ({len(matched_wa)/(len(matched_wa)+len(unmatched_wa))*100:.1f}%)")
print(f"  Written to: {out_csv}")
print(f"=========================================================================")
