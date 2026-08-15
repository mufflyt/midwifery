#!/usr/bin/env python3
# =============================================================================
# Automated Test Suite for Midwifery Workforce & Board of Nursing Pipeline
# =============================================================================
import csv
import json
import os
import unittest

# The master dataset is person-level -- names, certification numbers and NPIs
# for 12,211 midwives -- so it is gitignored by design and absent from every
# checkout. Three of the four tests below read it.
#
# They SKIP when it is missing rather than fail. An absent-input branch that
# fails cannot distinguish "the data is wrong" from "the data is not here",
# which is how this file broke CI: it asserted the artifact must exist, in a
# repository where it must NOT be committed. The rule is in the ci.yml header --
# an absent-input branch skips loudly, or the suite does not belong in CI.
#
# The skip names the producing script, so a local run tells you how to get the
# data rather than just that you lack it.
MASTER_CSV = "artifacts/cohort_midwives_tier1_tier2_bon_validated.csv"
MASTER_PRODUCER = "demonstrate_la_bon_access_pipeline.py"

SKIP_REASON = (
    f"{MASTER_CSV} is absent. It is person-level and gitignored by design, so "
    f"it is never present in a checkout; rebuild it locally with "
    f"`python3 {MASTER_PRODUCER}` to run this test."
)


class TestMidwiferyPipeline(unittest.TestCase):

    def setUp(self):
        self.master_csv = MASTER_CSV
        self.metadata_json = "metadata.json"

    def require_master(self):
        """Skip loudly when the person-level master is absent."""
        if not os.path.exists(self.master_csv):
            self.skipTest(SKIP_REASON)

    def test_metadata_file_exists_and_valid(self):
        """Verify that metadata.json exists and is valid JSON."""
        self.assertTrue(os.path.exists(self.metadata_json), "metadata.json must exist")
        with open(self.metadata_json, "r") as f:
            data = json.load(f)
            self.assertIn("title", data)
            self.assertIn("cohort_statistics", data)
            self.assertEqual(data["cohort_statistics"]["total_active_amcb_cnms"], 12211)

    def test_master_dataset_schema(self):
        """Verify master dataset fields and non-empty rows."""
        self.require_master()
        with open(self.master_csv, "r", encoding="utf-8", errors="ignore") as f:
            reader = csv.DictReader(f)
            rows = list(reader)
            self.assertGreater(len(rows), 8000, "Master dataset must contain at least 8,000 records")
            
            first_row = rows[0]
            self.assertIn("npi", first_row)
            self.assertIn("first_name", first_row)
            self.assertIn("last_name", first_row)

    def test_npi_format_validity(self):
        """Verify that all NPIs are 10-digit numeric strings."""
        self.require_master()
        with open(self.master_csv, "r", encoding="utf-8", errors="ignore") as f:
            reader = csv.DictReader(f)
            for i, r in enumerate(reader):
                npi = r.get("npi", "").strip()
                if npi:
                    self.assertEqual(len(npi), 10, f"NPI on row {i} must be 10 digits")
                    self.assertTrue(npi.isdigit(), f"NPI on row {i} must be numeric")

    def test_louisiana_cohort_size(self):
        """Verify Louisiana CNM roster size."""
        self.require_master()
        with open(self.master_csv, "r", encoding="utf-8", errors="ignore") as f:
            reader = csv.DictReader(f)
            la_rows = [r for r in reader if (r.get("scraped_bon_state") or r.get("nppes_state") or r.get("state") or "").upper() == "LA"]
            self.assertGreaterEqual(len(la_rows), 50, "Louisiana CNM roster must contain at least 50 verified CNMs")

if __name__ == "__main__":
    unittest.main()
