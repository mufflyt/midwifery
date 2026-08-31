#!/usr/bin/env Rscript
# =============================================================================
# Adversarial loop, cycle 29 (session-cycle 6 of 24) -- 3 BVA / 3 semantic / 4 adversarial
# =============================================================================
# Target: the OSM.de routing calibration/queue scripts -- calibrate_osmde_
# vs_ec2.R (feeds "the paper" per its own comment) and build_osmde_route_
# queue_all_midwives.R. Same underlying RNG-reproducibility root cause as
# cycle 27 (resolve_org_ambiguity.R), but manifesting through TWO genuinely
# different mechanisms: a single GROUPED slice_sample() call (not several
# sequential calls), and a full-table shuffle whose row-order safety turned
# out to be an incidental property of summarise(), not a documented one.
# Neither file had any prior tests.
suppressPackageStartupMessages(library(dplyr))

fails <- 0L
chk <- function(cond, m) {
  if (isTRUE(cond)) cat(sprintf("  ok   %s\n", m))
  else { fails <<- fails + 1L; cat(sprintf("  FAIL %s\n", m)) }
}

N_PER <- 5L

# Mirrors the FIXED calibrate_osmde_vs_ec2.R sampling exactly.
c29_sample_strata_fixed <- function(origins) {
  origins %>%
    filter(!is.na(rurality)) %>%
    {split(., .$rurality)} %>%
    lapply(function(d) {
      set.seed(20260808)
      d %>% arrange(location_key) %>% slice_sample(n = min(N_PER, nrow(d)))
    }) %>%
    bind_rows()
}

# The RETIRED pattern: one set.seed(), then a single grouped slice_sample().
c29_sample_strata_retired <- function(origins) {
  set.seed(20260808)
  origins %>% group_by(rurality) %>% slice_sample(n = min(N_PER, min(table(origins$rurality)))) %>% ungroup()
}

mk_origins <- function(n_rural, n_urban, shuffle = FALSE) {
  d <- bind_rows(
    data.frame(location_key = sprintf("rural_%04d", seq_len(n_rural)), rurality = "rural"),
    data.frame(location_key = sprintf("urban_%04d", seq_len(n_urban)), rurality = "urban")
  )
  if (shuffle) d <- d[sample(nrow(d)), , drop = FALSE]
  d
}

cat("\n-- BVA --\n")

small <- mk_origins(3, 200)
r_small <- c29_sample_strata_fixed(small)
chk(sum(r_small$rurality == "rural") == 3L,
    "T29-1: a stratum smaller than N_PER returns exactly its own count, not N_PER")

exact <- mk_origins(N_PER, 200)
r_exact <- c29_sample_strata_fixed(exact)
chk(sum(r_exact$rurality == "rural") == N_PER,
    "T29-2: a stratum with exactly N_PER rows returns all of them (cap boundary)")

g1 <- data.frame(location_key = c("C", "A", "B"), v = 1:3)
g2 <- g1[c(3, 1, 2), , drop = FALSE]
s1 <- g1 %>% group_by(location_key) %>% summarise(v = first(v), .groups = "drop")
s2 <- g2 %>% group_by(location_key) %>% summarise(v = first(v), .groups = "drop")
chk(identical(s1$location_key, s2$location_key),
    "T29-3: group_by()+summarise() sorts by group key regardless of input row order (the property build_osmde_route_queue's shuffle safety depends on)")

cat("\n-- semantic --\n")

set.seed(1); r1 <- c29_sample_strata_fixed(mk_origins(50, 200))
set.seed(1); r2 <- c29_sample_strata_fixed(mk_origins(80, 200))
chk(identical(sort(r1$location_key[r1$rurality == "urban"]),
              sort(r2$location_key[r2$rurality == "urban"])),
    "T29-4: the urban stratum's sample is unaffected by the UNRELATED rural stratum growing from 50 to 80 rows")

ordered_o  <- mk_origins(50, 60)
shuffled_o <- mk_origins(50, 60, shuffle = TRUE)
ru1 <- c29_sample_strata_fixed(ordered_o)
ru2 <- c29_sample_strata_fixed(shuffled_o)
chk(setequal(ru1$location_key[ru1$rurality == "urban"], ru2$location_key[ru2$rurality == "urban"]),
    "T29-5: identical stratum content in a different row order selects the same actual locations")

geo_ordered  <- data.frame(location_key = rep(c("X", "Y", "Z"), each = 2), latitude = 1:6)
geo_shuffled <- geo_ordered[sample(nrow(geo_ordered)), , drop = FALSE]
build_queue <- function(geo) {
  geo %>% group_by(location_key) %>%
    summarise(latitude = first(latitude), .groups = "drop") %>%
    arrange(location_key) %>%
    { set.seed(1); slice_sample(., prop = 1) }
}
chk(identical(build_queue(geo_ordered)$location_key, build_queue(geo_shuffled)$location_key),
    "T29-6: the queue-builder's final shuffled order is identical regardless of the upstream geo table's row order")

cat("\n-- adversarial --\n")

set.seed(1); rr1 <- c29_sample_strata_retired(mk_origins(50, 200))
set.seed(1); rr2 <- c29_sample_strata_retired(mk_origins(80, 200))
chk(!identical(sort(rr1$location_key[rr1$rurality == "urban"]),
               sort(rr2$location_key[rr2$rurality == "urban"])),
    "T29-7 (anti-ceremony): the RETIRED single grouped slice_sample() DOES let urban's sample change when rural's size changes -- confirms T29-4 discriminates")

ru1r <- c29_sample_strata_retired(ordered_o)
ru2r <- c29_sample_strata_retired(shuffled_o)
chk(!setequal(ru1r$location_key[ru1r$rurality == "urban"], ru2r$location_key[ru2r$rurality == "urban"]),
    "T29-8 (anti-ceremony): the RETIRED pattern is also row-order dependent -- confirms T29-5 discriminates")

src_lines_all <- readLines("calibrate_osmde_vs_ec2.R", warn = FALSE)
src_lines <- src_lines_all[!grepl("^\\s*#", src_lines_all)]
slice_idx <- grep("slice_sample\\(", src_lines)
chk(length(slice_idx) == 1L,
    sprintf("T29-9 setup: exactly 1 slice_sample() call site in calibrate_osmde_vs_ec2.R production code (got %d)", length(slice_idx)))
window <- src_lines[max(1, slice_idx[1] - 3):slice_idx[1]]
chk(any(grepl("set\\.seed\\(20260808\\)", window)) && any(grepl("arrange\\(location_key\\)", window)),
    "T29-9: the slice_sample() call is preceded by both set.seed(20260808) and arrange(location_key)")

plain_distinct <- function(geo) geo %>% distinct(location_key, .keep_all = TRUE)
chk(!identical(plain_distinct(geo_ordered)$location_key, plain_distinct(geo_shuffled)$location_key),
    "T29-10: unlike summarise(), a plain distinct(location_key, .keep_all=TRUE) does NOT sort by key and IS order-dependent -- the queue-builder's safety was an incidental property of summarise(), not a guaranteed one, which is why arrange() was added explicitly")

cat(sprintf("\n%s (%d failures)\n", if (fails == 0L) "PASS" else "FAIL", fails))
quit(status = if (fails == 0L) 0L else 1L)
