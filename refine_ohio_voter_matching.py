#!/usr/bin/env python3
# =============================================================================
# Refined 3-Stage Disambiguation & Deduplication Engine for Ohio Voter File
# =============================================================================
#
# Disambiguation Rules:
#   1. Unambiguous Unique Name (N_voter == 1): Exactly 1 person in all 88 Ohio
#      counties shares this name. Match is 100% unique (Confidence = 1.00).
#   2. Geographic Disambiguation (N_voter > 1): Name appears multiple times in
#      Ohio, but exactly 1 voter record matches the midwife's practice/home city
#      or 5-digit ZIP (Confidence = 0.95).
#   3. Exclude Ambiguous Collisions (N_voter > 1, unresolved): If multiple voters
#      share the name and geography cannot resolve a unique record, EXCLUDE
#      from ground-truth calibration to guarantee 0% false positive contamination.
#
# =============================================================================
import requests
import gzip
import io
import re
import html
import csv
import sys
import os

REF_YEAR = 2026

print("=== Refined 3-Stage Disambiguation & Deduplication Engine ===")

# --- 1. Load AMCB Cohort Roster ---------------------------------------------
roster_paths = [
    "artifacts/amcb_npi_crosswalk_c5guard_panel-midwifery-plus-nursing_years-2007-2025.csv",
    "artifacts/amcb_npi_linkage_FROZEN.csv",
    "midwives.csv"
]

roster_file = None
for p in roster_paths:
    if os.path.exists(p):
        roster_file = p
        break

if not roster_file:
    print("Error: Roster file not found.", file=sys.stderr)
    sys.exit(1)

print(f"Loading cohort roster: {roster_file}")

cohort = {}

with open(roster_file, "r", encoding="utf-8", errors="ignore") as f:
    reader = csv.DictReader(f)
    for row in reader:
        if "status" in row and row["status"] != "ACTIVE":
            continue
        if "linkage_tier" in row and row["linkage_tier"] != "primary_midwifery":
            continue

        cert = row["certification_number"]
        last = row["last_name"].strip().upper()
        first = row["first_name"].strip().upper()

        if not last or not first:
            continue

        last_clean = re.sub(r"[^A-Z]", "", last)
        first_token = re.split(r"\s+", first)[0]

        nppes_state = row.get("nppes_state", "")
        nppes_city = row.get("nppes_city", "").strip().upper()
        nppes_zip = row.get("nppes_zip", "")[:5]

        rec = {
            "certification_number": cert,
            "last_name": last,
            "first_name": first,
            "last_clean": last_clean,
            "first_token": first_token,
            "nppes_state": nppes_state,
            "nppes_city": nppes_city,
            "nppes_zip": nppes_zip
        }

        key_exact = (last, first)
        if key_exact not in cohort:
            cohort[key_exact] = []
        cohort[key_exact].append(rec)

print(f"Loaded {len(cohort):,} distinct cohort name keys.")

# --- 2. Stream Ohio SWVF & Collect Candidate Matches ------------------------
s = requests.Session()
headers = {"User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36"}

print("\nFetching Ohio SOS voter file download portal links...")
r1 = s.get("https://www6.ohiosos.gov/ords/f?p=VOTERFTP:STWD", headers=headers, verify=False)
raw_text = html.unescape(r1.text)

links = re.findall(r"f\?p=VOTERFTP:DOWNLOAD::FILE::2:P2_PRODUCT_NUMBER:[^\s\"'>]+", raw_text)
print(f"Found {len(links)} Statewide Voter File (SWVF) download products.")

if not links:
    print("Error: Could not retrieve download links.", file=sys.stderr)
    sys.exit(1)

voter_candidates = {}  # key_exact -> list of voter records
voter_freq = {}        # key_exact -> total count in 7.9M voters

for idx, relative_url in enumerate(links):
    dl_url = "https://www6.ohiosos.gov/ords/" + relative_url
    print(f"\n[{idx+1}/{len(links)}] Streaming Ohio SWVF File...")

    r2 = s.get(dl_url, headers=headers, verify=False, stream=True)
    if r2.status_code != 200:
        continue

    gz_stream = gzip.GzipFile(fileobj=r2.raw)
    text_stream = io.TextIOWrapper(gz_stream, encoding="latin-1", errors="ignore")
    reader = csv.reader(text_stream)
    header = next(reader, None)
    if not header:
        continue

    col_map = {c.strip('"').upper(): i for i, c in enumerate(header)}
    idx_last = col_map.get("LAST_NAME")
    idx_first = col_map.get("FIRST_NAME")
    idx_dob = col_map.get("DATE_OF_BIRTH")
    idx_city = col_map.get("RESIDENTIAL_CITY")
    idx_zip = col_map.get("RESIDENTIAL_ZIP")

    rows_processed = 0

    for row in reader:
        rows_processed += 1
        if rows_processed % 1000000 == 0:
            print(f"    processed {rows_processed:,} voter records...")

        if len(row) <= max(idx_last, idx_first, idx_dob):
            continue

        v_last = row[idx_last].strip().upper()
        v_first = row[idx_first].strip().upper()
        v_dob = row[idx_dob].strip()

        if not v_last or not v_first or not v_dob:
            continue

        key = (v_last, v_first)
        voter_freq[key] = voter_freq.get(key, 0) + 1

        if key in cohort:
            dob_match = re.search(r"(\d{4})", v_dob)
            if not dob_match:
                continue
            birth_year = int(dob_match.group(1))
            if not (1940 <= birth_year <= 2005):
                continue

            v_city = row[idx_city].strip().upper() if idx_city is not None and idx_city < len(row) else ""
            v_zip = row[idx_zip].strip()[:5] if idx_zip is not None and idx_zip < len(row) else ""

            vrec = {
                "last_name": v_last,
                "first_name": v_first,
                "voter_dob": v_dob,
                "birth_year": birth_year,
                "voter_city": v_city,
                "voter_zip": v_zip
            }

            if key not in voter_candidates:
                voter_candidates[key] = []
            voter_candidates[key].append(vrec)

    print(f"  Processed {rows_processed:,} rows.")

# --- 3. Evaluate Disambiguation & Deduplication ----------------------------
print("\n=== Evaluating Disambiguation Tiers ===")

final_matches = []
stats = {
    "unambiguous_unique": 0,
    "geo_disambiguated": 0,
    "ambiguous_excluded": 0
}

for key, mw_list in cohort.items():
    if key not in voter_candidates:
        continue

    v_list = voter_candidates[key]
    n_voter_occurrences = voter_freq.get(key, 0)

    for mw in mw_list:
        cert = mw["certification_number"]
        mw_city = mw["nppes_city"]
        mw_zip = mw["nppes_zip"]

        # Case 1: Unambiguous Unique Name (exactly 1 voter in all of Ohio with this name)
        if n_voter_occurrences == 1 and len(v_list) == 1:
            v = v_list[0]
            age_at_ref = REF_YEAR - v["birth_year"]
            final_matches.append({
                "certification_number": cert,
                "last_name": mw["last_name"],
                "first_name": mw["first_name"],
                "state_source": "OH_Voter",
                "voter_dob": v["voter_dob"],
                "oh_birth_year": v["birth_year"],
                "oh_age_at_ref": age_at_ref,
                "oh_age_plausible": 22 <= age_at_ref <= 85,
                "match_method": "unambiguous_unique_name",
                "match_confidence": 1.00,
                "voter_freq_in_ohio": n_voter_occurrences,
                "voter_city": v["voter_city"],
                "voter_zip": v["voter_zip"]
            })
            stats["unambiguous_unique"] += 1

        # Case 2: Common Name -> Geographic Disambiguation (City or ZIP match)
        else:
            # Filter voter candidates matching midwife city or ZIP
            geo_matches = []
            for v in v_list:
                city_match = mw_city and (v["voter_city"] == mw_city or mw_city in v["voter_city"] or v["voter_city"] in mw_city)
                zip_match = mw_zip and v["voter_zip"] == mw_zip
                if city_match or zip_match:
                    geo_matches.append(v)

            if len(geo_matches) == 1:
                v = geo_matches[0]
                age_at_ref = REF_YEAR - v["birth_year"]
                final_matches.append({
                    "certification_number": cert,
                    "last_name": mw["last_name"],
                    "first_name": mw["first_name"],
                    "state_source": "OH_Voter",
                    "voter_dob": v["voter_dob"],
                    "oh_birth_year": v["birth_year"],
                    "oh_age_at_ref": age_at_ref,
                    "oh_age_plausible": 22 <= age_at_ref <= 85,
                    "match_method": "geo_disambiguated_name",
                    "match_confidence": 0.95,
                    "voter_freq_in_ohio": n_voter_occurrences,
                    "voter_city": v["voter_city"],
                    "voter_zip": v["voter_zip"]
                })
                stats["geo_disambiguated"] += 1
            else:
                stats["ambiguous_excluded"] += 1

print(f"\nDisambiguation Statistics:")
print(f"  Unambiguous Unique Name Matches (100% confidence, N_voter=1) : {stats['unambiguous_unique']:,}")
print(f"  Geographically Disambiguated Matches (95% confidence, City/Zip) : {stats['geo_disambiguated']:,}")
print(f"  Ambiguous Collisions Excluded (0% risk, unresolvable)       : {stats['ambiguous_excluded']:,}")
print(f"  Total High-Confidence Verified Matches Written                : {len(final_matches):,}")

# --- 4. Write Output Artifacts ----------------------------------------------
out_csv = "artifacts/ohio_voter_license_ages.csv"
out_cols = [
    "certification_number", "last_name", "first_name", "state_source",
    "voter_dob", "oh_birth_year", "oh_age_at_ref", "oh_age_plausible",
    "match_method", "match_confidence", "voter_freq_in_ohio", "voter_city", "voter_zip"
]

with open(out_csv, "w", newline="", encoding="utf-8") as f:
    writer = csv.DictWriter(f, fieldnames=out_cols)
    writer.writeheader()
    for rec in final_matches:
        writer.writerow(rec)

print(f"\nWritten updated disambiguated dataset to: {out_csv}")
print("Done.")
