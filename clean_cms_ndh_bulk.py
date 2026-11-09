#!/usr/bin/env python3
# =============================================================================
# Stream-filter the CMS NDH bulk release into two cleaned CSVs
# =============================================================================
#
# WHY. download_cms_ndh_bulk.py lands two verified .zst files (06-Practitioner,
# 07-PractitionerRole) that together decompress to ~28 GB -- more than this
# project's internal disk has ever had free. This script never materializes
# that NDJSON on disk: each file is piped through `zstd -dc` directly into a
# line-by-line JSON parser, so the only things that live in memory are the
# (much smaller) set of matched rows.
#
# Reuses parse_practitioner()/parse_roles() from
# harvest_cms_national_provider_directory.py rather than re-implementing the
# FHIR-to-row flattening a second time; see that file and
# docs/TECHNICAL_APPENDIX_CMS_NDH.md s3 for what each field means.
#
# TWO OUTPUTS, deliberately not merged:
#   - artifacts/cms_ndh_bulk_cohort.csv -- this project's 16,775 cohort NPIs,
#     same schema as the per-NPI harvester's artifacts/cms_ndh_midwives.csv.
#     A faster, independent cross-check of that run, not a replacement for
#     it -- compare, do not assume agreement (same discipline as the WA BON
#     cross-reference in harvest_live_wa_bon_from_tracked_roster.py).
#   - artifacts/cms_ndh_bulk_national_cnm.csv -- EVERY practitioner in NDH
#     nationally carrying taxonomy 367A00000X ("Advanced Practice Midwife"),
#     regardless of cohort membership. This is the capability the per-NPI
#     approach structurally cannot offer: it can only confirm/enrich NPIs
#     already in the AMCB-to-NPPES linkage, never discover one the linkage
#     missed. A row appears in BOTH files when it is both.
#
# TWO PASSES over two streams, not one: PractitionerRole entries reference a
# Practitioner id, but the set of ids worth keeping roles for is only known
# after Practitioner has been fully scanned.
#
# Inputs : $CMS_NDH_BULK_ROOT/{06-Practitioner,07-PractitionerRole}.ndjson.zst
#          (from download_cms_ndh_bulk.py)
#          artifacts/amcb_npi_linkage_FROZEN.csv (cohort_member == TRUE)
# Outputs: artifacts/cms_ndh_bulk_cohort.csv (+ .provenance.json)
#          artifacts/cms_ndh_bulk_national_cnm.csv (+ .provenance.json)
#
# Usage  : CMS_NDH_BULK_ROOT=/Volumes/<volume>/midwifery/cms_ndh_bulk \
#          python3 clean_cms_ndh_bulk.py
# =============================================================================
import csv
import json
import os
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "tools"))
from download_cms_ndh_bulk import resolve_root  # noqa: E402
from harvest_cms_national_provider_directory import parse_practitioner, parse_roles  # noqa: E402
from provenance import sha256_file, utc_now, write_provenance  # noqa: E402

MIDWIFE_TAXONOMY = "367A00000X"  # NUCC "Advanced Practice Midwife" -- confirmed
# against a real cohort NPI, see docs/TECHNICAL_APPENDIX_CMS_NDH.md s2.

# The bulk export codes the SAME fields under DIFFERENT FHIR system URIs than
# the live gateway (directory.cms.gov/fhir) uses -- confirmed by inspecting
# 06-Practitioner.ndjson.zst directly after a first run matched 0 of 7.48M
# lines despite a known cohort NPI being present in the file. See
# docs/TECHNICAL_APPENDIX_CMS_NDH.md s5.
NPI_SYSTEMS = ("http://hl7.org/fhir/sid/us-npi",          # live gateway
               "http://terminology.hl7.org/NamingSystem/npi")  # bulk export
TAXONOMY_SYSTEMS = ("http://nucc.org/provider-taxonomy",   # live gateway
                     "http://hl7.org/fhir/us/ndh/ValueSet/HealthcareIndividualTaxonomyVS")  # bulk export
ROSTER_FILE = "artifacts/amcb_npi_linkage_FROZEN.csv"
COHORT_OUT = "artifacts/cms_ndh_bulk_cohort.csv"
NATIONAL_OUT = "artifacts/cms_ndh_bulk_national_cnm.csv"
PROGRESS_EVERY = 500_000


def log(msg):
    print(f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] {msg}", flush=True)


def load_cohort_npis():
    with open(ROSTER_FILE, newline="", encoding="utf-8", errors="ignore") as f:
        return {r["npi"].strip() for r in csv.DictReader(f)
                if r.get("cohort_member", "").strip().upper() == "TRUE" and r.get("npi", "").strip()}


def stream_ndjson_lines(zst_path):
    """Decompress on the fly; nothing but one line at a time ever hits memory."""
    proc = subprocess.Popen(["zstd", "-dc", zst_path], stdout=subprocess.PIPE,
                             stderr=subprocess.DEVNULL, text=True, bufsize=1)
    try:
        for line in proc.stdout:
            yield line
    finally:
        proc.stdout.close()
        proc.wait()


def extract_npi(res):
    for ident in res.get("identifier", []):
        if ident.get("system") in NPI_SYSTEMS:
            return ident.get("value", "")
    return ""


def has_midwife_taxonomy(res):
    for q in res.get("qualification", []):
        for c in (q.get("code") or {}).get("coding", []):
            if c.get("system") in TAXONOMY_SYSTEMS and c.get("code") == MIDWIFE_TAXONOMY:
                return True
    return False


def scan_practitioners(zst_path, cohort_npis):
    """Pass 1. Returns {practitioner_id: (npi, is_cohort, is_national, row)}."""
    matched = {}
    n_lines, n_errors = 0, 0
    for line in stream_ndjson_lines(zst_path):
        n_lines += 1
        if n_lines % PROGRESS_EVERY == 0:
            log(f"  practitioner pass: {n_lines:,} lines, {len(matched):,} matched so far")
        line = line.strip()
        if not line:
            continue
        try:
            res = json.loads(line)
        except json.JSONDecodeError:
            n_errors += 1
            continue

        npi = extract_npi(res)
        is_cohort = npi in cohort_npis
        is_national = has_midwife_taxonomy(res)
        if not (is_cohort or is_national):
            continue

        pid = res.get("id", "")
        row = {"npi": npi}
        row.update(parse_practitioner(res))
        matched[pid] = (npi, is_cohort, is_national, row)

    log(f"practitioner pass done: {n_lines:,} lines, {n_errors:,} json errors, "
        f"{len(matched):,} matched (cohort or national)")
    return matched


def scan_roles(zst_path, matched_ids):
    """Pass 2. Returns {practitioner_id: [role_resource, ...]}."""
    roles_by_id = {}
    n_lines, n_errors, n_kept = 0, 0, 0
    for line in stream_ndjson_lines(zst_path):
        n_lines += 1
        if n_lines % PROGRESS_EVERY == 0:
            log(f"  role pass: {n_lines:,} lines, {n_kept:,} roles kept so far")
        line = line.strip()
        if not line:
            continue
        try:
            res = json.loads(line)
        except json.JSONDecodeError:
            n_errors += 1
            continue

        ref = (res.get("practitioner") or {}).get("reference", "")
        pid = ref.split("/", 1)[-1] if "/" in ref else ref
        if pid in matched_ids:
            roles_by_id.setdefault(pid, []).append(res)
            n_kept += 1

    log(f"role pass done: {n_lines:,} lines, {n_errors:,} json errors, "
        f"{n_kept:,} roles kept for {len(roles_by_id):,} practitioners")
    return roles_by_id


def write_csv(path, rows):
    if not rows:
        log(f"{path}: nothing to write")
        return
    with open(path, "w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
        writer.writeheader()
        writer.writerows(rows)
    log(f"wrote {len(rows):,} rows -> {path}")


def main():
    root = resolve_root()
    prac_zst = os.path.join(root, "06-Practitioner.ndjson.zst")
    role_zst = os.path.join(root, "07-PractitionerRole.ndjson.zst")
    for p in (prac_zst, role_zst):
        if not os.path.exists(p):
            sys.exit(f"missing {p} -- run download_cms_ndh_bulk.py first")

    cohort_npis = load_cohort_npis()
    log(f"cohort NPIs loaded: {len(cohort_npis):,}")

    matched = scan_practitioners(prac_zst, cohort_npis)
    roles_by_id = scan_roles(role_zst, set(matched.keys()))

    cohort_rows, national_rows = [], []
    for pid, (npi, is_cohort, is_national, row) in matched.items():
        row = dict(row)
        row.update(parse_roles(roles_by_id.get(pid, [])))
        if is_cohort:
            cohort_rows.append(row)
        if is_national:
            national_rows.append(row)

    cohort_rows.sort(key=lambda r: r["npi"])
    national_rows.sort(key=lambda r: r["npi"])

    accessed_utc = utc_now()
    write_csv(COHORT_OUT, cohort_rows)
    write_csv(NATIONAL_OUT, national_rows)

    common_prov = dict(
        source_dataset="CMS National Directory of Healthcare Providers and Services (NDH), bulk NDJSON release",
        source_files={"practitioner": os.path.basename(prac_zst), "role": os.path.basename(role_zst)},
        source_file_sha256={os.path.basename(prac_zst): sha256_file(prac_zst),
                             os.path.basename(role_zst): sha256_file(role_zst)},
        accessed_utc=accessed_utc,
    )
    if cohort_rows:
        write_provenance(COHORT_OUT, source_url="https://directory.cms.gov/downloads", **common_prov,
                          cohort=ROSTER_FILE, cohort_sha256=sha256_file(ROSTER_FILE),
                          cohort_npis=len(cohort_npis), rows=len(cohort_rows))
    if national_rows:
        write_provenance(NATIONAL_OUT, source_url="https://directory.cms.gov/downloads", **common_prov,
                          taxonomy_filter=MIDWIFE_TAXONOMY, rows=len(national_rows))

    log(f"--- done: {len(cohort_rows):,} cohort rows, {len(national_rows):,} national CNM rows ---")


if __name__ == "__main__":
    main()
