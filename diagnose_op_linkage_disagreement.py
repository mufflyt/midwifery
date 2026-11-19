#!/usr/bin/env python3
# =============================================================================
# D5 diagnosis: why do the two Open Payments employer-linkage implementations
# disagree on 83.6% of overlapping midwives?
# =============================================================================
# A (Python): cohort_midwives_open_payments_type2_organizations_full.csv
#   joins the Open Payments RECIPIENT address to a Type-2 (organization) NPI.
# B (R):      midwife_org_affiliations_candidate.csv
#   joins NPPES primary + secondary PRACTICE LOCATIONS to Type-2 NPIs on
#   telephone / zip9+street / zip5+street keys, with an ambiguity rule.
#
# The two read DIFFERENT ADDRESS SOURCES. A disagreement therefore has two
# possible causes, which this script separates:
#   input-driven    -- the addresses being linked are different locations, so
#                      two correct linkers can legitimately name different orgs
#   implementation  -- the same location maps to different orgs (or B found
#                      none where A found one at the same address)
# =============================================================================

import csv
from address_keys import norm

A_FILE = "artifacts/cohort_midwives_open_payments_type2_organizations_full.csv"
B_FILE = "artifacts/midwife_org_affiliations_candidate.csv"
GEO_FILE = "artifacts/amcb_npi_geography.csv"
OUT = "artifacts/op_linkage_disagreement_diagnosis.csv"


def load(path):
    with open(path, encoding="utf-8", errors="ignore") as f:
        return list(csv.DictReader(f))


a_rows = load(A_FILE)
b_rows = load(B_FILE)
geo = {r["npi"].strip(): r for r in load(GEO_FILE)}

# B keeps ALL resolver candidates: several rows per midwife is normal.
b_by_npi = {}
for r in b_rows:
    b_by_npi.setdefault(r["npi"].strip(), []).append(r)

overlap = [r for r in a_rows if r["midwife_npi"].strip() in b_by_npi]
agree, disagree = [], []
for r in overlap:
    npi = r["midwife_npi"].strip()
    a_org = r["type2_organization_npi"].strip()
    b_orgs = {b["type2_npi"].strip() for b in b_by_npi[npi]}
    (agree if a_org in b_orgs else disagree).append(r)

# Decompose disagreements: does the address A linked even exist among the
# NPPES practice locations B started from?
def geo_keys(npi):
    g = geo.get(npi, {})
    return {
        norm(g.get("practice_address_1", "")),
        norm(g.get("practice_address_2", "")),
    } - {""}

rows = []
n_same_addr = 0
for r in disagree:
    npi = r["midwife_npi"].strip()
    op_addr_norm = norm(r.get("open_payments_address", ""))
    same_addr = op_addr_norm in geo_keys(npi)
    n_same_addr += same_addr
    b = b_by_npi[npi]
    rows.append({
        "npi": npi,
        "a_type2_npi": r["type2_organization_npi"].strip(),
        "a_org_name": r.get("type2_organization_name", ""),
        "a_op_address": r.get("open_payments_address", ""),
        "op_addr_is_nppes_practice_addr": same_addr,
        "b_type2_npis": ";".join(sorted({x["type2_npi"].strip() for x in b})),
        "b_org_names": ";".join(sorted({x["organization_name"] for x in b})),
        "b_evidence_keys": ";".join(sorted({x["evidence_key"] for x in b})),
        "b_resolution_methods": ";".join(sorted({x["resolution_method"] for x in b})),
        "n_b_candidates": len(b),
    })

with open(OUT, "w", newline="", encoding="utf-8") as f:
    w = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
    w.writeheader()
    w.writerows(rows)

n = len(overlap)
print(f"A (type2 full) matches:              {len(a_rows):,}")
print(f"B resolver candidates (midwives):    {len(b_by_npi):,}")
print(f"Overlap (both name an org):          {n:,}")
print(f"Agree on Type-2 NPI:                 {len(agree):,} ({len(agree)/n*100:.1f}%)")
print(f"Disagree:                            {len(disagree):,} ({len(disagree)/n*100:.1f}%)")
print(f"  of which OP addr == an NPPES practice addr: {n_same_addr} "
      f"({n_same_addr/max(len(disagree),1)*100:.1f}% of disagreements)")
print(f"  of which OP addr NOT in NPPES locations:    {len(disagree)-n_same_addr}")
print(f"wrote {OUT}")
