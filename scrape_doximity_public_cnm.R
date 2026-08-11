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
#   PASS 1 — paginate directory (?page=N), collect all public profile URLs.
#             Note: letter sub-paths (/a, /b …) return 404; base URL + ?page=N works.
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
  # purrr was USED but never LOADED -- keep() in pass 1 and map_chr() in pass 3.
  # Pass 1 aborted on the first directory page, which is why this scraper has
  # never emitted a row despite being committed twice.
  library(purrr)
})

RESUME      <- identical(Sys.getenv("DOX_RESUME"), "1")
SLEEP_SEC   <- 2

# BOUNDED RUNS. A full crawl of the public CNM directory is thousands of
# profiles at 2s each. DOX_MAX_PROFILES caps the number of profiles fetched so
# the scraper can be exercised against the live site -- and its output
# inspected -- without committing to hours of requests. Unset means no cap.
MAX_PROFILES <- suppressWarnings(as.integer(Sys.getenv("DOX_MAX_PROFILES", NA)))

# Hard ceiling on directory pages so no future pagination change can produce an
# unbounded crawl again.
MAX_PAGES <- suppressWarnings(as.integer(Sys.getenv("DOX_MAX_PAGES", "400")))

# The roster is only needed for the match stage and lives outside a worktree
# (it is gitignored person-level data), so its path is overridable.
ROSTER_FILE <- Sys.getenv("DOX_ROSTER", "artifacts/amcb_npi_linkage_FROZEN.csv")
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
# PASS 1: collect profile URLs via paginated directory (no letter sub-paths)
# =============================================================================
if (RESUME && file.exists(URL_FILE)) {
  cat("pass 1: loading existing URL list\n")
  url_df <- read_csv(URL_FILE, show_col_types = FALSE)
} else {
  cat("pass 1: crawling directory pages\n")
  all_urls <- character(0)

  # PAGINATION IS BY CURSOR, NOT PAGE NUMBER. This used to request
  # "?page=N". Doximity IGNORES that parameter: pages 1, 2 and 3 return a
  # byte-identical set of the same 50 profiles. Because unique() absorbed the
  # duplicates and the loop only stopped when a page yielded zero links, the
  # crawl could never terminate -- it sat at "total 50" forever. The real
  # control is a cursor link, "?after=pub%2F<last-slug>", which the page
  # exposes only as an anchor. Follow that anchor until it stops appearing.
  page_n <- 1L
  dir_url <- DIR_BASE
  repeat {
    resp <- safe_get(dir_url)
    if (is.null(resp) || status_code(resp) != 200) break

    html  <- content(resp, as = "parsed", encoding = "UTF-8")
    # The is.na guard matters: html_attr() returns NA for an anchor with no
    # href, and str_detect(NA, ...) yields NA, which subsets to a phantom row.
    links <- html %>%
      html_elements("a[href]") %>%
      html_attr("href")
    links <- links[!is.na(links) & str_detect(links, "^/pub/")]

    if (!length(links)) break
    before_n <- length(all_urls)
    new_urls <- paste0(BASE, links)
    all_urls <- unique(c(all_urls, new_urls))
    cat(sprintf("  p%d: %d profiles (total %d)\n",
                page_n, length(links), length(all_urls)))
    # Stop enumerating once the cap is reachable; there is no reason to page
    # through a directory whose extra URLs will not be fetched.
    if (!is.na(MAX_PROFILES) && length(all_urls) >= MAX_PROFILES) {
      cat(sprintf("  stopping directory crawl: %d URLs is enough for a cap of %d\n",
                  length(all_urls), MAX_PROFILES))
      break
    }

    # GUARD 1: a page that adds nothing new means the cursor is not advancing.
    # This is the exact condition the old ?page= loop failed to notice.
    if (length(all_urls) == before_n) {
      cat(sprintf("  stopping: page %d added no new URLs (cursor not advancing)\n",
                  page_n))
      break
    }

    # Advance the cursor by reading the "?after=" anchor off the page itself.
    nxt <- html %>% html_elements("a[href]") %>% html_attr("href")
    nxt <- nxt[!is.na(nxt) & str_detect(nxt, "after=")]
    if (!length(nxt)) { cat("  stopping: no next-page cursor on this page\n"); break }
    dir_url <- paste0(BASE, nxt[1])

    # GUARD 2: hard ceiling. Nothing below may loop without a bound.
    page_n <- page_n + 1L
    if (page_n > MAX_PAGES) {
      cat(sprintf("  stopping: hit MAX_PAGES (%d). Raise DOX_MAX_PAGES to go deeper.\n",
                  MAX_PAGES))
      break
    }
  }

  url_df <- tibble(profile_url = unique(all_urls))
  if (!is.na(MAX_PROFILES)) url_df <- head(url_df, MAX_PROFILES)
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
    # Strip inline CSS injected by Doximity icon wrappers before the text.
    li_clean <- str_trim(str_remove(li, "^.*\\}"))
    # Phone: full US number (country code 1 + 10 digits). The pattern was
    # anchored at ^ , but Doximity renders the item as "Phone+1 707-322-0445"
    # -- the literal label sits in front of the number, so the anchor never
    # matched and this column came back empty for every profile while the
    # number was plainly visible in bio_text. Match anywhere and extract just
    # the number rather than keeping the label in the value.
    PHONE_RE <- "\\+?1[\\s\\-\\.]?\\(?\\d{3}\\)?[\\s\\-\\.]?\\d{3}[\\s\\-\\.]?\\d{4}"
    if (str_detect(li_clean, PHONE_RE)) {
      phone <- str_trim(str_extract(li_clean, PHONE_RE))
    } else if (str_detect(li_clean, "\\d{5}")) {
      # HTML fuses street and city without a separator.
      # Use the already-scraped city name as the split anchor.
      split_done <- FALSE
      if (!is.na(city) && nchar(city) > 0 && str_detect(li_clean, fixed(city))) {
        idx <- str_locate(li_clean, fixed(city))[1, "start"]
        address_line <- str_trim(substr(li_clean, 1L, idx - 1L))
        city_zip     <- str_trim(substr(li_clean, idx, nchar(li_clean)))
        split_done   <- TRUE
      }
      if (!split_done) address_line <- li_clean
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

# INCREMENTAL CHECKPOINTING. This loop used to hold every profile in memory
# and write once, after the loop. A full run is ~11.7k profiles at ~2.4s each,
# so that single write sat roughly seven hours downstream of the first fetch --
# and it had never once executed at that scale. Any kill, crash or laptop sleep
# lost the entire crawl with nothing to resume from, because DOX_RESUME reads
# the very file that would never have been written. Flush every
# CHECKPOINT_EVERY profiles instead, so the worst case is losing one chunk.
CHECKPOINT_EVERY <- suppressWarnings(as.integer(Sys.getenv("DOX_CHECKPOINT", "250")))

# Appended chunks must all carry the same columns in the same order. The error
# path of parse_profile() returns only 2 columns, so a chunk that happened to
# contain only errors would otherwise append a short row and silently shift
# every field to the wrong header on read-back.
PROFILE_COLS <- c("profile_url", "parse_status", "uuid", "date_created",
                  "date_modified", "full_name", "name_clean", "maiden_name",
                  "name_no_maiden", "specialty", "city", "state",
                  "address_line", "city_zip", "phone", "affiliation",
                  "bio_text")

conform <- function(x) {
  for (cc in setdiff(PROFILE_COLS, names(x))) x[[cc]] <- NA_character_
  x %>% mutate(across(everything(), as.character)) %>% select(all_of(PROFILE_COLS))
}

# A fresh (non-resume) run must not append onto a stale file from an earlier
# crawl; that would silently blend two runs.
if (!RESUME && file.exists(OUT_FILE)) file.remove(OUT_FILE)

flush_chunk <- function(buf) {
  if (!length(buf)) return(invisible(0L))
  chunk <- conform(bind_rows(buf))
  first <- !file.exists(OUT_FILE)
  write_csv(chunk, OUT_FILE, na = "", append = !first, col_names = first)
  invisible(nrow(chunk))
}

buf <- list()
written <- 0L
for (i in seq_along(pending)) {
  if (i %% 50 == 0)
    cat(sprintf("  %d / %d\n", i, length(pending)))
  buf[[length(buf) + 1L]] <-
    tryCatch(parse_profile(pending[i]),
             error = function(e)
               tibble(profile_url = pending[i], parse_status = "error"))
  if (length(buf) >= CHECKPOINT_EVERY) {
    written <- written + flush_chunk(buf); buf <- list()
    cat(sprintf("  checkpoint: %d profiles on disk\n", written))
  }
}
written <- written + flush_chunk(buf)

# Read back from disk rather than from memory, so the reported counts describe
# what was actually persisted.
profiles <- read_csv(OUT_FILE, show_col_types = FALSE, progress = FALSE)
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
