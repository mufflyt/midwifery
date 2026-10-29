#!/usr/bin/env python3
# =============================================================================
# Live Medicaid MCO network-membership check: IEHP (CA) + BCBS Michigan (MI)
# =============================================================================
# Of the 6 open-access (no-registration) Medicaid MCO FHIR Provider
# Directory endpoints identified from github.com/hltiunn/provider-directory-db
# with geographic overlap against this project's CA/MI cohort, only 2 of 6
# turned out to genuinely support unauthenticated Practitioner search when
# tested directly (2026-10-26) -- the other 4 (HealthPartners MN: 401 JWT
# required; BCBS Minnesota: 500 server error; Horizon NJ: 403 HAPI access-
# control rule denial; BCBS Texas: 503 down) are NOT queryable without
# registration or are currently broken, despite the audit repo's "valid"
# classification, which reflects only the /metadata discovery call
# succeeding, not actual resource search.
#
#   IEHP (CA)         https://fhir.iehp.org/provider-directory/
#   BCBS Michigan (MI) https://api.interopstation.com/mdhhs/fhir/
#
# Both confirmed live: FHIR R4, JSON, Practitioner?identifier=<NPI-system>|
# <NPI> search, zero auth required, real empty-vs-populated Bundle responses
# (not error pages) for a known test NPI.
#
# PURPOSE: a direct ghost-network check. For each cohort NPI in CA/MI, is it
# LISTED in the plan's own provider directory? Cross this against the
# already-built enrollment x spending confidence tier
# (medicaid_enrollment_spending_tier_by_npi.csv) to see how "listed
# in-network" relates to "confirmed billing Medicaid" and "enrolled":
#   listed + enrolled_and_billed   directory and billing agree -- healthy
#   listed + enrolled_only/neither listed but not confirmed billing --
#                                  consistent with a "ghost network" entry
#                                  (can't confirm it ISN'T one either --
#                                  billing absence has its own caveats, see
#                                  docs/TECHNICAL_APPENDIX_MEDICAID_PROCEDURE_BILLING.md S7)
#   not listed + enrolled_and_billed  billing real, but directory misses
#                                  them -- the OPPOSITE failure mode,
#                                  equally worth surfacing
#
# IEHP SCOPE CAVEAT: IEHP is a Riverside/San Bernardino-county regional
# Medi-Cal plan, not statewide. Most of the 6,215-NPI CA cohort practices
# outside IEHP's two-county service area, so a low CA match rate here
# reflects GEOGRAPHIC SCOPE, not network accuracy -- do not read it as a
# ghost-network signal the way a low MI match rate (a statewide plan) would
# be. BCBS Michigan (via "Blue Cross Complete of Michigan") IS statewide.
#
# Input : artifacts/ca_mi_cohort_for_mco_check.csv (npi, provider_group,
#         display_name, state -- written by a small R snippet calling
#         build_ob_midwife_cohort(include_state=TRUE), NOT re-run here)
# Output: artifacts/mco_network_membership_ca_mi.csv
# =============================================================================
import csv
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

print("=== Live Medicaid MCO network-membership check: IEHP (CA) + BCBS Michigan (MI) ===")

NPI_SYSTEM = "http://hl7.org/fhir/sid/us-npi"
PLAN_CONFIG = {
    "CA": {"plan_name": "IEHP", "fhir_base": "https://fhir.iehp.org/provider-directory"},
    "MI": {"plan_name": "BCBS Michigan (Blue Cross Complete)",
           "fhir_base": "https://api.interopstation.com/mdhhs/fhir"},
}
QUERY_DELAY_SECONDS = 0.4
COHORT_CSV = "artifacts/ca_mi_cohort_for_mco_check.csv"
OUT_CSV = "artifacts/mco_network_membership_ca_mi.csv"


class UnexpectedFhirResponse(RuntimeError):
    pass


def check_practitioner_listed(fhir_base, npi, opener=urllib.request.urlopen):
    """Query Practitioner?identifier=<npi-system>|<npi> and classify the
    result. Returns one of 'listed', 'not_listed', or raises
    UnexpectedFhirResponse for anything that isn't a well-formed FHIR
    searchset Bundle (so a silently-changed API surfaces as an error, not
    a false not_listed).
    """
    identifier = f"{NPI_SYSTEM}|{npi}"
    url = f"{fhir_base}/Practitioner?{urllib.parse.urlencode({'identifier': identifier})}"
    req = urllib.request.Request(url, headers={"Accept": "application/fhir+json",
                                                "User-Agent": "Mozilla/5.0"})
    try:
        with opener(req, timeout=30) as resp:
            body = json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        raise UnexpectedFhirResponse(f"HTTP {e.code} for NPI {npi}: {e.read()[:300]}")
    except (urllib.error.URLError, TimeoutError, OSError, json.JSONDecodeError) as e:
        # A transient network hiccup (slow/unreachable server, dropped
        # connection, truncated response) must not crash an 8,000-row run --
        # confirmed the hard way: the first full run died here at row 2,250
        # with zero rows saved, because this except clause originally caught
        # only HTTPError. Classified the same as any other query_error.
        raise UnexpectedFhirResponse(f"network error for NPI {npi}: {type(e).__name__}: {e}")

    if body.get("resourceType") != "Bundle" or body.get("type") != "searchset":
        raise UnexpectedFhirResponse(f"unexpected response shape for NPI {npi}: {str(body)[:300]}")

    entries = body.get("entry", [])
    return "listed" if len(entries) > 0 else "not_listed"


def load_cohort_rows(path):
    with open(path, "r", encoding="utf-8", errors="ignore") as f:
        return list(csv.DictReader(f))


def load_billing_tier(path="artifacts/medicaid_enrollment_spending_tier_by_npi.csv"):
    with open(path, "r", encoding="utf-8", errors="ignore") as f:
        return {r["npi"]: r["tier"] for r in csv.DictReader(f)}


FIELDNAMES = ["npi", "state", "plan_name", "provider_group", "display_name",
              "network_status", "billing_tier"]


def load_done_npis(path=OUT_CSV):
    """Resume support: NPI already present in a prior (possibly crashed) run's
    output are not re-queried. Confirmed necessary the hard way -- the first
    attempt at this harvester lost 2,250 completed queries to one uncaught
    network timeout with no incremental save at all.
    """
    if not os.path.exists(path):
        return set()
    with open(path, "r", encoding="utf-8", errors="ignore") as f:
        return {r["npi"] for r in csv.DictReader(f)}


def main():
    cohort_rows = load_cohort_rows(COHORT_CSV)
    billing_tier = load_billing_tier()
    print(f"Loaded {len(cohort_rows):,} CA/MI cohort rows, {len(billing_tier):,} billing-tier rows.")

    done_npis = load_done_npis()
    remaining = [r for r in cohort_rows if r["npi"] not in done_npis]
    print(f"{len(done_npis):,} already done from a prior run; {len(remaining):,} remaining.")

    file_exists = os.path.exists(OUT_CSV) and len(done_npis) > 0
    with open(OUT_CSV, "a", encoding="utf-8", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=FIELDNAMES)
        if not file_exists:
            writer.writeheader()

        for i, r in enumerate(remaining):
            state = r["state"]
            npi = r["npi"]
            cfg = PLAN_CONFIG[state]
            try:
                status = check_practitioner_listed(cfg["fhir_base"], npi)
            except UnexpectedFhirResponse as e:
                print(f"  WARNING: {e}", file=sys.stderr)
                status = "query_error"

            writer.writerow({
                "npi": npi,
                "state": state,
                "plan_name": cfg["plan_name"],
                "provider_group": r["provider_group"],
                "display_name": r["display_name"],
                "network_status": status,
                "billing_tier": billing_tier.get(npi, "not_in_billing_tier_data"),
            })
            f.flush()  # every row survives a crash, not just every 250
            if (i + 1) % 250 == 0:
                print(f"  ...{i + 1}/{len(remaining)} queried this run "
                      f"({len(done_npis) + i + 1}/{len(cohort_rows)} total)")
            time.sleep(QUERY_DELAY_SECONDS)

    with open(OUT_CSV, "r", encoding="utf-8", errors="ignore") as f:
        results = list(csv.DictReader(f))
    print(f"\n{OUT_CSV}: {len(results):,} rows total")

    print("=========================================================================")
    for state, cfg in PLAN_CONFIG.items():
        subset = [r for r in results if r["state"] == state]
        n_listed = sum(1 for r in subset if r["network_status"] == "listed")
        n_errors = sum(1 for r in subset if r["network_status"] == "query_error")
        print(f"  {state} ({cfg['plan_name']}): {n_listed:,}/{len(subset):,} listed "
              f"({100 * n_listed / len(subset):.1f}%), {n_errors} query errors")
    print("=========================================================================")


if __name__ == "__main__":
    main()
