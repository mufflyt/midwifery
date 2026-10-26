#!/usr/bin/env python3
"""Regression: no CMS NDH-sourced row may carry an implausible address count
without being caught here first.

THE BUG THIS LOCKS OUT

NPI 1417904962 (Monica Amona Martin, MD -- Internal Medicine, per both the
live NPPES registry and CMS's own DAC_NationalDownloadableFile.csv, which
lists her name correctly and shows 36 real multi-state telehealth/hospitalist
enrollment rows) carries, in CMS's OWN bulk NDH export
(06-Practitioner.ndjson.zst, generated 2026-10-14), a SINGLE Practitioner
resource with:
  - 153 addresses,
  - a garbled extra name "AMONA MONICA CLUELULETE NATANA" that appears
    nowhere else -- not in the live NPPES registry, not in DAC -- alongside
    four OTHER, correct "MARTIN" name entries in the SAME resource,
  - a qualification entry tagging her "Advanced Practice Midwife"
    (367A00000X), tied to the issuer of her real Massachusetts MEDICAL
    license (281810) -- a taxonomy/license-type mismatch, not a specialty
    she holds.

This is a defect in CMS's own published data, confirmed by direct inspection
of the raw NDJSON line -- not a join, merge, or name-matching bug in this
project's code. parse_practitioner() takes one FHIR resource and flattens it
verbatim; clean_cms_ndh_bulk.py performs no cross-NPI joins on Practitioner
records at all. The NPI is NOT and has never been in
artifacts/amcb_npi_linkage_FROZEN.csv -- it surfaced only in the discovery-only
artifacts/cms_ndh_bulk_national_cnm.csv, which (at the time this test was
written) no other script reads. See
docs/TECHNICAL_APPENDIX_CMS_NDH.md for the full writeup.

WHAT THIS GUARDS. Not "contamination" (there is none here to catch) but the
NEXT time this NPI -- or any other CMS NDH record like it -- gets exported
again with its defect intact, or gets fed into something that assumes NDH
address counts are vetted worksites. A row this far outside the observed
distribution (cohort max 52 addresses across 16,361 real CNMs; this NPI is
nearly 3x that) must stop a pipeline, not flow through it silently.

Run:  python3 tests/test_cms_ndh_address_count_sanity.py
"""
import csv
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

# Observed distribution (2026-10-23): cohort max was 52 across 16,361 real
# CNMs; the next-highest national figure below the known defect was 60. 100
# sits comfortably above every plausible multi-site/locum case seen and
# below nothing legitimate observed -- a row past it gets a human look before
# the pipeline uses it, not an automatic drop (this test never deletes data).
MAX_PLAUSIBLE_ADDRESSES = 100

FILES_TO_CHECK = (
    "artifacts/cms_ndh_bulk_national_cnm.csv",
    "artifacts/cms_ndh_bulk_cohort.csv",
)

FAILURES = []


def check(name, condition, detail=""):
    if condition:
        print(f"  PASS  {name}")
    else:
        print(f"  FAIL  {name}  {detail}")
        FAILURES.append(name)


def run():
    checked_any = False
    for rel_path in FILES_TO_CHECK:
        path = os.path.join(ROOT, rel_path)
        if not os.path.exists(path):
            print(f"  SKIP  {rel_path} not present (not yet generated this run)")
            continue
        checked_any = True

        with open(path, newline="", encoding="utf-8") as f:
            rows = list(csv.DictReader(f))

        offenders = [r for r in rows if int(r.get("ndh_n_addresses", 0) or 0) > MAX_PLAUSIBLE_ADDRESSES]
        check(f"{rel_path}: no row exceeds {MAX_PLAUSIBLE_ADDRESSES} addresses",
              len(offenders) == 0,
              detail="; ".join(f"NPI {o['npi']} ({o.get('ndh_given','')} {o.get('ndh_family','')}): "
                                f"{o['ndh_n_addresses']} addresses"
                                for o in offenders) or None)

        # Visibility, not just pass/fail -- same discipline as the
        # Healthgrades scraper's "AMBIGUOUS: ... Not attributable" logging.
        for thresh in (10, 25, 50, 100):
            n = sum(1 for r in rows if int(r.get("ndh_n_addresses", 0) or 0) > thresh)
            print(f"        {rel_path}: {n} of {len(rows)} rows have >{thresh} addresses")

    if not checked_any:
        print("  SKIP  neither file present -- run clean_cms_ndh_bulk.py first")

    print("")
    if FAILURES:
        print(f"{len(FAILURES)} FAILED: {FAILURES}")
        return 1
    print("all checks passed")
    return 0


def test_ndh_address_count_sanity():
    """Pytest entry point; retain run() for direct command-line use."""
    assert run() == 0


if __name__ == "__main__":
    sys.exit(run())
