#!/usr/bin/env python3
# =============================================================================
# Combine Tier 1 and Tier 2 Ingested Datasets into Master Roster
# =============================================================================
import csv

t1_file = "artifacts/tier1_live_bon_all_states_complete.csv"
t2_file = "artifacts/tier2_live_bon_all_states_complete.csv"
out_file = "artifacts/tier1_tier2_combined_bon_validated_master.csv"

t1_records = []
with open(t1_file, "r", encoding="utf-8") as f:
    reader = csv.DictReader(f)
    for r in reader:
        t1_records.append(r)

t2_records = []
with open(t2_file, "r", encoding="utf-8") as f:
    reader = csv.DictReader(f)
    for r in reader:
        t2_records.append(r)

# Unify keys across all records
all_keys = set()
for r in t1_records + t2_records:
    all_keys.update(r.keys())

fieldnames = list(all_keys)

with open(out_file, "w", encoding="utf-8", newline="") as f:
    writer = csv.DictWriter(f, fieldnames=fieldnames)
    writer.writeheader()
    writer.writerows(t1_records + t2_records)

print(f"=== Combined Tier 1 ({len(t1_records):,}) + Tier 2 ({len(t2_records):,}) = {len(t1_records) + len(t2_records):,} Verified Midwives ===")
print(f"Master file written to: {out_file}")
