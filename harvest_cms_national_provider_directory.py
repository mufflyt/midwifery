#!/usr/bin/env python3
# =============================================================================
# CMS National Directory of Healthcare Providers and Services (NDH) lookup
# =============================================================================
#
# WHY. CMS runs a public, no-auth, CORS-enabled FHIR R4 gateway at
# https://directory.cms.gov/fhir (the "National Provider Directory"). Verified
# live 2026-10-23 against a real cohort NPI (1629453816, Hawa Al-Hassan,
# CNM2738): it returned 15 work addresses, 7 phone numbers, both an NJ and a
# WA state license number, a Medicare-enrollment flag, an HHS exclusion-list
# flag, and -- the one no other source here carries -- 9 PractitionerRole
# entries each tagged acceptingPatients="newpt" (accepting new and existing
# patients), one per affiliated organization/location. That is the same
# "active appointment availability" evidence a Zocdoc scrape was being
# considered for, delivered through an authorized federal API instead.
#
# One gateway, not five payers. The CMS Interoperability rule requires each
# Medicare Advantage/Medicaid/CHIP payer to publish its OWN Plan-Net FHIR
# endpoint, and there is no CMS-maintained master list of those yet (only
# proposed, CMS-4208-F2, effective Oct 2026). This gateway's
# cms_aligned_with_data_network extension suggests it already blends payer
# network data in, so it is queried by NPI directly rather than re-deriving
# per-payer endpoint discovery this project does not need yet.
#
# WHAT THIS IS NOT. A measure of insurance network participation (that is
# AccessMRF's job, see accessmrf_config.py) or a replacement for NPPES
# matching. It is corroborating practice-location, contact and
# appointment-availability evidence for NPIs already resolved.
#
# Inputs : artifacts/amcb_npi_linkage_FROZEN.csv (cohort_member == TRUE)
# Outputs: artifacts/cms_ndh_raw/<npi>.{practitioner,practitionerrole}.json
#          (raw bundles, one pair per NPI -- doubles as the resume checkpoint:
#          an NPI with both files already on disk is skipped)
#          artifacts/cms_ndh_midwives.csv (flattened)
#          artifacts/cms_ndh_midwives.csv.provenance.json
#
# Usage  : python3 harvest_cms_national_provider_directory.py [n_to_fetch]
#          Resumes automatically; pass a count to run a bounded batch.
# =============================================================================
import csv
import json
import os
import sys
import time
import urllib.error
import urllib.request

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "tools"))
from provenance import sha256_file, utc_now, write_provenance  # noqa: E402

BASE        = "https://directory.cms.gov/fhir"
ROSTER_FILE = "artifacts/amcb_npi_linkage_FROZEN.csv"
RAW_DIR     = "artifacts/cms_ndh_raw"
OUT_CSV     = "artifacts/cms_ndh_midwives.csv"
LOG_FILE    = "cms_ndh_harvest_log.txt"
DELAY_SEC   = float(os.environ.get("CMS_NDH_DELAY", "0.25"))
# A no-auth gateway has no robots.txt to violate, but an honest, descriptive
# User-Agent (not a spoofed browser string) is appropriate for an API that is
# explicitly meant to be queried this way -- there is no bot-detection to
# evade here, unlike the Healthgrades/Doximity scrapers.
HEADERS = {"User-Agent": "midwifery-research-script/1.0", "Accept": "application/fhir+json"}
MAX_PAGES = 20  # safety cap on PractitionerRole pagination; nobody has 20 pages of roles


def log(msg):
    line = f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] {msg}"
    print(line)
    with open(LOG_FILE, "a", encoding="utf-8") as f:
        f.write(line + "\n")


def fetch_json(url, tries=3):
    for attempt in range(tries):
        req = urllib.request.Request(url, headers=HEADERS)
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                return json.loads(resp.read().decode("utf-8"))
        except urllib.error.HTTPError as e:
            log(f"  HTTP {e.code} on {url}")
            return None
        except Exception as e:
            if attempt == tries - 1:
                log(f"  fetch error after {tries} tries: {e}")
                return None
            time.sleep(1.0 * (attempt + 1))
    return None


def fetch_bundle_entries(url):
    """Follow a FHIR Bundle's 'next' link, bounded by MAX_PAGES."""
    entries = []
    for _ in range(MAX_PAGES):
        bundle = fetch_json(url)
        time.sleep(DELAY_SEC)
        if bundle is None:
            break
        entries.extend(e["resource"] for e in bundle.get("entry", []) if "resource" in e)
        next_url = next((l["url"] for l in bundle.get("link", []) if l.get("relation") == "next"), None)
        if not next_url:
            break
        url = next_url
    return entries


def parse_practitioner(res):
    ext = {e["url"].rsplit("/", 1)[-1]: e.get("valueBoolean") for e in res.get("extension", [])}
    names = res.get("name", [])
    name = names[0] if names else {}

    addresses = []
    for a in res.get("address", []):
        parts = a.get("line", []) + [a.get("city", ""), a.get("state", ""), a.get("postalCode", "")]
        addresses.append(" ".join(p for p in parts if p))

    phones = sorted({t["value"] for t in res.get("telecom", []) if t.get("system") == "phone"})

    # The live gateway (directory.cms.gov/fhir) codes taxonomy under
    # http://nucc.org/provider-taxonomy; the bulk NDJSON export codes the
    # SAME NUCC codes under the NDH-specific ValueSet URI instead. Confirmed
    # by inspecting 06-Practitioner.ndjson.zst directly -- not a documentation
    # assumption. Both must be accepted or every bulk-sourced row silently
    # loses its taxonomy. See docs/TECHNICAL_APPENDIX_CMS_NDH.md s5.
    TAXONOMY_SYSTEMS = ("http://nucc.org/provider-taxonomy",
                        "http://hl7.org/fhir/us/ndh/ValueSet/HealthcareIndividualTaxonomyVS")
    taxonomies, state_licenses, credential = [], [], None
    for q in res.get("qualification", []):
        coding = (q.get("code") or {}).get("coding", [])
        for c in coding:
            if c.get("system") in TAXONOMY_SYSTEMS:
                taxonomies.append(f"{c['code']}:{c.get('display', '')}")
            elif c.get("system") == "http://hl7.org/fhir/us/ndh/CodeSystem/FaCeT-credentialCS":
                credential = c.get("code")
        issuer = (q.get("issuer") or {}).get("reference", "")
        if issuer.startswith("Organization/Organization-State-"):
            state = issuer.rsplit("-", 1)[-1]
            for ident in q.get("identifier", []):
                state_licenses.append(f"{state}:{ident.get('value', '')}")

    return {
        "ndh_found": True,
        "ndh_active": res.get("active"),
        "ndh_family": name.get("family", ""),
        "ndh_given": " ".join(name.get("given", [])),
        "ndh_gender": res.get("gender", ""),
        "ndh_credential": credential or "",
        "ndh_taxonomies": "; ".join(sorted(set(taxonomies))),
        "ndh_state_licenses": "; ".join(sorted(set(state_licenses))),
        "ndh_n_addresses": len(addresses),
        "ndh_addresses": " | ".join(addresses),
        "ndh_n_phones": len(phones),
        "ndh_phones": "; ".join(phones),
        "ndh_cms_identity_verified": ext.get("base-ext-cms-identity-verified"),
        "ndh_medicare_enrollment": ext.get("base-ext-cms_medicare_enrollment"),
        "ndh_hhs_exclusion_list": ext.get("base-ext-hhs-in-exclusion-list"),
        "ndh_aligned_with_data_network": ext.get("base-ext-cms_aligned_with_data_network"),
    }


NOT_FOUND = {k: "" for k in parse_practitioner({"name": [{}]})}
NOT_FOUND["ndh_found"] = False


def parse_roles(roles):
    orgs, accepting_orgs = set(), set()
    for r in roles:
        org_ref = (r.get("organization") or {}).get("reference", "")
        if org_ref:
            orgs.add(org_ref)
        for ext in r.get("extension", []):
            if ext.get("url", "").endswith("base-ext-newpatients"):
                for sub in ext.get("extension", []):
                    for c in (sub.get("valueCodeableConcept") or {}).get("coding", []):
                        if c.get("code") == "newpt" and org_ref:
                            accepting_orgs.add(org_ref)
    return {
        "ndh_n_roles": len(roles),
        "ndh_n_orgs": len(orgs),
        "ndh_accepting_new_patients": len(accepting_orgs) > 0,
        "ndh_n_orgs_accepting": len(accepting_orgs),
    }


def harvest_one(npi, allow_fetch=True):
    """Load an NPI's bundles from the on-disk cache, fetching only if
    allow_fetch and nothing is cached yet. allow_fetch=False is for the
    flatten-to-CSV pass, which must never turn "write the CSV" into
    "fetch the whole roster" for NPIs a bounded run hasn't reached yet.
    """
    prac_path = os.path.join(RAW_DIR, f"{npi}.practitioner.json")
    role_path = os.path.join(RAW_DIR, f"{npi}.practitionerrole.json")
    cached = os.path.exists(prac_path) and os.path.exists(role_path)

    if not cached and not allow_fetch:
        return None

    if cached:
        with open(prac_path, encoding="utf-8") as f:
            prac_entries = json.load(f)
        with open(role_path, encoding="utf-8") as f:
            role_entries = json.load(f)
    else:
        prac_entries = fetch_bundle_entries(
            f"{BASE}/Practitioner?identifier=http://hl7.org/fhir/sid/us-npi|{npi}")
        role_entries = fetch_bundle_entries(
            f"{BASE}/PractitionerRole?practitioner=Practitioner-{npi}") if prac_entries else []
        with open(prac_path, "w", encoding="utf-8") as f:
            json.dump(prac_entries, f)
        with open(role_path, "w", encoding="utf-8") as f:
            json.dump(role_entries, f)

    row = {"npi": npi}
    row.update(parse_practitioner(prac_entries[0]) if prac_entries else NOT_FOUND)
    row.update(parse_roles(role_entries))
    return row


def main(n_limit=None):
    os.makedirs(RAW_DIR, exist_ok=True)
    os.makedirs("artifacts", exist_ok=True)

    with open(ROSTER_FILE, newline="", encoding="utf-8", errors="ignore") as f:
        roster = [r for r in csv.DictReader(f)
                  if r.get("cohort_member", "").strip().upper() == "TRUE" and r.get("npi", "").strip()]
    npis = sorted({r["npi"].strip() for r in roster})

    done_npis = {fn.split(".")[0] for fn in os.listdir(RAW_DIR) if fn.endswith(".practitioner.json")}
    todo = [n for n in npis if n not in done_npis]
    if n_limit is not None:
        todo = todo[:n_limit]

    log(f"cohort_npis={len(npis)} already_done={len(done_npis)} this_run={len(todo)} delay={DELAY_SEC}s")

    accessed_utc = utc_now()
    for i, npi in enumerate(todo, 1):
        try:
            harvest_one(npi)
        except Exception as e:
            log(f"  ERROR on {npi}: {e}")
        if i % 100 == 0 or i == len(todo):
            log(f"  progress {i}/{len(todo)}")

    # Rebuild the flattened CSV from whatever is CACHED on disk, not the full
    # roster -- allow_fetch=False means this never fetches. A bounded batch
    # therefore produces a CSV covering only the NPIs harvested so far, and a
    # later run extends it, rather than every run silently trying to fetch
    # the remaining thousands of not-yet-done NPIs.
    rows = [r for r in (harvest_one(n, allow_fetch=False) for n in npis) if r is not None]
    if not rows:
        log("nothing cached yet -- no CSV written")
        return
    with open(OUT_CSV, "w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
        writer.writeheader()
        writer.writerows(rows)

    found = sum(1 for r in rows if r["ndh_found"])
    accepting = sum(1 for r in rows if r.get("ndh_accepting_new_patients"))
    log(f"--- done: {found}/{len(rows)} found in NDH, {accepting} with >=1 org accepting new patients ---")

    write_provenance(
        OUT_CSV,
        source_url=f"{BASE}/Practitioner?identifier=http://hl7.org/fhir/sid/us-npi|<NPI>",
        accessed_utc=accessed_utc,
        source_dataset="CMS National Directory of Healthcare Providers and Services (NDH) FHIR R4 API",
        endpoint_base=BASE,
        cohort=ROSTER_FILE,
        cohort_sha256=sha256_file(ROSTER_FILE),
        cohort_npis=len(npis),
        npis_found_in_ndh=found,
        npis_with_org_accepting_new_patients=accepting,
        raw_bundle_dir=RAW_DIR,
    )


if __name__ == "__main__":
    args = sys.argv[1:]
    main(int(args[0]) if args else None)
