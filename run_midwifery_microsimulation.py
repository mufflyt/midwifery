#!/usr/bin/env python3
# =============================================================================
# National Certified Nurse-Midwife (CNM) Workforce Microsimulation Engine
# =============================================================================
# Projects 15-year aggregate workforce state transitions -- inflow, retirement
# attrition, and rural/urban composition -- across a national CNM cohort
# (2026-2040). This is a deterministic cohort-component projection, not a
# stochastic microsimulation of individuals: no random draw occurs anywhere in
# it, despite the historical `random.seed(42)` call below, kept only because a
# downstream consumer may come to depend on the module having called it.
# =============================================================================
import csv

SIMULATION_YEARS = range(2026, 2041)
ANNUAL_NEW_GRADUATES = 680   # Annual AMCB new certificant inflow
ANNUAL_RETIRE_RATE = 0.032   # 3.2% annual attrition/retirement
ANNUAL_RURAL_DRIFT = 0.041   # 4.1% annual cross-county mobility
RURAL_BASELINE_PCT = 0.143   # 14.3% rural baseline
RURAL_GRAD_SHARE = 0.08      # 8% of new grads enter rural practice
BIRTHS_PER_CNM = 42.5        # average births attended per active CNM per year


def project_workforce(
    initial_workforce,
    years=SIMULATION_YEARS,
    annual_new_graduates=ANNUAL_NEW_GRADUATES,
    annual_retire_rate=ANNUAL_RETIRE_RATE,
    annual_rural_drift=ANNUAL_RURAL_DRIFT,
    rural_baseline_pct=RURAL_BASELINE_PCT,
    rural_grad_share=RURAL_GRAD_SHARE,
    births_per_cnm=BIRTHS_PER_CNM,
):
    """Project aggregate CNM workforce state year over year.

    Returns a list of one dict per simulated year. Population is conserved by
    construction: `Rural_Practicing_CNMs + Urban_Practicing_CNMs ==
    Total_Active_CNM_Workforce` for every returned row (tests/
    test_cycle24_microsimulation_conservation.py pins this).

    Retirement outflow is removed from the rural and urban sub-populations in
    proportion to their CURRENT composition (immediately after that year's
    rural-to-urban drift) -- not by `rural_grad_share`, which describes where
    INCOMING graduates start practicing, a different population from the
    existing workforce that is retiring. New-graduate inflow is split by
    `rural_grad_share` as before. In both cases one share is computed and the
    other is derived by subtraction, so the two allocations always sum to
    exactly the total being allocated regardless of independent truncation --
    computing `int(x * 0.08)` and `int(x * 0.92)` separately does not
    generally sum to `x`, which is how the previous version of this function
    silently lost population every year (see the ledger entry for this fix).
    """
    if initial_workforce < 0:
        raise ValueError(
            f"initial_workforce must be non-negative, got {initial_workforce}")

    current_active = initial_workforce
    current_rural = int(initial_workforce * rural_baseline_pct)
    current_urban = current_active - current_rural

    results = []
    for year in years:
        inflow = annual_new_graduates
        outflow = int(current_active * annual_retire_rate)

        # Rural-to-urban drift among the existing population. Zero-sum
        # between the two buckets; does not touch current_active.
        movers = int(current_rural * annual_rural_drift)
        current_rural -= movers
        current_urban += movers

        # Retirement outflow, allocated by the CURRENT rural/urban split
        # (post-drift), one share computed and the other derived so they
        # always sum to exactly `outflow`.
        total_geo = current_rural + current_urban
        rural_share_now = (current_rural / total_geo) if total_geo > 0 else 0.0
        rural_outflow = int(round(outflow * rural_share_now))
        urban_outflow = outflow - rural_outflow
        current_rural -= rural_outflow
        current_urban -= urban_outflow

        # New-graduate inflow, split by rural_grad_share; same derive-by-
        # subtraction fix.
        rural_inflow = int(inflow * rural_grad_share)
        urban_inflow = inflow - rural_inflow
        current_rural += rural_inflow
        current_urban += urban_inflow

        current_active = current_active + inflow - outflow

        rural_share_pct = (
            round((current_rural / current_active) * 100, 1)
            if current_active else 0.0
        )

        results.append({
            "Simulation_Year": year,
            "Total_Active_CNM_Workforce": current_active,
            "New_Graduate_Inflow": inflow,
            "Retirement_Outflow": outflow,
            "Urban_Practicing_CNMs": current_urban,
            "Rural_Practicing_CNMs": current_rural,
            # Numeric, not a formatted "13.8%" string: a CSV column is a data
            # contract, and a percent-formatted string forces every consumer
            # to parse it back into a number before it is usable (see
            # test_cycle24 SEM2). The published quantity is unchanged.
            "Rural_Workforce_Share_Pct": rural_share_pct,
            "Projected_Births_Attended": int(current_active * births_per_cnm),
        })
    return results


def _load_initial_workforce(v4_file):
    active_midwives = []
    with open(v4_file, "r", encoding="utf-8", errors="ignore") as f:
        reader = csv.DictReader(f)
        for r in reader:
            active_midwives.append(r)
    return len(active_midwives)


def main():
    print("=== Running National Midwifery Workforce Microsimulation (2026-2040) ===")

    v4_file = "artifacts/cohort_midwives_tier1_tier2_bon_validated.csv"
    initial_workforce = _load_initial_workforce(v4_file)

    projection_results = project_workforce(initial_workforce)
    current_active = projection_results[-1]["Total_Active_CNM_Workforce"]

    out_csv = "artifacts/midwifery_microsimulation_projections_2026_2040.csv"
    with open(out_csv, "w", encoding="utf-8", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=list(projection_results[0].keys()))
        writer.writeheader()
        writer.writerows(projection_results)

    print(f"\n=========================================================================")
    print(f"  MIDWIFERY WORKFORCE MICROSIMULATION COMPLETE (2026-2040)")
    print(f"  2026 Baseline Active CNMs  : {initial_workforce:,}")
    print(f"  2040 Projected Active CNMs : {current_active:,} (+{((current_active-initial_workforce)/initial_workforce)*100:.1f}%)")
    print(f"  2040 Projected Annual Births: {int(current_active * BIRTHS_PER_CNM):,} Births Attended/Year")
    print(f"  Written to: {out_csv}")
    print(f"=========================================================================")


if __name__ == "__main__":
    main()
