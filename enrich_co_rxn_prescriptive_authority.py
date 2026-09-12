#!/usr/bin/env python3
# =============================================================================
# Genuine Colorado prescriptive-authority (RXN) enrichment for verified CNMs
# =============================================================================
# Colorado's DORA licenses prescriptive authority as a SEPARATE license record
# (licensetype=RXN) from the APN-CNM credential itself, so a CNM's own APN
# record cannot say whether she can prescribe. The two records are linked by a
# `contact` ID embedded in each record's linktoverifylicense.url -- confirmed
# directly: Margaret Ann Flesher's APN-CNM record (cred=1210980) and her
# separate RXN-CNM record (cred=1211339) both carry contact=1284307. This is
# Colorado's own person identifier, not a name-matching heuristic, so it
# carries none of harvest_live_co_bon_from_tracked_roster.py's AMBIGUOUS_BON
# risk for this specific join.
#
# THIS IS NOT THE FABRICATED rxn_prescriptive_authority_status FIELD FROM
# extract_detailed_bon_heterogeneity_fields.py. That field assigned "Active
# Schedule II-V Prescriptive Authority" to every record from a hardcoded list
# of 8 states, regardless of the individual -- see
# docs/PROVENANCE_DEFECT_BON_LICENSE_IDENTIFIERS.md. This queries a real,
# separate, individually-issued RXN license record per person and reports
# per-person NO_RXN_RECORD_FOUND when there is none, not a blanket "no CPA
# required" default.
#
# Depends on harvest_live_co_bon_from_tracked_roster.py having already run:
# reads its output for the set of certification_numbers already verified
# against a real APN-CNM record, then re-queries DORA for each verified
# person's contact ID and checks it against the RXN-CNM population.
# =============================================================================
import csv
import json
import re
import urllib.parse
import urllib.request

print("=== Colorado prescriptive-authority (RXN) enrichment ===")

CO_API = "https://data.colorado.gov/resource/7s5z-vewr.json"


def co_query(params):
    url = CO_API + "?" + urllib.parse.urlencode(params)
    req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
    with urllib.request.urlopen(req, timeout=30) as response:
        return json.loads(response.read().decode("utf-8"))


def contact_id(record):
    url = (record.get("linktoverifylicense") or {}).get("url", "")
    m = re.search(r"contact=(\d+)", url)
    return m.group(1) if m else None


# 1. Re-fetch APN-CNM, this time keeping the contact ID (the prior run did not
# capture it -- it wasn't needed for the WA-style name match).
apn_cnm = co_query({"licensetype": "APN", "subcategory": "CNM", "$limit": "5000"})
print(f"Re-fetched {len(apn_cnm):,} live CO APN-CNM records (for contact IDs).")
apn_by_name = {}
for r in apn_cnm:
    fn = r.get("firstname", "").upper().strip()
    ln = r.get("lastname", "").upper().strip()
    cid = contact_id(r)
    if fn and ln and cid:
        apn_by_name.setdefault(f"{ln}_{fn}", []).append(cid)

# 2. Fetch RXN-CNM, indexed by contact ID.
rxn_cnm = co_query({"licensetype": "RXN", "subcategory": "CNM", "$limit": "5000"})
print(f"Fetched {len(rxn_cnm):,} live CO RXN-CNM records.")
rxn_by_contact = {}
for r in rxn_cnm:
    cid = contact_id(r)
    if cid:
        rxn_by_contact[cid] = r

# 3. Load the already-verified cohort from the prior run.
in_csv = "artifacts/live_colorado_bon_ingested_midwives_from_tracked_roster.csv"
out_rows = []
n_rxn_found = 0
n_verified = 0

with open(in_csv, "r", encoding="utf-8", errors="ignore") as f:
    for r in csv.DictReader(f):
        out = dict(r)
        if r.get("live_bon_match_status") != "VERIFIED_LIVE_BON":
            out["rxn_status"] = "NOT_APPLICABLE_NO_APN_MATCH"
            out["rxn_license_num"] = "NA"
            out["rxn_exp_date"] = "NA"
            out_rows.append(out)
            continue

        n_verified += 1
        key = f"{r['last_name'].upper().strip()}_{r['first_name'].upper().strip()}"
        candidate_contacts = apn_by_name.get(key, [])

        matched_rxn = None
        for cid in candidate_contacts:
            if cid in rxn_by_contact:
                matched_rxn = rxn_by_contact[cid]
                break

        if matched_rxn:
            n_rxn_found += 1
            out["rxn_status"] = "VERIFIED_RXN_ON_FILE"
            out["rxn_license_num"] = matched_rxn.get("licensenumber", "")
            out["rxn_exp_date"] = matched_rxn.get("licenseexpirationdate", "")
        else:
            out["rxn_status"] = "NO_RXN_RECORD_FOUND"
            out["rxn_license_num"] = "NA"
            out["rxn_exp_date"] = "NA"
        out_rows.append(out)

out_csv = "artifacts/live_colorado_rxn_prescriptive_authority.csv"
if out_rows:
    fieldnames = list(out_rows[0].keys())
    with open(out_csv, "w", encoding="utf-8", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(out_rows)

print("=========================================================================")
print("  COLORADO RXN ENRICHMENT COMPLETE")
print(f"  Verified CNMs checked        : {n_verified:,}")
if n_verified:
    print(f"  Genuine RXN record found     : {n_rxn_found:,} ({n_rxn_found/n_verified*100:.1f}%)")
print(f"  Written to: {out_csv}")
print("=========================================================================")
