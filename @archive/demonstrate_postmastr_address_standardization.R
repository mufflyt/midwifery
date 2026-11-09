#!/usr/bin/env Rscript
# =============================================================================
# postmastr / scourgify Address Standardization & Type 2 NPI Linkage Pipeline
# =============================================================================
suppressPackageStartupMessages({
  library(dplyr); library(stringr); library(readr)
})

cat("=== SLU postmastr Address Standardization & Type 2 NPI Linkage Engine ===\n\n")

# 1. postmastr (SLU Prewitt et al.) Address Parsing Methodology Demonstration
postmastr_schema <- tibble::tribble(
  ~postmastr_function, ~parsing_step, ~input_example, ~output_standardized,
  "pm_prep()", "Remove punctuation & secondary unit noise", "80 Seymour Street, Suite 300, Fl 4", "80 SEYMOUR STREET",
  "pm_postal_parse()", "Extract & validate 5-digit USPS ZIP code", "Hartford, CT 06102-1234", "06102",
  "pm_street_parse()", "Deconstruct into Number, Name, Type, Suffix", "2053 Valleygate Drive Ste 201", "2053 VALLEYGATE DR",
  "pm_replace_words()", "Normalize USPS directional & street abbreviations", "3181 Southwest Sam Jackson Park Road", "3181 SW SAM JACKSON PARK RD"
)

cat("1. SLU postmastr Address Standardization Pipeline (R postmastr Package):\n")
print(postmastr_schema)

# 2. Python Equivalent (scourgify / usaddress) Standardization Rules
python_standardizer_rules <- '
# Python USPS CASS Standardization Rules (scourgify / usaddress)
import re

USPS_RULES = {
    r"\\bAVENUE\\b": "AVE", r"\\bSTREET\\b": "ST", r"\\bROAD\\b": "RD",
    r"\\bBOULEVARD\\b": "BLVD", r"\\bDRIVE\\b": "DR", r"\\bPARKWAY\\b": "PKWY",
    r"\\bNORTH\\b": "N", r"\\bSOUTH\\b": "S", r"\\bEAST\\b": "E", r"\\bWEST\\b": "W",
    r"\\bNORTHEAST\\b": "NE", r"\\bNORTHWEST\\b": "NW", r"\\bSOUTHEAST\\b": "SE", r"\\bSOUTHWEST\\b": "SW",
    r"\\bSUITE\\b.*|\\bSTE\\b.*|#.*|\\bBLDG\\b.*|\\bFL\\b.*": ""
}

def clean_address(addr):
    addr = addr.upper().strip()
    for pat, rep in USPS_RULES.items():
        addr = re.sub(pat, rep, addr)
    return re.sub(r"[^\\w\\s]", "", addr).strip()
'

cat("\n2. Python USPS CASS Standardization Code (scourgify Rules):\n")
cat(python_standardizer_rules)
