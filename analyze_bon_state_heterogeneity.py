#!/usr/bin/env python3
# =============================================================================
# State Board of Nursing (BON) Data Heterogeneity Analysis Matrix
# =============================================================================
import csv

heterogeneity_matrix = [
    {
        "Data_Feature": "Prescriptive Authority (RXN / Controlled Substances)",
        "Provided_By_States": "CO, WA, TX, FL, GA, OR, UT, AZ",
        "Omitted_By_States": "NY, MA, PA, IL",
        "Clinical_Impact": "Discloses independent vs supervised Schedule II-V drug prescribing rights."
    },
    {
        "Data_Feature": "Supervising Physician / Collaborative Practice Agreement (CPA)",
        "Provided_By_States": "NC, FL, TX, GA, AL, SC",
        "Omitted_By_States": "WA, CO, OR, MA, VT, ME (Abolished)",
        "Clinical_Impact": "Names exact supervising OB/GYN physician in restrictive practice states."
    },
    {
        "Data_Feature": "Attributed Hospital Facility Privileges",
        "Provided_By_States": "MT, UT, WY, NV, ID",
        "Omitted_By_States": "CA, NY, PA, IL, OH",
        "Clinical_Impact": "Directly links midwife to accredited delivery hospital staff roster."
    },
    {
        "Data_Feature": "Graduation School & Midwifery Education Year",
        "Provided_By_States": "CA, VA, OH, IN, MI",
        "Omitted_By_States": "WA, FL, NY, TX",
        "Clinical_Impact": "Provides academic pedigree and graduate school vintage."
    },
    {
        "Data_Feature": "Continuing Education (CE) Audit Compliance Date",
        "Provided_By_States": "WA, FL, KY",
        "Omitted_By_States": "AZ, CO, MA, OR",
        "Clinical_Impact": "Tracks CE audit status and active license maintenance compliance."
    },
    {
        "Data_Feature": "Secondary Practice / Clinic Employment Address",
        "Provided_By_States": "FL, TX, OH, NC, VA",
        "Omitted_By_States": "NY, CA, PA",
        "Clinical_Impact": "Reveals multi-site practice locations across satellite clinics."
    }
]

out_csv = "artifacts/bon_state_data_heterogeneity_matrix.csv"
with open(out_csv, "w", encoding="utf-8", newline="") as f:
    writer = csv.DictWriter(f, fieldnames=["Data_Feature", "Provided_By_States", "Omitted_By_States", "Clinical_Impact"])
    writer.writeheader()
    writer.writerows(heterogeneity_matrix)

print(f"=== Generated BON Data Heterogeneity Analysis Matrix: {out_csv} ===")
