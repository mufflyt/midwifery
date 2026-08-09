#!/usr/bin/env Rscript
# =============================================================================
# State obstetric workforce composition: general OB/GYN + midwives, MFM apart
# =============================================================================
# Aggregated from the 118th-district artifact so the provider definitions,
# geocode provenance, and ACS denominators are identical to the district
# products -- recomputing from source would risk the two disagreeing.
#
# birth_attendants = general OB/GYN + midwives, the workforce attending routine
# births. MFM is the referral tier and is reported in its own columns, never
# summed in. Non-intrapartum subspecialties are excluded entirely.
# =============================================================================
suppressPackageStartupMessages({library(dplyr); library(readr)})
d <- read_csv("artifacts/cd_midwifery_stats.csv", show_col_types = FALSE)

st <- d %>% group_by(state) %>%
  summarise(districts = n(),
            midwives = sum(n_midwife),
            general_obgyn = sum(n_general_obgyn),
            mfm = sum(n_mfm),
            births = sum(acs_births, na.rm = TRUE),
            birth_attendants = sum(n_midwife) + sum(n_general_obgyn),
            # Geocode quality carried forward: a state leaning on centroids has
            # weaker within-state geography, even though its total is sound.
            generalist_city_centroid = sum(n_general_obgyn_city_centroid),
            .groups = "drop") %>%
  mutate(pct_generalist_city_centroid =
           round(100 * generalist_city_centroid / pmax(general_obgyn, 1), 1),
         midwives_per_1k_births = round(1000 * midwives / pmax(births, 1), 2),
         general_obgyn_per_1k_births = round(1000 * general_obgyn / pmax(births, 1), 2),
         mfm_per_1k_births = round(1000 * mfm / pmax(births, 1), 2),
         attendants_per_1k_births = round(1000 * birth_attendants / pmax(births, 1), 2),
         midwife_share_of_attendants = round(midwives / pmax(birth_attendants, 1), 3),
         midwives_per_general_obgyn = round(midwives / pmax(general_obgyn, 1), 2)) %>%
  arrange(desc(births))

cat("=========== STATE OBSTETRIC WORKFORCE (top 15 by births) ===========\n")
print(as.data.frame(st %>% select(state, births, midwives, general_obgyn, mfm,
                                  midwives_per_1k_births, midwife_share_of_attendants,
                                  midwives_per_general_obgyn) %>% head(15)),
      row.names = FALSE)

cat("\n=========== MIDWIFE SHARE OF ROUTINE ATTENDANTS: extremes ===========\n")
big <- st %>% filter(births >= 20000)
cat("highest 8 (states with >=20,000 births):\n")
print(as.data.frame(big %>% arrange(desc(midwife_share_of_attendants)) %>%
  select(state, births, midwives, general_obgyn, midwife_share_of_attendants) %>%
  head(8)), row.names = FALSE)
cat("\nlowest 8:\n")
print(as.data.frame(big %>% arrange(midwife_share_of_attendants) %>%
  select(state, births, midwives, general_obgyn, midwife_share_of_attendants) %>%
  head(8)), row.names = FALSE)

cat("\n=========== MFM REFERRAL CAPACITY (reported separately) ===========\n")
print(as.data.frame(st %>% arrange(desc(births)) %>%
  select(state, births, mfm, mfm_per_1k_births) %>% head(10)), row.names = FALSE)

write_csv(st, "artifacts/state_obstetric_workforce.csv", na = "")
cat("\nwritten: artifacts/state_obstetric_workforce.csv\n")
