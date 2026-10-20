#!/usr/bin/env Rscript
# =============================================================================
# Attanasio Claims Linkage & State Birth Certificate Attender Research Engine
# =============================================================================
suppressPackageStartupMessages({
  library(dplyr); library(readr); library(stringr)
})

cat("=== Attanasio Claims Linkage & Birth Certificate Attender Engine ===\n\n")

# 1. Attanasio Methodology: CPT Delivery Codes for Midwife Claims Linkage
cpt_delivery_codes <- tibble::tribble(
  ~cpt_code, ~description, ~clinical_setting,
  "59400", "Routine obstetric care including antepartum, vaginal delivery, and postpartum", "Hospital / Birth Center",
  "59409", "Vaginal delivery only (with or without episiotomy)", "Hospital / Birth Center",
  "59410", "Vaginal delivery including postpartum care", "Hospital / Birth Center",
  "59510", "Routine obstetric care including antepartum, cesarean delivery, and postpartum", "Hospital",
  "59610", "Routine obstetric care including antepartum, VBAC delivery, and postpartum", "Hospital"
)

cat("1. CPT Delivery Billing Codes (Attanasio Claims Attribution Methodology):\n")
print(cpt_delivery_codes)

# 2. CDC NCHS Natality Birth Certificate Attender Variables
natality_attender_schema <- tibble::tribble(
  ~variable_name, ~field_description, ~categories_values,
  "ATTEND", "Attendant at Birth", "1=MD, 2=DO, 3=CNM (Certified Nurse Midwife), 4=Other Midwife (CPM/LM), 5=Other",
  "PAY", "Primary Source of Payment", "1=Medicaid, 2=Private Insurance, 3=Self-Pay, 4=Other",
  "FACILITY", "Birth Facility Type", "1=Hospital, 2=Freestanding Birth Center, 3=Home (Intended), 4=Home (Unintended), 5=Clinic",
  "ATTEND_NPI", "Attender NPI (Restricted Microdata)", "10-Digit National Provider Identifier (Available via NCHS RDC / NAPHSIS DUA)",
  "HOSP_CCN", "Hospital Facility ID (Restricted Microdata)", "6-Character CMS Certification Number (Available via NCHS RDC / NAPHSIS DUA)"
)

cat("\n2. CDC NCHS Natality Birth Certificate Microdata Schema:\n")
print(natality_attender_schema)

# 3. R Code Template for Reading CDC Natality Microdata (ipumsr / readr)
r_code_template <- '
# Load Natality Microdata using R ipumsr or readr
library(ipumsr)
library(dplyr)

# Read IPUMS / NCHS Natality Microdata
# micro_df <- read_ipums_micro("usa_natality_microdata.xml")

# Filter for Midwife-Attended Deliveries by Payer & Setting
# midwife_deliveries <- micro_df %>%
#   filter(ATTEND %in% c(3, 4)) %>%  # 3 = CNM, 4 = Other Midwife
#   group_by(FACILITY, PAY) %>%
#   summarise(n_deliveries = n(), .groups = "drop")
'

cat("\n3. R Code Framework for Processing CDC Birth Certificate Microdata:\n")
cat(r_code_template)
