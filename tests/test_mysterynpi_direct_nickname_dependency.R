#!/usr/bin/env Rscript

root <- {
  a <- grep("--file=", commandArgs(), value = TRUE)
  if (length(a)) normalizePath(file.path(dirname(sub("--file=", "", a[1])), ".."))
  else normalizePath(".")
}
setwd(root)

fails <- 0L
checks <- 0L
ok <- function(m) {
  checks <<- checks + 1L
  cat(sprintf("  ok   %s\n", m))
}
bad <- function(m) {
  checks <<- checks + 1L
  fails <<- fails + 1L
  cat(sprintf("  FAIL %s\n", m))
}
chk <- function(cond, m) if (isTRUE(cond)) ok(m) else bad(m)

if (!requireNamespace("mysterynpi", quietly = TRUE)) {
  stop("mysterynpi is required for direct nickname dependency test",
       call. = FALSE)
}

src <- readLines(file.path("R", "lib", "isochrones_dep.R"), warn = FALSE)
chk(!any(grepl('"nickname_system[.]R"|"enhanced_name_parsing[.]R"', src)),
    "isochrones nickname files are not in the loader dependency list")

fake_root <- tempfile("fake_isochrones_")
fake_r <- file.path(fake_root, "R")
dir.create(file.path(fake_r, "utils"), recursive = TRUE)
writeLines(
  "luhn_check_npi <- function(x) TRUE",
  file.path(fake_r, "utils", "npi_luhn_qa.R")
)
writeLines(
  "normalize_string <- function(x) toupper(trimws(x))",
  file.path(fake_r, "string_normalization.R")
)
writeLines(
  "parse_physician_name_enhanced <- function(x) data.frame(first_name = 'BETH', middle_name = NA_character_, last_name = 'SMITH')",
  file.path(fake_r, "name_parsing_protocol_enhanced.R")
)

Sys.setenv(ISOCHRONES_R = fake_r)
source(file.path("R", "lib", "isochrones_dep.R"))
load_isochrones_name_tools(quiet = TRUE)

chk(exists("luhn_check_npi", mode = "function"),
    "loader still provides the isochrones Luhn helper")
chk(exists("parse_physician_name_enhanced", mode = "function"),
    "loader still provides the isochrones parser helper")
chk(are_nickname_variants("BETH", "ELIZABETH"),
    "nickname variants resolve directly through mysterynpi")
chk(!are_nickname_variants("J", "JOHN"),
    "initial/full-name compatibility is not nickname evidence")

if (checks < 5L) {
  stop(sprintf("only %d checks ran; test decayed", checks), call. = FALSE)
}
if (fails > 0L) {
  stop(sprintf("%d checks failed", fails), call. = FALSE)
}
cat(sprintf("PASS test_mysterynpi_direct_nickname_dependency: %d checks\n", checks))
