#!/usr/bin/env python3
# =============================================================================
# Live Texas BON cross-reference, using the TRACKED roster as the cohort
# =============================================================================
# Third real state added after the 2026-08-17/2026-09-11 fabrication findings
# (docs/PROVENANCE_DEFECT_BON_LICENSE_IDENTIFIERS.md). Follows
# harvest_live_co_bon_from_tracked_roster.py's pattern exactly -- a real HTTP
# request to a real state open-data API, honest failure on error, and
# name-based matching against the tracked cohort.
#
# Source: Texas Board of Nursing (via data.texas.gov / Socrata), dataset
# jnzg-cr4w, "APRN-Active." Confirmed via direct API query (2026-09-12):
# apn_category has a genuine "NURSE MIDWIFE" value (754 current records,
# distinct from NURSE PRACTITIONER/CLINICAL NURSE SPECIALIST/NURSE
# ANESTHETIST), and -- unlike Colorado, which required a second dataset
# (RXN/subcategory=CNM) joined by a contact ID -- prescriptive authority is
# tracked on the SAME row via apn_prescriptive_authority_status: of the 754
# nurse-midwife records, 704 (93.4%) show "Active." No cross-agency join
# (e.g. against the Texas Medical Board's separately-published Prescriptive
# Delegation dataset) is needed for this.
# https://data.texas.gov/resource/jnzg-cr4w.json
#
# Matched by last+first name (same key scheme as the WA/CO scripts) against
# nppes_state == "TX" in the cohort -- NOT a license-number or NPI join,
# because this Texas dataset carries neither an AMCB nor an NPI identifier.
# Name matching is imperfect (misses a hyphenated or maiden-name mismatch, can
# over-match a common name); this script reports what it found as its own
# result, not a confirmation of AMCB/NPPES identity.
#
# COHORT: artifacts/tracked_roster_active_primary_linked.csv (tracked; built by
# build_tracked_roster.R), the same source harvest_live_wa_bon_from_tracked_
# roster.py uses. It was artifacts/amcb_npi_linkage_FROZEN.csv, which is
# gitignored, person-level, and absent from a checkout without the data vault,
# so this script could not run at all on such a machine. The two cohorts are
# not the same population and the counts are not comparable: the freeze carries
# every certificant, the tracked roster only ACTIVE, primary-linked ones. TX
# rows fell from 736 to 536 and matches from 498 to 469, so the match RATE rose
# from 67.7% to 87.5%. The rows that went are mostly certificants the Texas
# board has no active APRN record for, which is what a roster of active
# certificants is supposed to leave out. Treat this output as its own result.
#
# TLS: verification stays ON. A macOS framework Python ships no CA store, so
# ssl.create_default_context() raises CERTIFICATE_VERIFY_FAILED against
# data.texas.gov; this falls back to certifi's bundle. It briefly used
# CERT_NONE instead, which turns off certificate and hostname checking
# altogether and would accept any server answering for that name.
# =============================================================================
import csv
import hashlib
import json
import os
import ssl
import urllib.parse
import urllib.request
from datetime import datetime, timezone

print("=== Live Texas BON cross-reference (tracked-roster cohort) ===")

TX_API = "https://data.texas.gov/resource/jnzg-cr4w.json"
TX_QUERY = {
    "apn_category": "NURSE MIDWIFE",
    "$limit": "5000",
}
tx_url = TX_API + "?" + urllib.parse.urlencode(TX_QUERY)
req = urllib.request.Request(tx_url, headers={"User-Agent": "Mozilla/5.0"})


def verified_tls_context():
    """A verifying TLS context, using certifi when the interpreter has no CA store.

    Returns a context that checks the certificate chain and the hostname. Never
    return an unverified one: without verification any host that answers for
    data.texas.gov would be trusted, and a licensure record read from an
    unauthenticated source is not evidence of anything.
    """
    ctx = ssl.create_default_context()
    if ctx.cert_store_stats()["x509_ca"] > 0:
        return ctx
    try:
        import certifi
    except ImportError:
        raise SystemExit(
            "This Python has no CA certificate store, so HTTPS cannot be verified.\n"
            "Install certifi (python3 -m pip install certifi), or on macOS run\n"
            "'Install Certificates.command' from the Python installation folder."
        )
    ctx.load_verify_locations(cafile=certifi.where())
    return ctx


retrieved_at = datetime.now(timezone.utc)
live_tx_records = []
try:
    with urllib.request.urlopen(req, context=verified_tls_context(), timeout=30) as response:
        live_tx_records = json.loads(response.read().decode("utf-8"))
    print(f"Successfully streamed {len(live_tx_records):,} live TX nurse-midwife APRN records.")
except Exception as e:
    print(f"Error fetching live TX BON data: {e}")
    raise SystemExit(1)

# Index live TX records by Last_First name -- same key scheme as the CO script.
tx_lookup = {}
for r in live_tx_records:
    fn = r.get("first_name", "").upper().strip()
    ln = r.get("last_name", "").upper().strip()
    if fn and ln:
        tx_lookup.setdefault(f"{ln}_{fn}", []).append(r)

# Cross-reference against the TRACKED roster, filtered to TX.
roster_file = "artifacts/tracked_roster_active_primary_linked.csv"
matched_tx = []
unmatched_tx = []

with open(roster_file, "r", encoding="utf-8", errors="ignore") as f:
    reader = csv.DictReader(f)
    for r in reader:
        st = r.get("nppes_state", "").upper().strip()
        if st != "TX":
            continue
        fn = (r.get("nppes_first_name") or r.get("first_name") or "").upper().strip()
        ln = (r.get("nppes_last_name") or r.get("last_name") or "").upper().strip()
        key = f"{ln}_{fn}"

        out = {
            "certification_number": r.get("certification_number", ""),
            "last_name": r.get("last_name", ""),
            "first_name": r.get("first_name", ""),
            "npi": r.get("npi", ""),
            "nppes_state": st,
        }
        candidates = tx_lookup.get(key, [])
        if len(candidates) == 1:
            tx_info = candidates[0]
            out["live_bon_license_number"] = tx_info.get("license_number", "")
            out["live_bon_status"] = tx_info.get("apn_status", "")
            out["live_bon_apn_sub_category"] = tx_info.get("apn_sub_category", "")
            out["live_rxn_authority_number"] = tx_info.get("apn_prescriptive_authority_number", "")
            out["live_rxn_authority_status"] = tx_info.get("apn_prescriptive_authority_status", "")
            out["live_rxn_authority_exp_date"] = tx_info.get("apn_prescriptive_authority_expiration_date", "")
            out["live_bon_match_status"] = "VERIFIED_LIVE_BON"
            matched_tx.append(out)
        else:
            # 0 candidates: no name match at all. >1: an ambiguous common name
            # -- reported as unmatched rather than guessed, same as the CO
            # script's handling of name collisions.
            out["live_bon_license_number"] = "NA"
            out["live_bon_status"] = "UNMATCHED_BON" if not candidates else "AMBIGUOUS_BON"
            out["live_bon_apn_sub_category"] = "NA"
            out["live_rxn_authority_number"] = "NA"
            out["live_rxn_authority_status"] = "NA"
            out["live_rxn_authority_exp_date"] = "NA"
            out["live_bon_match_status"] = "UNMATCHED" if not candidates else "AMBIGUOUS"
            unmatched_tx.append(out)

out_csv = "artifacts/live_texas_bon_ingested_midwives_from_tracked_roster.csv"
out_provenance = out_csv + ".provenance.json"
rows = matched_tx + unmatched_tx
if rows:
    fieldnames = list(rows[0].keys())
    with open(out_csv, "w", encoding="utf-8", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


# The sidecar every tracked artifact is supposed to carry: what was queried,
# when, and the SHA-256 of both the cohort read and the artifact written. The
# cohort is tracked now, so this artifact is reproducible from the repository
# and no longer belongs on tests/ci_artifact_provenance_baseline.txt.
if rows:
    provenance = {
        "artifact": out_csv,
        "sha256": sha256_file(out_csv),
        "byte_size": os.path.getsize(out_csv),
        "source_api": tx_url,
        "source_dataset": "Texas Board of Nursing, APRN-Active (data.texas.gov jnzg-cr4w)",
        "retrieved_utc": retrieved_at.strftime("%Y-%m-%d %H:%M:%S UTC"),
        "records_retrieved": len(live_tx_records),
        "cohort": roster_file,
        "cohort_sha256": sha256_file(roster_file),
        "cohort_rows_tx": len(rows),
        "cohort_matched_rows": len(matched_tx),
        "match_key": "last_name + first_name (upper, trimmed); ambiguous names reported unmatched",
        "verification_portal": "https://www.bon.texas.gov/licensure_verification.asp",
    }
    with open(out_provenance, "w", encoding="utf-8") as f:
        json.dump(provenance, f, indent=2)
        f.write("\n")

n_total = len(matched_tx) + len(unmatched_tx)
n_rxn_active = sum(1 for r in matched_tx if r["live_rxn_authority_status"] == "Active")
print("=========================================================================")
print("  LIVE TX BON CROSS-REFERENCE COMPLETE (tracked-roster cohort)")
print(f"  Total TX-state rows in tracked roster : {n_total:,}")
if n_total:
    print(f"  Live State BON Matched                : {len(matched_tx):,} ({len(matched_tx)/n_total*100:.1f}%)")
if matched_tx:
    print(f"  Of those, Active RXN authority         : {n_rxn_active:,} ({n_rxn_active/len(matched_tx)*100:.1f}%)")
print(f"  Written to: {out_csv}")
print(f"  Provenance: {out_provenance}")
print("=========================================================================")
