#!/usr/bin/env Rscript
# =============================================================================
# Sweep Healthgrades profile enrichment to completion
# =============================================================================
# enrich_healthgrades_profiles.R::main() snapshots its target list once, at
# startup. That is correct for a single pass but wrong while the stage 1 roster
# crawl is still running: every URL stage 1 discovers after stage 2 started is
# invisible to that invocation. Left alone, healthgrades_profile_attrs.csv ends
# up partially enriched while LOOKING complete -- the failure mode where a
# Table 1 "Unknown" row quietly means "we never fetched it" rather than
# "Healthgrades does not publish it".
#
# This driver closes that gap by calling main() repeatedly. Each call re-reads
# healthgrades_midwives.csv, so each call sees the URLs stage 1 has produced
# since the last one. It exits only when stage 1 is gone AND a full pass adds
# nothing.
#
# TERMINATION. Every attempted URL is written into the checkpoint whatever
# happens -- ok, fetch_failed, or error -- so a permanently broken URL is
# retried at most once and then leaves the todo set forever. The loop cannot
# spin on it. MAX_HOURS is a backstop against stage 1 hanging without dying,
# not the expected exit path.
#
# CONCURRENCY. Two enrichers sharing one checkpoint file would double-fetch and
# race: both hold the full result list in memory and write it whole, so the
# slower writer silently reverts the faster one's work. This waits for any
# existing enricher to finish rather than adding a second.
#
# Usage:  nohup Rscript sweep_healthgrades_enrichment.R > hg_sweep.out 2>&1 &
# =============================================================================

POLL_SEC  <- as.numeric(Sys.getenv("HG_SWEEP_POLL", "300"))
MAX_HOURS <- as.numeric(Sys.getenv("HG_SWEEP_MAX_HOURS", "36"))

say <- function(...) {
  cat(sprintf("[%s] %s\n", format(Sys.time(), "%Y-%m-%d %H:%M:%S"), sprintf(...)))
  flush.console()
}

#' Is a pipeline stage running?
#'
#' Matched on the `file=` argument rather than the script name: Rscript execs
#' `R --no-echo --file=<script>`, so the word "Rscript" is absent from the
#' process the crawl actually runs under.
#'
#' The leading `--` is deliberately NOT in the pattern. pgrep parses an
#' argument beginning with `--` as an option and exits 2 without searching,
#' which reads as "not running" and would send this driver off to enrich in
#' parallel with a live enricher -- the exact race the wait exists to prevent.
#' The bracket keeps pgrep from matching this process's own argv.
#'
#' @param stage [character(1)]: "scrape" or "enrich".
#' @return [logical(1)]
stage_running <- function(stage) {
  pat <- sprintf("file=%s[%s]", substr(stage, 1, nchar(stage) - 1),
                 substr(stage, nchar(stage), nchar(stage)))
  out <- suppressWarnings(system2("pgrep", c("-f", shQuote(pat)),
                                  stdout = TRUE, stderr = FALSE))
  # A usage error must never be read as "absent"; fail loudly instead.
  st <- attr(out, "status")
  if (!is.null(st) && st > 1L) {
    stop(sprintf("pgrep failed (status %d) for pattern '%s'", st, pat),
         call. = FALSE)
  }
  length(out) > 0
}

# ---- wait out the enricher that is already running -------------------------
if (stage_running("enrich")) {
  say("an enricher is already running; waiting for it rather than racing it")
  while (stage_running("enrich")) Sys.sleep(POLL_SEC)
  say("prior enricher exited")
}

suppressPackageStartupMessages({library(dplyr); library(readr)})
source("enrich_healthgrades_profiles.R")   # entry point is sys.nframe()-guarded

#' Count URLs stage 1 has published that stage 2 has not yet attempted
#' @return [integer(1)]
pending <- function() {
  if (!file.exists(HITS)) return(0L)
  tgt <- read_csv(HITS, show_col_types = FALSE, progress = FALSE) %>%
    filter(hg_status == "ok", !is.na(hg_url)) %>%
    distinct(hg_url) %>%
    pull(hg_url)
  done <- if (file.exists(CHECKPOINT)) names(readRDS(CHECKPOINT)) else character(0)
  length(setdiff(tgt, done))
}

deadline <- Sys.time() + MAX_HOURS * 3600
pass <- 0L

repeat {
  n <- pending()
  s1 <- stage_running("scrape")
  say("pass %d: %d URL(s) pending | stage 1 %s", pass + 1L, n,
      if (s1) "still crawling" else "finished")

  if (n > 0) {
    pass <- pass + 1L
    main()
  } else if (!s1) {
    say("nothing pending and stage 1 is done -- enrichment complete")
    break
  }

  if (Sys.time() > deadline) {
    say("STOPPING: hit the %g-hour backstop with %d URL(s) still pending.",
        MAX_HOURS, pending())
    say("Stage 1 never exited. Check it, then re-run this sweep; the")
    say("checkpoint means it resumes rather than refetching.")
    break
  }

  if (n == 0 && s1) Sys.sleep(POLL_SEC)   # idle only while waiting on stage 1
}

# ---- report what is actually usable ----------------------------------------
# Coverage is reported against the ACTIVE cohort, not against profiles fetched.
# A field can be 95% complete among profiles and still describe a third of the
# cohort, because most of the loss happens upstream in the search stage.
a <- read_csv(OUTPUT, show_col_types = FALSE, progress = FALSE)
say("profiles enriched: %s", format(nrow(a), big.mark = ","))

ACTIVE_COHORT <- 11913L
hits <- read_csv(HITS, show_col_types = FALSE, progress = FALSE)
linked <- hits %>%
  filter(hg_status == "ok", !is.na(hg_url)) %>%
  distinct(certification_number, hg_url)
say("certificants with a profile: %s of %s ACTIVE (%.1f%%)",
    format(n_distinct(linked$certification_number), big.mark = ","),
    format(ACTIVE_COHORT, big.mark = ","),
    100 * n_distinct(linked$certification_number) / ACTIVE_COHORT)

per_cert <- linked %>% left_join(a, by = "hg_url")
cat("\nfield                     of profiles    of ACTIVE cohort\n")
for (v in c("hg_gender", "hg_age", "hg_years_experience", "hg_languages",
            "hg_accepts_new_patients", "hg_has_telehealth", "hg_medicaid_named")) {
  if (!v %in% names(a)) { cat(sprintf("  %-24s COLUMN ABSENT\n", v)); next }
  n_cert <- n_distinct(per_cert$certification_number[!is.na(per_cert[[v]])])
  cat(sprintf("  %-24s %5d (%3.0f%%)   %5d (%3.0f%%)\n",
              v, sum(!is.na(a[[v]])), 100 * sum(!is.na(a[[v]])) / max(nrow(a), 1),
              n_cert, 100 * n_cert / ACTIVE_COHORT))
}

# A URL claimed by more than one certificant cannot be attributed to either.
dup <- linked %>% count(hg_url) %>% filter(n > 1)
if (nrow(dup)) {
  cat(sprintf("\nAMBIGUOUS: %d profile URL(s) map to >1 certificant (%d links).\n",
              nrow(dup), sum(dup$n)))
  cat("Those certificants must not receive these fields; resolve or drop them.\n")
} else {
  cat("\nNo profile URL maps to more than one certificant.\n")
}
