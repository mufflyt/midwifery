#!/usr/bin/env python3
# =============================================================================
# Profile Spotlight: Elisabeth Brie Thumm, CNM
# =============================================================================
import csv
import json

v4_file = "artifacts/scraped_20_state_bons_midwives_master.csv"
thumm_record = None

with open(v4_file, "r", encoding="utf-8", errors="ignore") as f:
    reader = csv.DictReader(f)
    for r in reader:
        if r.get("npi") == "1306048970" or "THUMM" in r.get("last_name", "").upper():
            thumm_record = r
            break

out_json = "artifacts/elisabeth_thumm_profile_spotlight.json"
if thumm_record:
    with open(out_json, "w", encoding="utf-8") as f:
        json.dump(thumm_record, f, indent=2)
    print(f"Successfully written spotlight profile for CNM Elisabeth Thumm to: {out_json}")
