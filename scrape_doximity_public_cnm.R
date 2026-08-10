#!/usr/bin/env Rscript
# =============================================================================
# Doximity public CNM profile scraper (no login required)
# =============================================================================
# Doximity lists CNMs at:
#   https://www.doximity.com/directory/np/specialty/certified-nurse-midwife
# with alphabetical sub-pages (/a, /b, ...) and ?page=N pagination.
#
# Each public profile exposes (without authentication):
#   - Full name (including maiden name in parentheses)
#   - UUID in JSON-LD (not NPI — Doximity internal identifier)
#   - Specialty label
#   - City, state
#   - Practice street address and zip
#   - Phone number
#   - Hospital / practice affiliation (in bio sentence)
#   - dateCreated / dateModified (profile metadata)
#
# Strategy:
#   PASS 1 — crawl directory A–Z, collect all public profile URLs.
#   PASS 2 — fetch each profile URL, parse HTML + JSON-LD.
#   PASS 3 — name-match to the AMCB cohort roster.
#
# Outputs:
#   artifacts/doximity_public_profiles.csv      — parsed profiles
#   artifacts/doximity_public_urls.csv          — URL list (resume checkpoint)
#   artifacts/doximity_public_provenance.csv    — run metadata
#
# Rate limit: 2-second sleep between requests (robots.txt compliance).
# Resume:     set DOX_RESUME=1 to skip already-fetched profiles.
# =============================================================================
suppressPackageStartupMessages({
  library(httr); library(rvest); library(jsonlite)
  library(dplyr); library(readr); library(stringr); library(tibble)
})

RESUME      <- identical(Sys.getenv("DOX_RESUME"), "1")
SLEEP_SEC   <- 2
ROSTER_FILE <- "artifacts/amcb_npi_linkage_FROZEN.csv"
URL_FILE    <- "artifacts/doximity_public_urls.csv"
OUT_FILE    <- "artifacts/doximity_public_profiles.csv"
PROV_FILE   <- "artifacts/doximity_public_provenance.csv"
BASE        <- "https://www.doximity.com"
DIR_BASE    <- paste0(BASE, "/directory/np/specialty/certified-nurse-midwife")

HEADERS <- add_headers(
  `User-Agent`      = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36",
  `Accept`          = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
  `Accept-Language` = "en-US,en;q=0.9",
  `Accept-Encoding` = "gzip, deflate, br"
)

safe_get <- function(url, pause = SLEEP_SEC) {
  Sys.sleep(pause)
  tryCatch(GET(url, HEADERS, timeout(30)), error = function(e) NULL)
}

cat("=== Doximity public CNM scraper ===\n")
cat(sprintf("resume mode: %s\n", RESUME))
dir.create("artifacts", showWarnings = FALSE)

# =============================================================================
# PASS 1: collect profile URLs from directory A–Z
# =============================================================================
if (RESUME && file.exists(URL_FILE)) {
  cat("pass 1: loading existing URL list\n")
  url_df <- read_csv(URL_FILE, show_col_types = FALSE)
} else {
  cat("pass 1: crawling directory A–Z\n")
  all_urls <- character(0)
  letters_tried <- character(0)

  for (letter in letters) {
    page_n <- 1L
    repeat {
      dir_url <- sprintf("%s/%s?page=%d", DIR_BASE, letter, page_n)
      resp <- safe_get(dir_url)
      if (is.null(resp) || status_code(resp) != 200) break

      html  <- content(resp, as = "parsed", encoding = "UTF-8")
      links <- html %>%
        html_elements("a[href]") %>%
        html_attr("href") %>%
        keep(~ str_detect(.x, "^/pub/"))

      if (!length(links)) break
      new_urls <- paste0(BASE, links)
      all_urls <- unique(c(all_urls, new_urls))
      cat(sprintf("  %s p%d: %d profiles (total %d)\n",
                  toupper(letter), page_n, length(links), length(all_urls)))
      page_n <- page_n + 1L
    }
    letters_tried <- c(letters_tried, letter)
  }

  url_df <- tibble(profile_url = unique(all_urls))
  write_csv(url_df, URL_FILE)
  cat(sprintf("pass 1 complete: %d unique profile URLs\n",
              nrow(url_df)))
}

# =============================================================================
# PASS 2: fetch and parse each profile
# =============================================================================
parse_profile <- function(url) {
  resp <- safe_get(url)
  if (is.null(resp) || status_code(resp) != 200)
    return(tibble(profile_url = url, parse_status = "http_error"))

  html <- tryCatch(content(resp, as = "parsed", encoding = "UTF-8"),
                   error = function(e) NULL)
  if (is.null(html))
    return(tibble(profile_url = url, parse_status = "parse_error"))

  # --- JSON-LD -----------------------------------------------------------------
  jsonld_text <- html %>%
    html_element('script[type="application/ld+json"]') %>%
    html_text()
  uuid <- NA_character_; date_created <- NA_character_; date_modified <- NA_character_
  if (!is.na(jsonld_text) && nchar(jsonld_text) > 2) {
    jld <- tryCatch(fromJSON(jsonld_text), error = function(e) NULL)
    if (!is.null(jld)) {
      uuid          <- jld$mainEntity$identifier %||% NA_character_
      date_created  <- jld$dateCreated           %||% NA_character_
      date_modified <- jld$dateModified          %||% NA_character_
    }
  }

  # --- name (from title or h1) -------------------------------------------------
  full_name <- html %>% html_element("h1") %>% html_text(trim = TRUE)
  if (is.na(full_name))
    full_name <- html %>% html_element("title") %>% html_text(trim = TRUE) %>%
      str_remove("\\s*[–|].*$")

  # Strip credential suffix (CNM, NP, etc.) from end
  name_clean <- str_trim(str_remove(full_name, "\\s+(CNM|NP|WHNP|DNP|MSN|RN)[\\.\\s]*$"))

  # Maiden name in parentheses → extract separately
  maiden_name <- str_match(name_clean, "\\(([^)]+)\\)")[,2]
  name_no_maiden <- str_trim(str_remove(name_clean, "\\s*\\([^)]+\\)\\s*"))

  # --- specialty ---------------------------------------------------------------
  specialty <- html %>%
    html_element("a[href*='/directory/np/specialty/']") %>%
    html_text(trim = TRUE)

  # --- city, state -------------------------------------------------------------
  city_state_raw <- html %>%
    html_elements("a[href*='/directory/location/']") %>%
    html_text(trim = TRUE)
  city  <- city_state_raw[1] %||% NA_character_
  state <- city_state_raw[2] %||% NA_character_

  # --- address and phone (list items) -----------------------------------------
  list_items <- html %>%
    html_elements("main li") %>%
    html_text(trim = TRUE)

  address_line <- NA_character_
  city_zip     <- NA_character_
  phone        <- NA_character_
  for (li in list_items) {
    if (str_detect(li, "^\\+1\\s")) {
      phone <- str_trim(li)
    } else if (str_detect(li, "\\d{5}")) {
      # e.g. "111 17th Ave E\nAlexandria, MN 56308"
      parts <- str_split(li, "\n")[[1]]
      if (length(parts) >= 2) {
        address_line <- str_trim(parts[1])
        city_zip     <- str_trim(parts[2])
      } else {
        address_line <- str_trim(li)
      }
    }
  }

  # --- hospital affiliation (from bio sentence) --------------------------------
  bio_text <- html %>%
    html_elements("main p, main [class*='bio'], main [class*='description']") %>%
    html_text(trim = TRUE) %>%
    paste(collapse = " ")

  affiliation <- NA_character_
  aff_match <- str_match(bio_text,
    "affiliated with ([A-Z][^.]{3,80}?)(?:\\.|$)")
  if (!is.na(aff_match[,2]))
    affiliation <- str_trim(aff_match[,2])

  tibble(
    profile_url   = url,
    parse_status  = "ok",
    uuid          = uuid,
    date_created  = date_created,
    date_modified = date_modified,
    full_name     = full_name,
    name_clean    = name_clean,
    maiden_name   = maiden_name,
    name_no_maiden = name_no_maiden,
    specialty     = specialty,
    city          = city,
    state         = state,
    address_line  = address_line,
    city_zip      = city_zip,
    phone         = phone,
    affiliation   = affiliation,
    bio_text      = str_trunc(bio_text, 300)
  )
}

# Null-coalescing helper
`%||%` <- function(a, b) if (!is.null(a) && length(a) > 0 && !is.na(a[1])) a[1] else b

already_done <- character(0)
existing_profiles <- NULL
if (RESUME && file.exists(OUT_FILE)) {
  existing_profiles <- read_csv(OUT_FILE, show_col_types = FALSE)
  already_done <- existing_profiles$profile_url
  cat(sprintf("pass 2: resuming — %d already fetched\n", length(already_done)))
}

pending <- setdiff(url_df$profile_url, already_done)
cat(sprintf("pass 2: fetching %d profiles\n", length(pending)))

results <- vector("list", length(pending))
for (i in seq_along(pending)) {
  if (i %% 50 == 0)
    cat(sprintf("  %d / %d\n", i, length(pending)))
  results[[i]] <- tryCatch(parse_profile(pending[i]),
                           error = function(e)
                             tibble(profile_url = pending[i], parse_status = "error"))
}

profiles <- bind_rows(c(list(existing_profiles), results))
write_csv(profiles, OUT_FILE, na = "")
ok_n <- sum(profiles$parse_status == "ok", na.rm = TRUE)
cat(sprintf("pass 2 complete: %d profiles parsed (%d ok)\n", nrow(profiles), ok_n))

# =============================================================================
# PASS 3: name-match to AMCB cohort
# =============================================================================
if (file.exists(ROSTER_FILE)) {
  cat("pass 3: matching to AMCB cohort\n")
  coh <- read_csv(ROSTER_FILE, show_col_types = FALSE, progress = FALSE) %>%
    filter(status == "ACTIVE", linkage_tier == "primary_midwifery") %>%
    distinct(certification_number, .keep_all = TRUE) %>%
    mutate(
      last_upper  = str_to_upper(str_trim(last_name)),
      first_upper = str_to_upper(str_squish(first_name))
    )

  dox_ok <- profiles %>%
    filter(parse_status == "ok") %>%
    mutate(
      # Parse name_no_maiden into first / last tokens
      name_parts  = str_split(name_no_maiden, "\\s+"),
      last_upper  = str_to_upper(map_chr(name_parts, ~ tail(.x, 1))),
      first_upper = str_to_upper(map_chr(name_parts, ~ .x[1]))
    )

  matched <- inner_join(
    coh %>% select(certification_number, last_upper, first_upper),
    dox_ok %>% select(profile_url, uuid, specialty, city, state,
                      address_line, city_zip, phone, affiliation,
                      full_name, maiden_name, date_created, date_modified,
                      last_upper, first_upper),
    by = c("last_upper", "first_upper")
  ) %>%
    distinct(certification_number, .keep_all = TRUE)

  cat(sprintf("  matched %d of %d cohort members (%.1f%%)\n",
              nrow(matched), nrow(coh), 100 * nrow(matched) / nrow(coh)))

  match_file <- "artifacts/doximity_public_matched.csv"
  write_csv(matched, match_file, na = "")
  cat(sprintf("  written: %s\n", match_file))
} else {
  cat("pass 3: roster not found — skipping cohort match\n")
}

# =============================================================================
# Provenance
# =============================================================================
write_csv(tibble(
  built_at      = format(Sys.time(), "%Y-%m-%dT%H:%M:%S"),
  urls_found    = nrow(url_df),
  profiles_ok   = ok_n,
  profiles_err  = nrow(profiles) - ok_n,
  sleep_sec     = SLEEP_SEC
), PROV_FILE)

cat(sprintf("written: %s\n", OUT_FILE))
cat(sprintf("written: %s\n", PROV_FILE))
cat("done.\n")
