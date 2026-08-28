#!/usr/bin/env python3
# =============================================================================
# Adversarial loop, cycle 24 — 4 BVA / 3 semantic / 3 adversarial
# =============================================================================
# Target (at cycle time): run_midwifery_microsimulation.py. Zero prior tests
# existed for this file despite it producing a README-embedded, 15-year
# national workforce forecast
# (artifacts/midwifery_microsimulation_projections_2026_2040.csv,
# artifacts/plots/plot3_microsimulation_workforce_projections.png) -- exactly
# the class of public-facing scientific artifact this loop exists to protect.
#
# Archived 2026-08-28 to @archive/run_midwifery_microsimulation.py, superseded
# by the R port (run_midwifery_microsimulation.R). Kept and still tested here
# because it is the pinned oracle the R port's cross-implementation test
# checks against -- see tests/test_run_midwifery_microsimulation.R.
#
# See docs/ADVERSARIAL_LOOP_LEDGER.md, Cycle 24, for the full defect writeup.
import subprocess
import sys
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
ARCHIVE_DIR = REPO_ROOT / "@archive"
SIM_FILE = ARCHIVE_DIR / "run_midwifery_microsimulation.py"

# Archived 2026-08-28 (superseded by run_midwifery_microsimulation.R) but
# still the pinned oracle this cycle's tests, and the R port's own
# cross-implementation check, both depend on. sys.path insertion, not a
# plain `import`, because pytest's conftest.py only puts the repo ROOT on
# sys.path, and a plain `python3 -m unittest` run from elsewhere would not
# find the module inside `@archive/` otherwise.
sys.path.insert(0, str(ARCHIVE_DIR))
import run_midwifery_microsimulation as sim


def old_buggy_split(inflow, rural_share=0.08):
    """The ORIGINAL allocation this module used, reproduced verbatim for the
    anti-ceremony check (T24-SEM1b): independent truncation of both shares,
    which does not generally sum to `inflow`."""
    return int(inflow * rural_share), int(inflow * (1 - rural_share))


class TestBVA(unittest.TestCase):
    """T24-1 .. T24-4 — boundary-value analysis."""

    def test_zero_initial_workforce_never_goes_negative_and_conserves(self):
        """T24-1 (BVA): a zero baseline is a valid, if unusual, input -- a
        brand-new specialty or a cohort filter that matched nobody. The
        simulation must not crash, must never go negative, and must still
        conserve population from a zero start."""
        rows = sim.project_workforce(0)
        for row in rows:
            self.assertGreaterEqual(row["Total_Active_CNM_Workforce"], 0)
            self.assertGreaterEqual(row["Rural_Practicing_CNMs"], 0)
            self.assertGreaterEqual(row["Urban_Practicing_CNMs"], 0)
            self.assertEqual(
                row["Rural_Practicing_CNMs"] + row["Urban_Practicing_CNMs"],
                row["Total_Active_CNM_Workforce"],
                f"population not conserved in {row['Simulation_Year']} from a zero baseline",
            )

    def test_single_simulation_year_matches_hand_computation(self):
        """T24-2 (BVA): the minimum meaningful run length is one year. Every
        value is checked against a hand computation, not just internal
        self-consistency, so this pins the actual arithmetic contract."""
        rows = sim.project_workforce(1000, years=[2026])
        self.assertEqual(len(rows), 1)
        row = rows[0]
        # active_0=1000, rural_0=143, urban_0=857
        # outflow = int(1000*0.032) = 32
        # movers = int(143*0.041) = 5  -> rural=138, urban=862
        # rural_share_now = 138/1000 = 0.138 -> rural_outflow = round(32*0.138)=round(4.416)=4
        # urban_outflow = 32-4 = 28 -> rural=134, urban=834
        # rural_inflow = int(680*0.08)=54, urban_inflow=680-54=626
        # rural=134+54=188, urban=834+626=1460
        # active = 1000+680-32 = 1648
        self.assertEqual(row["Total_Active_CNM_Workforce"], 1648)
        self.assertEqual(row["Retirement_Outflow"], 32)
        self.assertEqual(row["Rural_Practicing_CNMs"], 188)
        self.assertEqual(row["Urban_Practicing_CNMs"], 1460)
        self.assertEqual(row["Rural_Practicing_CNMs"] + row["Urban_Practicing_CNMs"],
                          row["Total_Active_CNM_Workforce"])

    def test_extreme_full_attrition_rate_conserves_and_stays_nonnegative(self):
        """T24-3 (BVA): annual_retire_rate=1.0 is an extreme but VALID
        parameter value (everyone retires every year, workforce fully
        replaced by inflow). This stresses the outflow-allocation arithmetic
        at its ceiling rather than its typical 3.2%."""
        rows = sim.project_workforce(5000, annual_retire_rate=1.0)
        for row in rows:
            self.assertGreaterEqual(row["Rural_Practicing_CNMs"], 0)
            self.assertGreaterEqual(row["Urban_Practicing_CNMs"], 0)
            self.assertEqual(row["Total_Active_CNM_Workforce"], 680,
                              "full attrition should leave exactly one year's inflow")
            self.assertEqual(
                row["Rural_Practicing_CNMs"] + row["Urban_Practicing_CNMs"],
                row["Total_Active_CNM_Workforce"])

    def test_conservation_holds_across_many_initial_values_rounding_sweep(self):
        """T24-4 (BVA): rounding/truncation boundaries do not announce
        themselves at round numbers. Sweep every initial workforce from 0 to
        2,000 for one simulated year and require exact conservation for all
        of them -- the class of value where independent int() truncation of
        two shares most often fails to sum to the whole."""
        failures = []
        for n in range(0, 2001):
            row = sim.project_workforce(n, years=[2026])[0]
            total = row["Rural_Practicing_CNMs"] + row["Urban_Practicing_CNMs"]
            if total != row["Total_Active_CNM_Workforce"]:
                failures.append((n, total, row["Total_Active_CNM_Workforce"]))
        self.assertEqual(failures, [],
                          f"{len(failures)} of 2001 initial values broke conservation, e.g. {failures[:5]}")


class TestSemantic(unittest.TestCase):
    """T24-5 .. T24-7 — semantic / contract tests."""

    def test_population_conservation_contract_over_full_15_year_run(self):
        """T24-5 (semantic): the central contract this cycle exists to pin.
        Rural + Urban must equal Total for every year of the real 15-year,
        12,211-baseline run this repository actually publishes."""
        rows = sim.project_workforce(12211)
        self.assertEqual(len(rows), 15)
        for row in rows:
            self.assertEqual(
                row["Rural_Practicing_CNMs"] + row["Urban_Practicing_CNMs"],
                row["Total_Active_CNM_Workforce"],
                f"{row['Simulation_Year']}: rural+urban != total -- "
                f"a published figure would show a sub-population exceeding the whole",
            )

    def test_anti_ceremony_old_split_logic_does_not_conserve(self):
        """T24-5b (anti-ceremony): the retired allocation logic -- computing
        both shares independently via int() truncation, and never subtracting
        outflow from either bucket -- must actually FAIL the conservation
        check T24-5 pins. If it didn't, T24-5 would be proving nothing."""
        active, rural, urban = 12211, int(12211 * 0.143), 12211 - int(12211 * 0.143)
        for _year in range(2026, 2041):
            outflow = int(active * 0.032)
            movers = int(rural * 0.041)
            rural -= movers
            urban += movers
            active = active + 680 - outflow
            r_add, u_add = old_buggy_split(680)
            rural += r_add
            urban += u_add
        self.assertNotEqual(rural + urban, active,
                             "the original logic was expected to violate conservation; "
                             "if this now passes, the fixture no longer reproduces the defect")

    def test_rural_workforce_share_is_numeric_not_a_percent_string(self):
        """T24-6 (semantic): a CSV data column is a machine-readable contract.
        The published field must be a number equal to the actual computed
        share, not a display-formatted string a consumer must re-parse."""
        row = sim.project_workforce(12211, years=[2026])[0]
        pct = row["Rural_Workforce_Share_Pct"]
        self.assertIsInstance(pct, float,
                               "Rural_Workforce_Share_Pct must be numeric, not a formatted string")
        expected = round(100 * row["Rural_Practicing_CNMs"] / row["Total_Active_CNM_Workforce"], 1)
        self.assertEqual(pct, expected)

    def test_retirement_allocated_by_current_composition_not_new_grad_share(self):
        """T24-7 (semantic): retirees are drawn from the EXISTING workforce
        and must be allocated by its current rural/urban composition -- not
        by rural_grad_share (8%), which describes where NEW graduates start.
        Conflating the two populations is a distinct, plausible-looking wrong
        fix for the conservation defect. Constructed so current rural share
        (~50%) is far from rural_grad_share (8%): if outflow followed the
        grad share instead, rural would end up far higher than this."""
        rows = sim.project_workforce(
            1000, years=[2026],
            rural_baseline_pct=0.50, annual_retire_rate=0.10, annual_rural_drift=0.0)
        row = rows[0]
        # active_0=1000, rural_0=500, urban_0=500; no drift.
        # outflow = int(1000*0.10) = 100
        # rural_share_now = 500/1000 = 0.50 -> rural_outflow = round(100*0.50) = 50
        self.assertEqual(row["Retirement_Outflow"], 100)
        # rural before inflow = 500 - 50 = 450; + rural_inflow int(680*0.08)=54 -> 504
        self.assertEqual(row["Rural_Practicing_CNMs"], 504,
                          "retirement outflow was not allocated by current (~50%) rural share")


class TestAdversarial(unittest.TestCase):
    """T24-8 .. T24-10 — adversarial tests."""

    def test_import_has_no_side_effects_from_any_working_directory(self):
        """T24-8 (adversarial): hidden dependence on the working directory.
        The module must be importable -- with zero file I/O -- from a
        directory that does not even contain an artifacts/ folder. Run as a
        subprocess so the import is genuinely fresh, not cached from this
        test session's own sys.modules."""
        result = subprocess.run(
            [sys.executable, "-c",
             f"import sys; sys.path.insert(0, {str(ARCHIVE_DIR)!r}); "
             "import run_midwifery_microsimulation; print('OK')"],
            cwd="/tmp", capture_output=True, text=True, timeout=30,
        )
        self.assertEqual(result.returncode, 0,
                          f"import failed outside the repo directory:\n{result.stderr}")
        self.assertIn("OK", result.stdout)

    def test_negative_initial_workforce_is_rejected_not_silently_propagated(self):
        """T24-9 (adversarial): a negative cohort count is nonsensical (an
        upstream filter bug, a sign error in a join). The function must
        refuse it rather than silently produce a negative-population forecast
        that could still look superficially like ordinary output."""
        with self.assertRaises(ValueError):
            sim.project_workforce(-5)

    def test_no_hardcoded_reliance_on_the_current_cohort_size(self):
        """T24-10 (adversarial): assumptions that hold in the current fixture
        (initial_workforce == 12,211 today) but are not guaranteed by the
        contract. The function must scale with whatever count the input file
        actually contains next year, not with today's number baked in."""
        source = SIM_FILE.read_text()
        code_lines = [ln for ln in source.splitlines() if not ln.strip().startswith("#")]
        code_only = "\n".join(code_lines)
        self.assertNotIn("12211", code_only,
                          "the historical cohort size must not appear in executable code")
        self.assertNotIn("12,211", code_only,
                          "the historical cohort size must not appear in executable code")
        # Functional confirmation: three arbitrary, unrelated sizes must each
        # produce their own distinct, internally-scaled first-year total.
        totals = {n: sim.project_workforce(n, years=[2026])[0]["Total_Active_CNM_Workforce"]
                  for n in (1, 9999, 500000)}
        self.assertEqual(len(set(totals.values())), 3,
                          "workforce totals did not scale distinctly with initial_workforce")


if __name__ == "__main__":
    unittest.main()
