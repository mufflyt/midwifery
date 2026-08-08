#!/usr/bin/env Rscript
# =============================================================================
# Scrape Healthgrades for practice addresses of unmatched AMCB midwives
# =============================================================================
#
# Target: midwives_unmatched.csv -- AMCB certificants with no NPI and therefore
# no address at all. Midwives who DID match NPPES already have an address; their
# problem is geocoding (geocode_queue.csv), not address discovery.
#
# Reuses the proven techniques from the isochrones physician scrapers
# (R/scrape_healthgrades_obgyn.R, R/scrape_healthgrades_locations.R):
#
#   * JSON-LD parsing -- Healthgrades embeds schema.org blocks carrying
#     streetAddress / addressLocality / addressRegion / postalCode AND
#     geo$latitude / geo$longitude. Coordinates come free, so anything found
#     here skips the geocoder entirely.
#   * NPI recovery + Luhn validation -- the NPI is NOT displayed on the page
#     but IS present in embedded JS, in a backslash-quote encoding
#     (npi\":\"1275863631). Five regex patterns catch the variants; the Luhn
#     checksum filters false positives out of a 1.7 MB page of digits. This is
#     what makes Healthgrades a MATCHING source and not merely an address
#     source.
#   * Browser headers, 2 s rate limit, checkpoint/resume, append-only log.
#
# The URL shape differs from the physician scrapers: midwives live at
# /providers/{slug}, not /physician/dr-{slug}.
#
# Inputs : midwives_unmatched.csv
# Outputs: healthgrades_midwives.csv, healthgrades_checkpoint.rds,
#          healthgrades_scrape_log.txt
#
# Usage  : Rscript scrape_healthgrades_midwives.R [n_to_scrape]
#          Resumes from the checkpoint; pass a count to run a bounded batch.
# =============================================================================

suppressPackageStartupMessages({
  library(httr); library(rvest); library(jsonlite)
  library(dplyr); library(stringr); library(readr); library(tibble)
})

INPUT       <- "midwives_unmatched.csv"
OUTPUT      <- "healthgrades_midwives.csv"
CHECKPOINT  <- "healthgrades_checkpoint.rds"
LOG_FILE    <- "healthgrades_scrape_log.txt"
DELAY_SEC   <- as.numeric(Sys.getenv("HG_DELAY", "2"))
CKPT_EVERY  <- 25L

`%||%` <- function(a, b) if (is.null(a) || length(a) == 0) b else a

# Rate limiting is not decoration: Healthgrades' robots.txt sets no
# Crawl-delay but does blanket-block AI crawler user-agents, so keep request
# volume in the range a human researcher would plausibly generate.
BROWSER_HEADERS <- c(
  `User-Agent` = paste("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)",
                       "AppleWebKit/537.36 (KHTML, like Gecko)",
                       "Chrome/120.0.0.0 Safari/537.36"),
  `Accept` = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
  `Accept-Language` = "en-US,en;q=0.5",
  `Connection` = "keep-alive"
)

log_message <- function(msg) {
  line <- sprintf("[%s] %s", format(Sys.time(), "%Y-%m-%d %H:%M:%S"), msg)
  cat(line, "\n", sep = "")
  cat(line, "\n", sep = "", file = LOG_FILE, append = TRUE)
}

# --- NPI recovery (ported from scrape_healthgrades_obgyn.R) ----------------

#' Validate a 10-digit NPI with the Luhn checksum
#'
#' NPI uses Luhn over the number prefixed with 80840. Essential here: a 1.7 MB
#' page contains many 10-digit runs, and without the checksum the regexes
#' return phone numbers and internal ids as NPIs.
#'
#' @param npi [character(1)]: candidate 10-digit string.
#' @return [logical(1)] TRUE when the checksum validates.
luhn_check_npi <- function(npi) {
  if (is.na(npi) || !str_detect(npi, "^[0-9]{10}$")) return(FALSE)
  digits <- as.integer(strsplit(paste0("80840", substr(npi, 1, 9)), "")[[1]])
  digits <- rev(digits)
  odd <- seq(1, length(digits), by = 2)
  digits[odd] <- digits[odd] * 2
  digits[digits > 9] <- digits[digits > 9] - 9
  check <- (10 - (sum(digits) %% 10)) %% 10
  check == as.integer(substr(npi, 10, 10))
}

#' Pull a Luhn-valid NPI out of raw profile HTML
#'
#' @param content [character(1)]: raw page HTML.
#' @return [character(1)] the NPI, or NA when none validates.
extract_npi_from_html <- function(content) {
  if (is.null(content) || is.na(content) || nchar(content) == 0) {
    return(NA_character_)
  }
  candidates <- c()
  pat <- c('data-npi=["\']([0-9]{10})["\']',
           '"npi"\\s*:\\s*"([0-9]{10})"',
           'NPI[:\\s#]*([0-9]{10})',
           '"npi"\\s*:\\s*([0-9]{10})(?=[^0-9])',
           # Healthgrades embeds npi\":\"1234567890 -- literal backslash-quote,
           # so neither of the quoted patterns above matches it.
           'npi[^0-9]{1,10}([0-9]{10})')
  for (p in pat) {
    m <- str_match_all(content, p)[[1]]
    if (nrow(m) > 0) candidates <- c(candidates, m[, 2])
  }
  candidates <- unique(candidates)
  for (n in candidates) if (luhn_check_npi(n)) return(n)
  NA_character_
}

# --- HTTP ------------------------------------------------------------------

fetch <- function(url) {
  Sys.sleep(DELAY_SEC)
  r <- tryCatch(GET(url, add_headers(.headers = BROWSER_HEADERS), timeout(45)),
                error = function(e) { log_message(paste("  fetch error:", e$message)); NULL })
  if (is.null(r) || status_code(r) != 200) return(NA_character_)
  content(r, "text", encoding = "UTF-8")
}

#' First whitespace token of a given-name field
#'
#' AMCB fuses middle names into first_name for 2,965 of 5,963 unmatched
#' certificants (50%): "Doris Mary", "Hope Marie", "Julie Ann". Querying
#' Healthgrades with the fused string returns nothing, so half the roster was
#' unsearchable before this. Search on the leading token only.
#'
#' @param x [character(1)]: raw first_name.
#' @return [character(1)] leading token.
given_name <- function(x) str_squish(str_extract(str_squish(x), "^[^ ]+"))

#' Find candidate /providers/ profile slugs for a name
#'
#' @param first,last [character(1)]: midwife name.
#' @param state [character(1)]: optional state to narrow the search.
#' @return [character] unique relative profile URLs, best-first.
search_midwife <- function(first, last, state = NA_character_) {
  q <- URLencode(paste(given_name(first), last, "Midwifery"))
  url <- if (!is.na(state) && nzchar(state)) {
    paste0("https://www.healthgrades.com/usearch?what=", q,
           "&where=", URLencode(state))
  } else {
    paste0("https://www.healthgrades.com/usearch?what=", q)
  }
  html <- fetch(url)
  if (is.na(html)) return(character(0))
  unique(str_extract_all(html, "/providers/[a-z0-9-]+")[[1]])
}

#' Choose the profile whose slug best matches the name
#'
#' Slug-based, so it is a weak check -- verify_profile() re-checks the name and
#' credential from the page itself before anything is written out.
pick_best_url <- function(urls, first, last) {
  if (length(urls) == 0) return(NA_character_)
  lc <- tolower(str_replace_all(last, "[^A-Za-z]", ""))
  fc <- tolower(str_replace_all(first, "[^A-Za-z]", ""))
  if (nchar(lc) == 0) return(NA_character_)
  if (nchar(fc) >= 2) {
    both <- urls[str_detect(tolower(urls), fixed(lc)) &
                   str_detect(tolower(urls), fixed(fc))]
    if (length(both) > 0) return(both[1])
  }
  only_last <- urls[str_detect(tolower(urls), fixed(lc))]
  if (length(only_last) > 0) return(only_last[1]) else NA_character_
}

#' Extract every practice location from a profile's JSON-LD blocks
#'
#' @param html [character(1)]: raw profile HTML.
#' @return [tibble] one row per location with street/city/state/zip/lat/lon.
extract_locations <- function(html) {
  blocks <- tryCatch(
    read_html(html) %>% html_nodes("script[type='application/ld+json']") %>% html_text(),
    error = function(e) character(0))

  rows <- list()
  add_node <- function(node) {
    if (is.null(node)) return(invisible(NULL))
    addr <- node$address
    if (is.null(addr) || is.null(addr$streetAddress)) return(invisible(NULL))
    geo <- node$geo
    rows[[length(rows) + 1]] <<- tibble(
      hg_practice = node$name %||% NA_character_,
      hg_street   = addr$streetAddress %||% NA_character_,
      hg_city     = addr$addressLocality %||% NA_character_,
      hg_state    = addr$addressRegion %||% NA_character_,
      hg_zip      = addr$postalCode %||% NA_character_,
      hg_lat      = as.numeric(geo$latitude %||% NA),
      hg_lon      = as.numeric(geo$longitude %||% NA)
    )
  }

  # `location` is a LIST of practice sites, not a single object -- a midwife
  # with three offices has three entries. Treating it as one object (the shape
  # the physician scrapers assumed) silently yielded zero addresses.
  add_locations <- function(node) {
    loc <- node$location
    if (is.null(loc)) return(invisible(NULL))
    if (!is.null(loc$address)) add_node(loc)          # single site
    else for (l in loc) add_node(l)                   # list of sites
  }

  for (b in blocks) {
    d <- tryCatch(fromJSON(b, simplifyVector = FALSE), error = function(e) NULL)
    if (is.null(d)) next
    add_locations(d)
    add_node(d)
    for (item in (d$`@graph` %||% list())) { add_locations(item); add_node(item) }
  }
  if (length(rows) == 0) return(tibble())
  distinct(bind_rows(rows))
}

#' Read the NPI from the JSON-LD `usNPI` field
#'
#' Cleaner than scraping embedded JS: schema.org exposes it directly. Still
#' Luhn-checked, and extract_npi_from_html() remains the fallback for pages
#' whose JSON-LD omits it.
#'
#' @param html [character(1)]: raw profile HTML.
#' @return [character(1)] NPI or NA.
extract_npi_jsonld <- function(html) {
  blocks <- tryCatch(
    read_html(html) %>% html_nodes("script[type='application/ld+json']") %>% html_text(),
    error = function(e) character(0))
  for (b in blocks) {
    d <- tryCatch(fromJSON(b, simplifyVector = FALSE), error = function(e) NULL)
    if (is.null(d)) next
    for (node in c(list(d), d$`@graph` %||% list())) {
      n <- node$usNPI %||% NA_character_
      if (!is.na(n) && luhn_check_npi(as.character(n))) return(as.character(n))
    }
  }
  NA_character_
}

#' Confirm the page really is this person, and really is a CNM/CM
#'
#' AMCB certifies CNMs and CMs only. Healthgrades also lists CPMs, LMs, NPs and
#' NDs under Midwifery, and those are a DIFFERENT credential that cannot appear
#' on the AMCB roster -- accepting them would silently import non-certificants.
#'
#' @return [list] with `ok`, `credential`, `hg_name`.
verify_profile <- function(html, first, last) {
  title <- tryCatch(read_html(html) %>% html_node("title") %>% html_text(),
                    error = function(e) NA_character_)
  hg_name <- str_squish(str_remove(title %||% "", "\\|.*$"))
  cred <- str_match(hg_name, "\\b(CNM|CM|CPM|LM|ND|NP)\\b")[1, 2]

  # BUG FIX: last-name-only verification accepted "Ann Abbott, CNM" as a match
  # for Donna Abbott -- pick_best_url() falls back to a last-name-only slug
  # match, so without a first-name check the scraper silently attributes one
  # midwife's practice address to a different midwife who shares a surname.
  # Surnames are not rare in a 22K roster; this would have contaminated the
  # output at scale.
  hg_first <- str_squish(str_remove(hg_name, ",.*$"))
  norm <- function(x) tolower(str_replace_all(x, "[^A-Za-z]", ""))

  last_ok  <- str_detect(norm(hg_name), fixed(norm(last)))
  gn <- given_name(first)
  first_ok <- nchar(norm(gn)) >= 2 && str_detect(norm(hg_first), fixed(norm(gn)))
  cred_ok  <- !is.na(cred) && cred %in% c("CNM", "CM")

  list(ok = isTRUE(last_ok) && isTRUE(first_ok) && isTRUE(cred_ok),
       credential = cred, hg_name = hg_name)
}

scrape_one <- function(row) {
  first <- row$first_name; last <- row$last_name
  log_message(sprintf("%s %s", first, last))

  urls <- search_midwife(first, last)
  url <- pick_best_url(urls, given_name(first), last)
  if (is.na(url)) {
    return(tibble(certification_number = row$certification_number,
                  hg_status = "no_search_hit"))
  }

  html <- fetch(paste0("https://www.healthgrades.com", url))
  if (is.na(html)) {
    return(tibble(certification_number = row$certification_number,
                  hg_status = "profile_fetch_failed", hg_url = url))
  }

  v <- verify_profile(html, first, last)
  if (!v$ok) {
    return(tibble(certification_number = row$certification_number,
                  hg_status = "rejected_name_or_credential",
                  hg_url = url, hg_credential = v$credential, hg_name = v$hg_name))
  }

  locs <- extract_locations(html)
  npi <- extract_npi_jsonld(html)
  if (is.na(npi)) npi <- extract_npi_from_html(html)
  if (nrow(locs) == 0) {
    return(tibble(certification_number = row$certification_number,
                  hg_status = "no_address", hg_url = url,
                  hg_credential = v$credential, hg_name = v$hg_name, hg_npi = npi))
  }

  locs %>%
    mutate(certification_number = row$certification_number,
           hg_status = "ok", hg_url = url, hg_credential = v$credential,
           hg_name = v$hg_name, hg_npi = npi, hg_site_n = row_number()) %>%
    relocate(certification_number)
}

# --- Main ------------------------------------------------------------------

main <- function(n_limit = NA_integer_) {
  stopifnot(file.exists(INPUT))
  roster <- read_csv(INPUT, show_col_types = FALSE) %>%
    filter(!is.na(last_name), !is.na(first_name))

  done <- if (file.exists(CHECKPOINT)) readRDS(CHECKPOINT) else list()
  todo <- roster %>% filter(!certification_number %in% names(done))
  if (!is.na(n_limit)) todo <- head(todo, n_limit)

  log_message(sprintf("roster=%d already_done=%d this_run=%d delay=%ss",
                      nrow(roster), length(done), nrow(todo), DELAY_SEC))

  for (i in seq_len(nrow(todo))) {
    r <- todo[i, ]
    res <- tryCatch(scrape_one(r), error = function(e) {
      log_message(paste("  ERROR:", e$message))
      tibble(certification_number = r$certification_number, hg_status = "error")
    })
    done[[as.character(r$certification_number)]] <- res

    if (i %% CKPT_EVERY == 0 || i == nrow(todo)) {
      saveRDS(done, CHECKPOINT)
      out <- bind_rows(done)
      write_csv(out, OUTPUT, na = "")
      log_message(sprintf("  checkpoint %d/%d -> %s (%d rows)",
                          i, nrow(todo), OUTPUT, nrow(out)))
    }
  }

  out <- bind_rows(done)
  write_csv(out, OUTPUT, na = "")

  s <- out %>% count(hg_status, sort = TRUE)
  log_message("--- status counts ---")
  for (j in seq_len(nrow(s))) log_message(sprintf("  %-28s %d", s$hg_status[j], s$n[j]))
  hits <- filter(out, hg_status == "ok")
  log_message(sprintf("people with an address : %d",
                      dplyr::n_distinct(hits$certification_number)))
  log_message(sprintf("locations              : %d", nrow(hits)))
  log_message(sprintf("with coordinates       : %d", sum(!is.na(hits$hg_lat))))
  log_message(sprintf("with Luhn-valid NPI    : %d",
                      dplyr::n_distinct(hits$certification_number[!is.na(hits$hg_npi)])))
  invisible(out)
}

if (sys.nframe() == 0) {
  a <- commandArgs(trailingOnly = TRUE)
  main(if (length(a) > 0) as.integer(a[1]) else NA_integer_)
}
