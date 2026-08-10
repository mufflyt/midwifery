#!/usr/bin/env python3
# =============================================================================
# Stream & Match Ohio Statewide Voter Database (SWVF) for Provider DOBs
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

print("=== Ohio Statewide Voter Database (SWVF) DOB Extractor & Matcher ===")

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
cohort_token = {}

with open(roster_file, "r", encoding="utf-8", errors="ignore") as f:
    reader = csv.DictReader(f)
    for row in reader:
        # Filter active primary if columns exist
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

        # Index by exact name
        key_exact = (last, first)
        if key_exact not in cohort:
            cohort[key_exact] = []
        cohort[key_exact].append(rec)

        # Index by token name
        key_token = (last_clean, first_token)
        if key_token not in cohort_token:
            cohort_token[key_token] = []
        cohort_token[key_token].append(rec)

print(f"Loaded {len(cohort)} distinct exact name keys across national cohort.")

# --- 2. Get Ohio SOS Download Links -----------------------------------------
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

# --- 3. Stream & Process Each Product File ----------------------------------
matched_records = {}

for idx, relative_url in enumerate(links):
    dl_url = "https://www6.ohiosos.gov/ords/" + relative_url
    print(f"\n[{idx+1}/{len(links)}] Streaming Ohio SWVF File...")
    print(f"  URL: {dl_url}")

    r2 = s.get(dl_url, headers=headers, verify=False, stream=True)
    if r2.status_code != 200:
        print(f"  Error fetching file (Status Code: {r2.status_code})")
        continue

    content_disp = r2.headers.get("Content-Disposition", "")
    print(f"  Filename: {content_disp}")

    # Stream & decompress gzip in memory line-by-line
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

    if idx_last is None or idx_first is None or idx_dob is None:
        print("  Error: Required columns not found in file header.")
        continue

    rows_processed = 0
    file_matches = 0

    for row in reader:
        rows_processed += 1
        if rows_processed % 500000 == 0:
            print(f"    processed {rows_processed:,} voter records (matched {len(matched_records):,} certificants)...")

        if len(row) <= max(idx_last, idx_first, idx_dob):
            continue

        v_last = row[idx_last].strip().upper()
        v_first = row[idx_first].strip().upper()
        v_dob = row[idx_dob].strip()

        if not v_last or not v_first or not v_dob:
            continue

        # Extract birth year (YYYY-MM-DD or YYYY/MM/DD)
        dob_match = re.search(r"(\d{4})", v_dob)
        if not dob_match:
            continue

        birth_year = int(dob_match.group(1))
        if birth_year < 1940 or birth_year > 2005:
            continue

        v_last_clean = re.sub(r"[^A-Z]", "", v_last)
        v_first_token = re.split(r"\s+", v_first)[0]
        v_city = row[idx_city].strip().upper() if idx_city is not None and idx_city < len(row) else ""
        v_zip = row[idx_zip].strip()[:5] if idx_zip is not None and idx_zip < len(row) else ""

        # Try exact match first
        matches = cohort.get((v_last, v_first))
        match_tier = "exact_name"
        confidence = 1.00

        # Try token match if exact not found
        if not matches:
            matches = cohort_token.get((v_last_clean, v_first_token))
            match_tier = "token_name"
            confidence = 0.90

        if matches:
            for m in matches:
                cert = m["certification_number"]
                if cert in matched_records:
                    continue  # already matched

                age_at_ref = REF_YEAR - birth_year
                matched_records[cert] = {
                    "certification_number": cert,
                    "last_name": m["last_name"],
                    "first_name": m["first_name"],
                    "state_source": "OH_Voter",
                    "voter_dob": v_dob,
                    "oh_birth_year": birth_year,
                    "oh_age_at_ref": age_at_ref,
                    "oh_age_plausible": 22 <= age_at_ref <= 85,
                    "match_method": match_tier,
                    "match_confidence": confidence,
                    "voter_city": v_city,
                    "voter_zip": v_zip
                }
                file_matches += 1

    print(f"  Processed {rows_processed:,} voter records | Matched {file_matches:,} certificants.")

# --- 4. Write Output Artifacts ----------------------------------------------
os.makedirs("artifacts", exist_ok=True)
out_csv = "artifacts/ohio_voter_license_ages.csv"

out_cols = [
    "certification_number", "last_name", "first_name", "state_source",
    "voter_dob", "oh_birth_year", "oh_age_at_ref", "oh_age_plausible",
    "match_method", "match_confidence", "voter_city", "voter_zip"
]

with open(out_csv, "w", newline="", encoding="utf-8") as f:
    writer = csv.DictWriter(f, fieldnames=out_cols)
    writer.writeheader()
    for rec in matched_records.values():
        writer.writerow(rec)

print(f"\nWritten {len(matched_records):,} matched certificant DOB records to: {out_csv}")
print("Done.")
