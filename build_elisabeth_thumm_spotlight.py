#!/usr/bin/env python3
# =============================================================================
# Profile Spotlight: Elisabeth Brie Thumm, CNM (AMCB 10542, NPI 1306048970)
# =============================================================================
# Every field is copied from an observed source; nothing is typed in by hand.
# An earlier version read artifacts/scraped_20_state_bons_midwives_master.csv,
# whose license fields were synthesized from certification_number
# ("CO-RN-APRN-10542", "Active Verified (BON Direct Scrape)") -- see
# docs/PROVENANCE_DEFECT_BON_LICENSE_IDENTIFIERS.md. A companion script,
# add_elisabeth_thumm_to_cohort.py, hand-wrote a whole record for her
# (invented certification and license numbers, a hard-coded delivery-claim
# flag) and has been deleted.
#
# Inputs (all required; the script stops rather than fill a gap):
#   artifacts/amcb_npi_linkage_FROZEN.csv                           AMCB roster + NPPES link
#   artifacts/live_colorado_bon_ingested_midwives_from_tracked_roster.csv
#       Colorado DORA open data, data.colorado.gov/resource/7s5z-vewr (APN, subcategory CNM)
#   artifacts/cohort_midwife_hospital_rigorous_attributions.csv     hospital attribution
# Output:
#   artifacts/elisabeth_thumm_profile_spotlight.json
# =============================================================================
import csv
import json
import os
import sys

NPI = "1306048970"
CERT = "10542"
ART = "artifacts"
SRC = {
    "linkage": os.path.join(ART, "amcb_npi_linkage_FROZEN.csv"),
    "co_bon": os.path.join(ART, "live_colorado_bon_ingested_midwives_from_tracked_roster.csv"),
    "hospital": os.path.join(ART, "cohort_midwife_hospital_rigorous_attributions.csv"),
}
OUT = os.path.join(ART, "elisabeth_thumm_profile_spotlight.json")

missing = [p for p in SRC.values() if not os.path.exists(p)]
if missing:
    sys.exit("Refusing to build the spotlight from a partial source set; missing: "
             + ", ".join(missing))


def rows(path):
    with open(path, newline="", encoding="utf-8") as f:
        yield from csv.DictReader(f)


def one(path, key, value):
    hits = [r for r in rows(path) if r.get(key) == value]
    if len(hits) > 1:
        sys.exit(f"{path}: {len(hits)} rows for {key}={value}; expected at most one")
    return hits[0] if hits else None


link = one(SRC["linkage"], "certification_number", CERT)
if link is None or link.get("npi") != NPI:
    sys.exit(f"FROZEN linkage has no row linking certification {CERT} to NPI {NPI}")
profile = dict(link)

co = one(SRC["co_bon"], "certification_number", CERT)
profile.update({
    "co_bon_license_number": co["live_bon_credential_num"] if co else "",
    "co_bon_license_status": co["live_bon_status"] if co else "",
    "co_bon_license_expiration": (co["live_bon_exp_date"] or "")[:10] if co else "",
    "co_bon_match_status": co["live_bon_match_status"] if co else "not found in Colorado DORA APN/CNM file",
    "co_bon_source": "data.colorado.gov/resource/7s5z-vewr (Colorado DORA, licensetype=APN, subcategory=CNM)",
})

# No delivery-claim field. The file this read,
# artifacts/cohort_midwives_cpt_delivery_attenders.csv, listed NPIs whose DAC
# primary specialty is CNM and called them delivery attenders; public Part B
# has no delivery-code rows for any provider
# (artifacts/medicare_delivery_code_observability.csv).

hosp = one(SRC["hospital"], "npi", NPI) or {}
for k in ("attribution_tier", "attributed_hospital_name", "cms_ccn"):
    profile[k] = hosp.get(k, "")

with open(OUT, "w", encoding="utf-8") as f:
    json.dump(profile, f, indent=2)
    f.write("\n")
print(f"wrote {OUT}")
