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

# THE ONE DEFECT THIS TEST WAS WRITTEN AGAINST, NAMED SO IT CANNOT HIDE A
# SECOND ONE.
#
# Added 2026-11-13. As first written, this test failed on the very row its
# docstring documents: NPI 1417904962 is still in the tracked discovery
# artifact, so the check could never be green and the nightly reported it
# every night as though it were new. A permanently red check stops being read,
# which is worse than no check -- and its stated purpose is the NEXT such row,
# not this one.
#
# So the known row is recorded with its EXACT count, and three things still
# fail:
#   - any other NPI over the threshold, in either file;
#   - this NPI with a different count (CMS re-exported it, changed);
#   - this NPI gone, so the entry cannot outlive its cause -- the same rule
#     N1 enforces on tests/ci_nightly_exceptions.txt.
#
# It is NOT dropped from the data. The row stays in the artifact exactly as
# CMS published it, written up in docs/TECHNICAL_APPENDIX_CMS_NDH.md; this
# only records that one specific published defect is already known.
KNOWN_CMS_DEFECTS = {
    ("artifacts/cms_ndh_bulk_national_cnm.csv", "1417904962"): 153,
}

FAILURES = []


def check(name, condition, detail=""):
    if condition:
        print(f"  PASS  {name}")
    else:
        print(f"  FAIL  {name}  {detail}")
        FAILURES.append(name)


# WHY THE 153-ADDRESS RECORD NEEDS NO SENSITIVITY ANALYSIS -- AND WHAT WOULD
# CHANGE THAT (audited 2026-11-13).
#
# The defect cannot perturb any estimate, because nothing downstream reads
# either NDH artifact: the only readers are clean_cms_ndh_bulk.py, which
# WRITES them, and this test. The NPI is also absent from
# artifacts/amcb_npi_linkage_FROZEN.csv and from cms_ndh_bulk_cohort.csv, so
# even a cohort-restricted consumer could not see it.
#
# Measured bound, kept so the number exists before it is needed rather than
# after: in the national discovery artifact the record holds 153 of 64,941
# addresses (0.236% of the address mass) and sets the maximum; excluding it
# moves that maximum from 153 to 60. In cms_ndh_bulk_cohort.csv -- the file any
# cohort analysis would actually use -- the row is not present at all, the
# maximum is 52 across 16,361 CNMs, and no row exceeds 60.
#
# That premise is enforced here rather than remembered. The day a script starts
# reading either artifact, this fails and the defect gets re-evaluated against
# that specific use before it reaches an estimate -- which is the risk the
# docstring above was written about ("gets fed into something that assumes NDH
# address counts are vetted worksites"). A legitimate new consumer is added to
# ALLOWED_NDH_READERS together with that re-evaluation; it is a tripwire, not a
# prohibition.
ALLOWED_NDH_READERS = ("clean_cms_ndh_bulk.py",
                       "tests/test_cms_ndh_address_count_sanity.py")


def check_no_cohort_reaching_consumer():
    """Fail if anything but the producer and this test reads the NDH artifacts."""
    import subprocess
    tracked = subprocess.run(["git", "ls-files", "*.R", "*.py", "*.Rmd", "*.qmd"],
                             cwd=ROOT, capture_output=True, text=True).stdout.split()
    stems = ("cms_ndh_bulk_national_cnm", "cms_ndh_bulk_cohort")
    readers = []
    for rel in tracked:
        if rel in ALLOWED_NDH_READERS:
            continue
        try:
            txt = open(os.path.join(ROOT, rel), encoding="utf-8", errors="replace").read()
        except OSError:
            continue
        if any(stem in txt for stem in stems):
            readers.append(rel)
    check("no unreviewed script consumes the NDH artifacts",
          not readers,
          detail=("these now read an artifact holding a known 153-address CMS "
                  "defect; re-evaluate its effect on what they compute, then add "
                  "them to ALLOWED_NDH_READERS: " + ", ".join(readers))
                 if readers else None)


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

        def describe(o):
            return (f"NPI {o['npi']} ({o.get('ndh_given','')} {o.get('ndh_family','')}): "
                    f"{o['ndh_n_addresses']} addresses")

        unexpected = [o for o in offenders
                      if KNOWN_CMS_DEFECTS.get((rel_path, o["npi"])) !=
                      int(o.get("ndh_n_addresses", 0) or 0)]
        check(f"{rel_path}: no NEW row exceeds {MAX_PLAUSIBLE_ADDRESSES} addresses",
              len(unexpected) == 0,
              detail="; ".join(describe(o) for o in unexpected) or None)

        for o in offenders:
            if (rel_path, o["npi"]) in KNOWN_CMS_DEFECTS:
                print(f"  KNOWN {describe(o)} -- documented CMS export defect, "
                      f"see docs/TECHNICAL_APPENDIX_CMS_NDH.md")

        # A recorded defect that is no longer in the data must be deleted from
        # KNOWN_CMS_DEFECTS, not left to excuse some future row silently.
        seen = {o["npi"] for o in offenders}
        stale = [npi for (f, npi) in KNOWN_CMS_DEFECTS if f == rel_path and npi not in seen]
        check(f"{rel_path}: every recorded defect is still present",
              len(stale) == 0,
              detail=("gone from the data -- delete from KNOWN_CMS_DEFECTS: "
                      + ", ".join(stale)) if stale else None)

        # Visibility, not just pass/fail -- same discipline as the
        # Healthgrades scraper's "AMBIGUOUS: ... Not attributable" logging.
        for thresh in (10, 25, 50, 100):
            n = sum(1 for r in rows if int(r.get("ndh_n_addresses", 0) or 0) > thresh)
            print(f"        {rel_path}: {n} of {len(rows)} rows have >{thresh} addresses")

    check_no_cohort_reaching_consumer()

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
