#!/usr/bin/env Rscript
# =============================================================================
# State-level CNM/CM scope-of-practice classification, 2012-2016
# =============================================================================
# Source: Ranchoff BM, Declercq ER. "The Scope of Midwifery Practice
# Regulations and the Availability of the Certified Nurse-Midwife/Certified
# Midwife Workforce". J Midwifery Womens Health. 2020;65(1):119-130. Table 1
# (p.122, continuous 2012-2016 classification) and Table 3 (p.124-125, 2016
# single-year snapshot, which resolves the 6 states whose law changed
# mid-window to their end-of-window status).
#
# DEFINITIONS (verbatim from the paper):
#   Autonomous            "not requiring a legal written collaborative
#                          agreement with a physician or physician
#                          supervision"
#   Collaborative_supervisory   state laws requiring "a written collaborative
#                          agreement with physician (that may apply to
#                          clinical practice or may be limited to prescriptive
#                          authority), or laws the[sic] specify supervision by
#                          a physician"
#
# TWO CLASSIFICATIONS, KEPT SEPARATE ON PURPOSE. `practice_authority_continuous`
# reproduces Table 1 exactly: the 6 states whose law changed during 2012-2016
# are "changed" rather than forced into one bucket, matching how Ranchoff &
# Declercq's own bivariate comparison excludes them. `practice_authority_2016`
# resolves those 6 to their status at the END of the window (Table 3's
# single-year snapshot), giving a complete 50-state+DC classification with no
# excluded rows -- the one to use for a join that needs every state
# represented. Collapsing the two into one column would silently pick a side
# on a methodological choice the source paper deliberately kept open.
#
# Count check (asserted below, not just claimed): 20 autonomous + DC + 24
# collaborative + 6 changed = 51 jurisdictions. The paper's own abstract states
# these exact three counts.
#
# Output: artifacts/state_scope_of_practice.csv
# =============================================================================

suppressPackageStartupMessages({library(tibble); library(dplyr); library(readr)})
source(file.path("R", "lib", "artifact_provenance.R"))

CONTINUOUS_AUTONOMOUS <- c("AK","AZ","CO","CT","DC","ID","IA","ME","MD","MN",
                          "MT","NH","NM","NY","ND","OR","RI","UT","VT","WA","WY")
CONTINUOUS_COLLABORATIVE <- c("AL","AR","CA","DE","FL","GA","IL","IN","KS","KY",
                             "LA","MS","MO","NE","NC","OH","OK","PA","SC","SD",
                             "TN","TX","VA","WI")
# Changed law during 2012-2016; 2016_status is each state's resolved status at
# the end of the window per Table 3, not an average of what it was at points
# in between.
CHANGED <- tribble(
  ~state, ~changed_from,           ~changed_to,             ~year_changed, ~status_2016,
  "HI",   "Collaborative_supervisory", "Autonomous",         2013L,         "Autonomous",
  "MA",   "Collaborative_supervisory", "Autonomous",         2013L,         "Autonomous",
  "NV",   "Collaborative_supervisory", "Autonomous",         2013L,         "Autonomous",
  "WV",   "Collaborative_supervisory", "Autonomous",         2016L,         "Autonomous",
  "NJ",   "Autonomous",                "Collaborative_supervisory (2015) -> Autonomous (2016)",
          2016L,                       "Autonomous",
  "MI",   "Autonomous",                "Collaborative_supervisory",         2014L,         "Collaborative_supervisory"
)

stopifnot(length(CONTINUOUS_AUTONOMOUS) == 21L,   # 20 states + DC
          length(CONTINUOUS_COLLABORATIVE) == 24L,
          nrow(CHANGED) == 6L,
          length(CONTINUOUS_AUTONOMOUS) + length(CONTINUOUS_COLLABORATIVE) + nrow(CHANGED) == 51L)

out <- bind_rows(
  tibble(state = CONTINUOUS_AUTONOMOUS,
        practice_authority_continuous = "Autonomous",
        practice_authority_2016 = "Autonomous"),
  tibble(state = CONTINUOUS_COLLABORATIVE,
        practice_authority_continuous = "Collaborative_supervisory",
        practice_authority_2016 = "Collaborative_supervisory"),
  tibble(state = CHANGED$state,
        practice_authority_continuous = "Changed_during_window_excluded",
        practice_authority_2016 = CHANGED$status_2016)
) %>% arrange(state)

stopifnot(nrow(out) == 51L, !anyDuplicated(out$state))

write_with_provenance(out, "artifacts/state_scope_of_practice.csv",
                      inputs = character(0))
cat(sprintf("wrote artifacts/state_scope_of_practice.csv (%d jurisdictions)\n", nrow(out)))
cat(sprintf("  continuous: %d autonomous, %d collaborative, %d excluded (changed mid-window)\n",
            sum(out$practice_authority_continuous == "Autonomous"),
            sum(out$practice_authority_continuous == "Collaborative_supervisory"),
            sum(out$practice_authority_continuous == "Changed_during_window_excluded")))
cat(sprintf("  2016 snapshot: %d autonomous, %d collaborative\n",
            sum(out$practice_authority_2016 == "Autonomous"),
            sum(out$practice_authority_2016 == "Collaborative_supervisory")))
