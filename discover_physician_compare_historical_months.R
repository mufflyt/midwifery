#!/usr/bin/env Rscript
# =============================================================================
# Which NBER-mirrored Physician Compare months actually serve a real CSV,
# 2014-2020 (2013 already covered by acquire_physician_compare_2013.R)
# =============================================================================
# Same discovery/probe logic as acquire_physician_compare_2013.R, generalized
# across years, and deliberately download-nothing -- this only answers "is
# there a file here" so the real multi-GB pull can target real months instead
# of guessing.
# =============================================================================
suppressPackageStartupMessages({library(dplyr); library(httr2); library(stringr); library(purrr)})

BROWSER_UA <- paste("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)",
                    "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36")
NBER_BASE <- "https://data.nber.org/compare/physician"

list_directory <- function(url) {
  response <- tryCatch(
    request(url) |> req_user_agent(BROWSER_UA) |> req_timeout(60) |> req_perform(),
    error = function(e) NULL)
  if (is.null(response)) return(character(0))
  hrefs <- stringr::str_match_all(resp_body_string(response), 'href="([^"]+)"')[[1]][, 2]
  hrefs[!stringr::str_detect(hrefs, "^[?/]")]
}

probe_month <- function(year, month) {
  url <- sprintf("%s/%d/%s/National_Downloadable_File.csv", NBER_BASE, year, month)
  handle <- curl::new_handle(useragent = BROWSER_UA, connecttimeout = 30)
  connection <- curl::curl(url, open = "", handle = handle)
  first_line <- tryCatch({
    open(connection, "r")
    line <- readLines(connection, n = 1L, warn = FALSE)
    if (length(line) == 0L) "" else line[[1]]
  }, error = function(e) NA_character_)
  try(close(connection), silent = TRUE)
  status <- tryCatch(curl::handle_data(handle)$status_code, error = function(e) NA_integer_)
  header_ok <- !is.na(first_line) &&
    stringr::str_detect(first_line, stringr::regex("NPI", ignore_case = TRUE)) &&
    stringr::str_detect(first_line, stringr::regex("special", ignore_case = TRUE))
  tibble::tibble(year = year, month = month, url = url, status = as.integer(status),
                 header_ok = header_ok,
                 header_line = if (is.na(first_line)) NA_character_ else substr(first_line, 1, 200))
}

for (y in 2014:2020) {
  dirs <- list_directory(paste0(NBER_BASE, "/", y, "/")) |>
    (\(x) x[stringr::str_detect(x, "^[0-9]{2}/$")])() |>
    stringr::str_remove("/$") |> sort()
  cat(sprintf("\n%d: advertised months: %s\n", y,
              if (length(dirs)) paste(dirs, collapse = ", ") else "(none)"))
  if (!length(dirs)) next
  probes <- purrr::map_dfr(dirs, ~probe_month(y, .x))
  ok <- probes |> filter(header_ok)
  cat(sprintf("%d: REAL files at: %s\n", y,
              if (nrow(ok)) paste(ok$month, collapse = ", ") else "(none)"))
}
