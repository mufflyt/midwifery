#!/usr/bin/env Rscript
# =============================================================================
# Second pass over matched Healthgrades profiles: person-level attributes
# =============================================================================
#
# scrape_healthgrades_midwives.R read only the JSON-LD block, which carries
# address, specialty and NPI. Gender, age, rating and verification date live in
# the Next.js flight payload on the same page and were discarded. This pass
# re-fetches the profiles that already matched and runs parse_next_flight()
# over them.
#
# Scope: the distinct hg_url of hg_status == "ok" rows only -- roughly 870
# pages against 5,933 for the original crawl. Attributes are PERSON-level, so
# a midwife with four practice sites is fetched once, not four times.
#
# Inputs : healthgrades_midwives.csv
# Outputs: healthgrades_profile_attrs.csv, healthgrades_attrs_checkpoint.rds,
#          healthgrades_attrs_log.txt
#
# Usage  : Rscript enrich_healthgrades_profiles.R [n_to_fetch]
#          Resumes from the checkpoint; pass a count to run a bounded batch.
# =============================================================================

suppressPackageStartupMessages({
  library(dplyr); library(readr); library(tibble); library(stringr)
})

# Reuse the canonical fetch/parse helpers rather than restating them. The
# scraper's `if (sys.nframe() == 0)` guard keeps sourcing from starting a crawl.
source("scrape_healthgrades_midwives.R")

HITS        <- "healthgrades_midwives.csv"
OUTPUT      <- "healthgrades_profile_attrs.csv"
CHECKPOINT  <- "healthgrades_attrs_checkpoint.rds"
# CKPT_EVERY chosen 2026-08-16 after tests/test_recovery_resume_equivalence.R
# (E4) demonstrated a LIVELOCK: a job that dies before it ever checkpoints
# makes zero progress and repeats the same work forever. At the old value of
# 25, with DELAY_SEC = 2, that window was ~50 seconds -- so anything killing
# the job more often than once a minute (a rate-limit ban, a dropped
# connection, a sleeping laptop) left it re-fetching the same 25 profiles
# indefinitely.
#
# 10 halves-and-then-some the exposure (~20s) at 2,230 writes per full roster
# rather than 892. NOT lowered to 5, which would have been ~10s: the output is
# 3.4 MB and is rewritten WHOLLY on every checkpoint via a plain write_csv(),
# with no temp-file-and-rename, so each additional write is another chance to
# be interrupted mid-write and leave a torn CSV. Buying 10 more seconds of
# livelock protection for 5x the torn-write exposure is the wrong trade until
# the write is made atomic. See DEBT.md.
CKPT_EVERY  <- 10L

# log_message() writes to LOG_FILE from the sourced scraper; repoint it so this
# pass does not interleave into the original crawl's log.
LOG_FILE <- "healthgrades_attrs_log.txt"

#' Fetch one profile and parse its person-level attributes
#'
#' @param url [character(1)]: relative /providers/ path.
#' @return [tibble] one row: hg_url, hg_attr_status, plus parse_next_flight().
enrich_one <- function(url) {
  log_message(url)
  html <- fetch(paste0("https://www.healthgrades.com", url))
  if (is.na(html)) {
    return(tibble(hg_url = url, hg_attr_status = "fetch_failed"))
  }
  bind_cols(tibble(hg_url = url, hg_attr_status = "ok"), parse_next_flight(html))
}

main <- function(n_limit = NA_integer_) {
  stopifnot(file.exists(HITS))

  # One fetch per PERSON. hg_url is the person key here; certification_number
  # repeats across practice sites and would multiply the crawl fourfold.
  targets <- read_csv(HITS, show_col_types = FALSE) %>%
    filter(hg_status == "ok", !is.na(hg_url)) %>%
    distinct(hg_url) %>%
    pull(hg_url)

  done <- if (file.exists(CHECKPOINT)) readRDS(CHECKPOINT) else list()
  todo <- setdiff(targets, names(done))
  if (!is.na(n_limit)) todo <- head(todo, n_limit)

  log_message(sprintf("profiles=%d already_done=%d this_run=%d delay=%ss",
                      length(targets), length(done), length(todo), DELAY_SEC))

  for (i in seq_along(todo)) {
    u <- todo[i]
    res <- tryCatch(enrich_one(u), error = function(e) {
      log_message(paste("  ERROR:", e$message))
      tibble(hg_url = u, hg_attr_status = "error")
    })
    done[[u]] <- res

    if (i %% CKPT_EVERY == 0 || i == length(todo)) {
      saveRDS(done, CHECKPOINT)
      write_csv(bind_rows(done), OUTPUT, na = "")
      log_message(sprintf("  checkpoint %d/%d -> %s", i, length(todo), OUTPUT))
    }
  }

  out <- bind_rows(done)
  write_csv(out, OUTPUT, na = "")

  ok <- filter(out, hg_attr_status == "ok")
  log_message("--- fill rates (of parsed profiles) ---")
  log_message(sprintf("profiles parsed        : %d", nrow(ok)))
  if (nrow(ok) > 0) {
    fill <- function(col) sum(!is.na(ok[[col]]))
    for (v in c("hg_gender", "hg_age", "hg_years_experience",
                "hg_education_year", "hg_languages", "hg_board_certs",
                "hg_rating", "hg_verified_date")) {
      log_message(sprintf("  %-22s %4d (%.0f%%)", v, fill(v),
                          100 * fill(v) / nrow(ok)))
    }
    log_message("--- gender ---")
    g <- count(ok, hg_gender)
    for (j in seq_len(nrow(g))) {
      log_message(sprintf("  %-4s %d", g$hg_gender[j] %||% "NA", g$n[j]))
    }
    a <- ok$hg_age[!is.na(ok$hg_age)]
    if (length(a) > 0) {
      log_message(sprintf("age: n=%d median=%.0f IQR=%.0f-%.0f range=%d-%d",
                          length(a), median(a), quantile(a, .25),
                          quantile(a, .75), min(a), max(a)))
    }
  }
  invisible(out)
}

if (sys.nframe() == 0) {
  a <- commandArgs(trailingOnly = TRUE)
  main(if (length(a) > 0) as.integer(a[1]) else NA_integer_)
}
