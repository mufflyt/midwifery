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
  library(humaniformat)
})
# Atomic checkpoint/output writes. A plain saveRDS() + write_csv() pair can be
# killed between the two calls, or mid-write, leaving a checkpoint newer than
# its output or a truncated CSV where a complete one was. See DEBT.md D1.
source(file.path("R", "lib", "resume_state.R"))
# luhn_check_npi(), parse_physician_name_enhanced() and are_nickname_variants()
# all come from the isochrones checkout; none is re-implemented here.
source(file.path("R", "lib", "isochrones_dep.R"))
load_isochrones_name_tools(quiet = TRUE)


# The FULL AMCB roster (22,309), not a subset. The frozen linkage carries
# certification_number, last_name and first_name for every certificant
# regardless of linkage tier, which is what a name search needs.
INPUT       <- Sys.getenv("HG_INPUT", "artifacts/amcb_npi_linkage_FROZEN.csv")
OUTPUT      <- "healthgrades_midwives.csv"
CHECKPOINT  <- "healthgrades_checkpoint.rds"
LOG_FILE    <- "healthgrades_scrape_log.txt"
DELAY_SEC   <- as.numeric(Sys.getenv("HG_DELAY", "2"))
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

# luhn_check_npi() is NOT defined here. It is the canonical implementation in
# isochrones R/utils/npi_luhn_qa.R, loaded by load_isochrones_name_tools()
# above. isochrones already carried three copies of the Luhn check; a fourth in
# this file made four, and the whole point of the checksum is that every caller
# agrees on it.

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

#' Split a name into lowercase alphabetic tokens
#'
#' Splitting on any non-letter means "Barlow-Reed" and "Barlow Reed" tokenise
#' identically, so hyphenation differences between AMCB and Healthgrades do not
#' cause a miss. Tokens shorter than 2 characters (middle initials) are dropped.
#'
#' @param x [character(1)]: a name, or a URL slug.
#' @return [character] tokens.
name_tokens <- function(x) {
  if (is.na(x)) return(character(0))
  # Apostrophes are DELETED, not treated as separators: Healthgrades stores
  # "Michele Oconnor" where AMCB has "Michele O'Connor". Splitting on the
  # apostrophe yields the token "connor", which then fails to equal "oconnor"
  # and rejects a correct match. Deleting makes both sides "oconnor".
  x <- str_replace_all(x, "[’'`]", "")
  t <- tolower(str_split(str_squish(x), "[^A-Za-z]+")[[1]])
  t[nchar(t) >= 2]
}

#' Parse a full name into normalised given/surname parts
#'
#' Thin adapter over isochrones' parse_physician_name_enhanced(), which is the
#' canonical parser: humaniformat-backed, vectorised, and carrying the edge
#' cases this cohort actually hits (particles like "van Erven", the DO-vs-
#' Vietnamese-surname ambiguity, trailing credentials). It also returns a parse
#' confidence, which a hand-rolled splitter cannot.
#'
#' Applied to BOTH sides of every comparison. That symmetry is the point:
#' whatever convention the parser imposes on a compound name it imposes
#' identically on the roster string and the scraped string, so the two stay
#' comparable even where the parse is debatable.
#'
#' @param full [character(1)]: a whole name, e.g. "Christine Barlow Reed".
#' @return [list] `first`, `middle`, `last` (lowercased, apostrophes stripped)
#'   and `rest`, the tokens after the leading given name.
parse_person <- function(full) {
  if (is.na(full) || !nzchar(str_squish(full))) {
    return(list(first = NA_character_, middle = NA_character_,
                last = NA_character_, rest = character(0)))
  }
  p <- parse_physician_name_enhanced(str_squish(full))
  norm1 <- function(s) {
    if (length(s) == 0 || is.na(s)) return(NA_character_)
    tolower(str_squish(str_replace_all(s, "[\u2019\u0027`]", "")))
  }
  list(first = norm1(p$first_name[1]), middle = norm1(p$middle_name[1]),
       last = norm1(p$last_name[1]),
       # Everything after the leading token. Unhyphenated compound surnames --
       # "Sherece Dyer Hill", "Emily Young Johnson" -- are split into middle +
       # last by any parser, so the roster's single "Dyer" can never equal the
       # parsed last name "Hill". Comparing the whole trailing pool keeps them
       # together. isochrones has no equivalent, so this part stays local.
       rest = name_tokens(str_squish(str_remove(full, "^\\S+\\s*"))))
}

#' Candidate given-name forms for one side of a comparison
#'
#' AMCB fuses middle names into first_name ("Jo Ann", "Beth Anne"), while
#' Healthgrades stores the fused form as one word ("Joann"). Generating both
#' the split and the concatenated form lets "Jo Ann" reach "Joann" without
#' loosening the prefix rule to two characters, which would start matching
#' "Al" to "Alice".
#'
#' @param p [list]: output of parse_person().
#' @return [character] distinct candidate forms.
given_forms <- function(p) {
  parts <- c(p$first, p$middle)
  parts <- parts[!is.na(parts) & nzchar(parts)]
  if (length(parts) == 0) return(character(0))
  toks <- name_tokens(paste(parts, collapse = " "))
  unique(c(p$first, toks, paste(toks, collapse = "")))
}

#' Does the given name match, allowing documented shortenings?
#'
#' Surnames must match exactly because a wrong surname means a different
#' person. Given names cannot be that strict: AMCB and Healthgrades disagree
#' constantly on the same individual -- "Jo Ann"/"Joann", "Carol"/"Caroline",
#' "Sara"/"Sarah", "Jan"/"Janet". A prefix rule accepts those while still
#' rejecting the substring collisions that motivated this change --
#' "Linda"/"Melinda" and "Elissa"/"Melissa" are NOT prefixes of one another, so
#' they stay rejected.
#'
#' Nicknames that are not prefixes ("Beth" for Elizabeth) remain misses. That is
#' accepted: a miss costs one unmatched midwife, a false match corrupts a row.
#'
#' @param a,b [character(1)]: two normalised given names.
#' @return [logical(1)]
given_name_match <- function(a, b) {
  if (is.na(a) || is.na(b) || !nzchar(a) || !nzchar(b)) return(FALSE)
  if (identical(a, b)) return(TRUE)
  # Nickname dictionary FIRST, from isochrones. It resolves the pairs a prefix
  # rule structurally cannot -- Beth/Elizabeth, Peggy/Margaret, Betty/Elizabeth
  # -- which were previously logged here as permanent misses. It correctly
  # rejects Linda/Melinda and Elissa/Melissa.
  if (isTRUE(are_nickname_variants(a, b))) return(TRUE)
  # Prefix rule retained: isochrones has no principled equivalent (only a
  # 3-character containment hack in its Healthgrades verifier), and this is what
  # admits Carol/Caroline, Sara/Sarah, Jo Ann/Joann.
  n <- min(nchar(a), nchar(b))
  n >= 3 && substr(a, 1, n) == substr(b, 1, n)
}

#' Compare a Healthgrades page title against a roster name
#'
#' @param hg_name [character(1)]: page title, e.g. "Joann Haas, CNM - Midwife
#'   in Fountain Hill, PA". Everything from the first comma is credential and
#'   location boilerplate and is discarded before parsing.
#' @param first,last [character(1)]: roster name fields.
#' @return [logical(1)] TRUE when surname matches exactly and given name
#'   matches under given_name_match().
name_matches_roster <- function(hg_name, first, last) {
  if (is.na(hg_name)) return(FALSE)
  hg <- parse_person(str_squish(str_remove(hg_name, ",.*$")))
  ros <- parse_person(paste(first %||% "", last %||% ""))
  if (is.na(hg$last) || is.na(ros$last)) return(FALSE)

  # Surname comparison is token SUBSET, not string equality. Married and
  # hyphenated surnames are the single largest source of legitimate
  # disagreement between the two sources -- AMCB "Nelson" vs Healthgrades
  # "Nelson-Becker", "Kioko" vs "Kioko-Kamps", "Perry" vs "Perry-Hidalgo" (56
  # such pairs in the current output). Requiring equality rejects all of them.
  #
  # Subset still blocks the collisions this whole change is about, because
  # those differ WITHIN a token rather than by adding one: "anderson" is not a
  # member of {"sanderson"}, nor "williams" of {"williamson"}, nor "martin" of
  # {"martinez"}.
  # Two views of the surname, either of which may match. Neither alone is
  # enough:
  #   * parsed last name handles a roster middle name against a hyphenated
  #     surname -- "Karen Margaret Murphy" vs "Karen Murphy-Fitch", where the
  #     trailing pools {margaret,murphy} and {murphy,fitch} do not nest.
  #   * trailing pool handles an unhyphenated compound -- "Sherece Dyer" vs
  #     "Sherece Dyer Hill", where parse_names() calls the last name "Hill".
  subset_either <- function(a, b) {
    if (length(a) == 0 || length(b) == 0) return(FALSE)
    all(b %in% a) || all(a %in% b)
  }
  surname_ok <- subset_either(name_tokens(hg$last), name_tokens(ros$last)) ||
    subset_either(hg$rest, ros$rest)
  if (!surname_ok) return(FALSE)

  fa <- given_forms(hg)
  fb <- given_forms(ros)
  any(outer(fa, fb, Vectorize(given_name_match)))
}

#' Does every token of `part` appear as a WHOLE token of `full`?
#'
#' The substring test this replaces -- str_detect(full, fixed(part)) -- accepted
#' any name that merely contained the target as a substring. Observed live:
#' AMCB's "Anderson" matched Healthgrades' "Laura Sanderson", because
#' "sanderson" contains "anderson". The same collision hits every -son/-sen
#' surname, plus Allen/Allende and Arnold/Arnoldson, and it silently attributes
#' one midwife's address, NPI and demographics to a different person.
#'
#' Whole-token equality is deliberately stricter than the old behaviour: it also
#' stops rejecting-by-luck cases like "Beth" matching inside "Elizabeth". Those
#' become misses rather than wrong answers, which is the correct trade for a
#' matching source feeding a provider panel.
#'
#' @param full [character(1)]: the candidate name (or slug).
#' @param part [character(1)]: the roster name to require.
#' @return [logical(1)]
tokens_all_present <- function(full, part) {
  need <- name_tokens(part)
  if (length(need) == 0) return(FALSE)
  all(need %in% name_tokens(full))
}

#' Choose the profile whose slug best matches the name
#'
#' Slug-based, so it is a weak check -- verify_profile() re-checks the name and
#' credential from the page itself before anything is written out. Matching is
#' on whole slug tokens; see tokens_all_present() for why substrings are unsafe.
pick_best_url <- function(urls, first, last) {
  if (length(urls) == 0) return(NA_character_)

  # Slugs cannot go through humaniformat -- "/providers/laura-sanderson-ylb2q"
  # has no name structure and carries a trailing profile id. Compare whole slug
  # tokens instead, which is enough to stop the Anderson/Sanderson collision;
  # verify_profile() then does the real humaniformat check on the page title.
  ros <- parse_person(paste(first %||% "", last %||% ""))
  if (is.na(ros$last)) return(NA_character_)

  last_hit <- vapply(urls, tokens_all_present, logical(1), part = ros$last)
  if (!is.na(ros$first) && nchar(ros$first) >= 2) {
    first_hit <- vapply(urls, tokens_all_present, logical(1), part = ros$first)
    both <- urls[last_hit & first_hit]
    if (length(both) > 0) return(both[1])
  }
  only_last <- urls[last_hit]
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

#' Unescape the Next.js flight payload embedded in the page
#'
#' Healthgrades is a Next.js app: alongside the JSON-LD it ships the whole
#' provider model inside `self.__next_f.push([1,"..."])` string chunks. Because
#' those chunks are JS string literals, every quote arrives escaped -- and at
#' two different depths (\\" and \\\\") depending on nesting. Collapsing both
#' turns the payload into ordinary JSON text that plain regexes can read.
#'
#' Not parsed as JSON: the payload is a concatenation of partial React flight
#' chunks, not one well-formed document, so fromJSON() fails on it.
#'
#' @param html [character(1)]: raw profile HTML.
#' @return [character(1)] the page text with flight-payload escaping removed.
unescape_flight <- function(html) {
  if (is.null(html) || is.na(html) || nchar(html) == 0) return(NA_character_)
  str_replace_all(str_replace_all(html, fixed('\\\\"'), '"'), fixed('\\"'), '"')
}

#' Slice out the bracket-balanced array value of a key in the flight payload
#'
#' `insuranceAccepted` nests a `plans` array inside each payor object, so the
#' obvious '\\[([^]]*)\\]' stops at the first inner bracket and truncates after
#' one payor. Count depth instead.
#'
#' @param x [character(1)]: unescaped flight payload.
#' @param key [character(1)]: the JSON key whose array value is wanted.
#' @return [character(1)] the array text including its brackets, or NA.
extract_json_array <- function(x, key) {
  start <- str_locate(x, fixed(paste0('"', key, '":[')))
  if (is.na(start[1, 1])) return(NA_character_)
  open_at <- start[1, 2]                     # index of the '['
  chars <- strsplit(substr(x, open_at, min(nchar(x), open_at + 200000L)), "")[[1]]
  depth <- 0L
  for (i in seq_along(chars)) {
    if (chars[i] == "[") depth <- depth + 1L
    else if (chars[i] == "]") {
      depth <- depth - 1L
      if (depth == 0L) return(paste(chars[1:i], collapse = ""))
    }
  }
  NA_character_
}

#' Summarise the payors and plans a provider is listed as accepting
#'
#' Medicaid shows up inconsistently -- sometimes as the payor name ("Georgia
#' Medicaid"), sometimes only in a plan name under a commercial payor ("Anthem
#' Healthy Blue Medicaid"), sometimes in planType. Match across all three.
#'
#' IMPORTANT for interpretation: this list is sponsor-supplied and demonstrably
#' incomplete (a hospital-employed CNM showing exactly one EPO plan is not a
#' provider who takes one plan). Absence of Medicaid is NOT evidence of
#' non-acceptance; treat hg_medicaid == TRUE as a lower bound and never read
#' NA/FALSE as a refusal.
#'
#' @param x [character(1)]: unescaped flight payload.
#' @return [tibble] payor count, plan count, Medicaid/Medicare flags, payor list.
parse_insurance <- function(x) {
  blk <- extract_json_array(x, "insuranceAccepted")
  if (is.na(blk) || identical(str_squish(blk), "[]")) {
    return(tibble(hg_payor_n = 0L, hg_plan_n = 0L,
                  hg_medicaid_named = NA, hg_medicare = NA,
                  hg_payors = NA_character_, hg_plans = NA_character_))
  }
  # Scoped to the block, so the stray '"payor":"term"' elsewhere on the page
  # cannot inflate the count.
  payors <- str_match_all(blk, '"payor":"([^"]*)"')[[1]][, 2]
  plans  <- str_match_all(blk, '"name":"([^"]*)"')[[1]][, 2]
  types  <- str_match_all(blk, '"planType":"([^"]*)"')[[1]][, 2]
  hay <- c(payors, plans, types)

  tibble(
    hg_payor_n  = length(payors),
    hg_plan_n   = length(plans),
    # Hyphen REQUIRED in medi-cal: an optional hyphen makes the pattern match
    # the word "Medical", which flagged the payor "Medical Mutual" (an Ohio
    # commercial insurer) as Medicaid.
    hg_medicaid_named = any(str_detect(hay, regex("medicaid|\\bmedi-cal\\b|\\bchip\\b",
                                                  ignore_case = TRUE))),
    hg_medicare = any(str_detect(hay, regex("medicare", ignore_case = TRUE))),
    hg_payors   = if (length(payors) == 0) NA_character_
                  else paste(unique(payors), collapse = "; "),
    # Kept verbatim so a payor -> Medicaid crosswalk can be applied later
    # without re-crawling. Necessary because Healthgrades does not label
    # Medicaid plans: New Mexico's Medicaid product appears as "HealthyBlue
    # Advantage" and Ohio's as "CareSource", neither containing "Medicaid".
    # hg_medicaid_named is therefore a floor, not a measure.
    hg_plans    = if (length(plans) == 0) NA_character_
                  else paste(unique(plans), collapse = "; ")
  )
}

#' Extract person-level attributes from the Next.js flight payload
#'
#' The JSON-LD block carries only address, specialty and NPI. Everything else
#' Healthgrades knows about a provider -- gender, age, rating, verification
#' date -- lives in the flight payload and is invisible to extract_locations().
#'
#' Anchoring matters. The payload also embeds a `compareProviders` array of
#' OTHER midwives, each with its own "gender" key, and those appear BEFORE the
#' subject's in the document. An unanchored '"gender":"([MF])"' therefore
#' returns a neighbouring provider's sex, silently and for most of the file.
#' Both gender patterns below are pinned to a key that only the subject's own
#' record carries; no unanchored fallback, because a wrong value here is worse
#' than a missing one.
#'
#' Empty-by-design fields (education, boardCertifications, languages,
#' roundedYearsOfExperience) are still extracted: they are populated for
#' physicians, and capturing them costs nothing beyond a regex. Expect NA.
#'
#' @param html [character(1)]: raw profile HTML.
#' @return [tibble] one row of attributes; NA where the page is silent.
parse_next_flight <- function(html) {
  na_row <- tibble(
    hg_gender = NA_character_, hg_age = NA_integer_,
    hg_years_experience = NA_integer_, hg_education_n = NA_integer_,
    hg_education_year = NA_integer_, hg_education_name = NA_character_,
    hg_languages = NA_character_, hg_board_certs = NA_character_,
    hg_memberships = NA_character_, hg_professional_subtype = NA_character_,
    hg_accepts_new_patients = NA, hg_has_telehealth = NA,
    hg_has_photo = NA, hg_rating = NA_real_, hg_review_n = NA_integer_,
    hg_verified_date = NA_character_, hg_provider_code = NA_character_,
    hg_payor_n = NA_integer_, hg_plan_n = NA_integer_, hg_medicaid_named = NA,
    hg_medicare = NA, hg_payors = NA_character_, hg_plans = NA_character_)

  x <- unescape_flight(html)
  if (is.na(x)) return(na_row)

  # First capture group of the first match, or NA.
  g1 <- function(pat) {
    m <- str_match(x, pat)
    if (is.na(m[1, 1])) NA_character_ else m[1, 2]
  }
  # NA unless every match agrees -- guards against a key that also occurs in
  # some other provider's record on the same page.
  g_unique <- function(pat) {
    v <- unique(str_match_all(x, pat)[[1]][, 2])
    if (length(v) == 1) v else NA_character_
  }
  as_lgl <- function(s) if (is.na(s)) NA else identical(s, "true")
  # "[]" is Healthgrades' way of saying "we have no data", not "none".
  nonempty <- function(s) if (is.na(s) || !nzchar(str_squish(s))) NA_character_ else s

  tibble(
    # Spelled out, not the raw "F"/"M": a CSV column of bare F/M is read back
    # by readr's type guesser as LOGICAL, turning every female midwife into
    # FALSE and every male into NA. Verified round-trip, do not "simplify".
    hg_gender           = c(F = "Female", M = "Male")[
      g1('"providerDisplayFullName":"[^"]*","gender":"([MF])"')] %>% unname(),
    hg_age              = suppressWarnings(as.integer(g_unique('"age":"([0-9]{1,3})"'))),
    hg_years_experience = suppressWarnings(as.integer(g_unique('"roundedYearsOfExperience":([0-9]+)'))),
    hg_education_n      = nrow(str_match_all(x, '"completionYear":')[[1]]),
    hg_education_year   = suppressWarnings(as.integer(g1('"completionYear":([0-9]{4})'))),
    hg_education_name   = nonempty(g1('"education":\\[\\{[^}]*?"name":"([^"]*)"')),
    hg_languages        = nonempty(g1('"languages":\\[([^]]*)\\]')),
    hg_board_certs      = nonempty(g1('"boardCertifications":\\[([^]]*)\\]')),
    hg_memberships      = nonempty(g1('"memberships":\\[([^]]*)\\]')),
    hg_professional_subtype = nonempty(g1('"professionalSubType":"([^"]*)"')),
    hg_accepts_new_patients = as_lgl(g_unique('"acceptsNewPatients":(true|false)')),
    hg_has_telehealth   = as_lgl(g_unique('"hasTelehealth":(true|false)')),
    hg_has_photo        = as_lgl(g_unique('"hasDisplayImage":(true|false)')),
    hg_rating           = suppressWarnings(as.numeric(g_unique('"surveyOverallRatingScore":([0-9.]+)'))),
    # Anchored to the rating, which is unique to the subject. Bare
    # "surveyUserCount" occurs ~10x per page -- the FIRST hit sits inside the
    # `otherProviders` / `compareProviders` arrays, so an unanchored read
    # returns a neighbouring midwife's review count (observed: 1 instead of 0).
    hg_review_n         = suppressWarnings(as.integer(
      g1('"surveyOverallRatingScore":[0-9.]+,"surveyUserCount":([0-9]+)'))),
    hg_verified_date    = g_unique('"lastVerificationDateIso":"([0-9-]{10})"'),
    hg_provider_code    = g_unique('"providerCode":"([A-Z0-9]+)"')
  ) %>% bind_cols(parse_insurance(x))
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

  # humaniformat on both sides, surname exact: the old substring test matched
  # AMCB's "Anderson" against Healthgrades' "Laura Sanderson".
  # name_matches_roster() covers first and last together.
  name_ok  <- name_matches_roster(hg_name, first, last)
  cred_ok  <- !is.na(cred) && cred %in% c("CNM", "CM")

  list(ok = isTRUE(name_ok) && isTRUE(cred_ok),
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

  # RECOVERY GUARD (added 2026-08-09 after losing 5,963 completed searches).
  # OUTPUT is rewritten wholesale from `done` at every checkpoint, so a missing
  # or reset checkpoint does not merely lose progress -- it TRUNCATES the CSV
  # that held it. That is what happened: the checkpoint went away, the next run
  # started from zero, and 482 KB of results became 552 bytes.
  #
  # If the CSV holds more work than the checkpoint does, rebuild the checkpoint
  # from the CSV instead of overwriting it. Results are recovered rather than
  # destroyed, and a stale checkpoint can never cost more than the requests
  # since the last save.
  if (file.exists(OUTPUT)) {
    prior <- suppressWarnings(tryCatch(
      readr::read_csv(OUTPUT, show_col_types = FALSE, progress = FALSE),
      error = function(e) NULL))
    if (!is.null(prior) && nrow(prior) &&
        dplyr::n_distinct(prior$certification_number) > length(done)) {
      recovered <- split(prior, prior$certification_number)
      log_message(sprintf(
        "RECOVERY: %s has %d certificants but the checkpoint has %d. Rebuilding
   the checkpoint from the CSV so completed work is not re-scraped.",
        OUTPUT, length(recovered), length(done)))
      # FLAT name-keyed replacement, NOT modifyList(). modifyList() recurses
      # into any element that is itself a list -- and a tibble IS a list -- so
      # it tries to merge the recovered and checkpointed records COLUMN BY
      # COLUMN inside each certificant and dies on row recycling:
      #   Assigned data `if (...) NULL` must be compatible with existing data.
      # That is exactly what happened when merging two checkpoints by hand, and
      # it would have fired here the first time recovery was ever needed.
      # Checkpoint entries win where both exist: they are the fresher pass.
      recovered[names(done)] <- done
      done <- recovered
    }
  }

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
      atomic_saveRDS(done, CHECKPOINT)
      out <- bind_rows(done)
      atomic_write_csv(out, OUTPUT, na = "")
      log_message(sprintf("  checkpoint %d/%d -> %s (%d rows)",
                          i, nrow(todo), OUTPUT, nrow(out)))
    }
  }

  out <- bind_rows(done)
  atomic_write_csv(out, OUTPUT, na = "")

  # A profile URL claimed by more than one certificant cannot describe both.
  # 185 URLs matched 204 certificants in the first pass; at roster scale that
  # ambiguity multiplies, so it is counted every run rather than discovered
  # later.
  if ("hg_url" %in% names(out)) {
    # Two corrections to the obvious version of this check, each of which
    # inflated the count several-fold:
    #
    # 1. distinct() on certification_number FIRST. A midwife occupies one row
    #    per practice site, so counting rows per URL flags every multi-site
    #    midwife as though she were several people -- 766 flagged where 131
    #    were real, one certificant with four clinics counted as four
    #    claimants.
    # 2. Select on hg_status == "ok", not !is.na(hg_url). A candidate rejected
    #    for a name or credential mismatch KEEPS the URL it was rejected for,
    #    so !is.na(hg_url) silently readmits rejected matches.
    #
    # The claim is about PEOPLE sharing one profile, so the unit counted has
    # to be the person, over accepted matches only.
    dup <- out %>%
      filter(hg_status == "ok", !is.na(hg_url)) %>%
      distinct(certification_number, hg_url) %>%
      count(hg_url) %>%
      filter(n > 1)
    if (nrow(dup))
      log_message(sprintf(
        "AMBIGUOUS: %d profile URL(s) claimed by >1 certificant (%d certificant-links). Not attributable; drop before use.",
        nrow(dup), sum(dup$n)))
  }

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
