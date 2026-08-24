#!/usr/bin/env Rscript
# =============================================================================
# L8: identical scientific inputs must produce identical scientific outputs
# =============================================================================
# THE LAW
#
#   f(X) = f(pi(X)) for any row permutation pi, and repeated evaluation, and
#   any chunk size, and any order the filesystem happens to enumerate in.
#
# WHY THIS IS NOT ALREADY OBVIOUS. Three constructs in this pipeline decide an
# answer by position rather than by value:
#
#   slice_max(land, n = 1, with_ties = FALSE) in zip_county_crosswalk.R picks a
#   county for a ZCTA. With ties broken by ROW ORDER, a permuted input could
#   assign a different county. There are zero real ties in the current Census
#   file -- checked, not assumed -- so this is latent, not live. It is tested
#   because "no ties today" is a property of the data, not of the code.
#
#   list.files() in osmde_cache_keys() enumerates the cache in whatever order
#   the filesystem returns, which is not guaranteed stable across machines.
#
#   osmde_assemble(chunk = 500L) batches. A batch boundary that changed an
#   aggregate would make the answer depend on a performance parameter.
#
# BOTH CONTROLS. The negative control is that permutation changes nothing. The
# positive control is that a REAL change to a scientific input DOES change the
# fingerprint -- without it, a pipeline that emitted a constant would satisfy
# every assertion here and prove nothing at all.
#
# Public: the Census relationship file and synthetic cache entries. No
# person-level data.
# =============================================================================

suppressPackageStartupMessages({ library(dplyr); library(readr); library(sf) })
sf::sf_use_s2(FALSE)

root <- {
  a <- grep("--file=", commandArgs(), value = TRUE)
  if (length(a)) normalizePath(file.path(dirname(sub("--file=", "", a[1])), ".."))
  else normalizePath(".")
}
setwd(root)
source(file.path("R", "lib", "common_helpers.R"))
source(file.path("R", "lib", "zip_county_crosswalk.R"))
source(file.path("R", "lib", "osmde_cache.R"))

fails <- 0L
chk <- function(cond, m) if (isTRUE(cond)) cat(sprintf("  ok   %s\n", m)) else {
  fails <<- fails + 1L; cat(sprintf("  FAIL %s\n", m)) }

XW <- file.path("data", "zcta_county_2020.txt")
if (!file.exists(XW)) {
  cat(sprintf("  FAIL required public input absent: %s\n", XW))
  cat("       It is tracked; absence means L8 is not being evaluated.\n\nFAILED (1)\n")
  quit(status = 1)
}

# Canonical fingerprint: sort rows and columns, then hash. Semantic equality
# rather than byte equality -- a legitimate difference in serialisation order
# must not read as a scientific difference, and a scientific difference must not
# hide behind one.
fingerprint <- function(d) {
  d <- as.data.frame(d, stringsAsFactors = FALSE)
  d <- d[, sort(names(d)), drop = FALSE]
  d <- d[do.call(order, lapply(d, as.character)), , drop = FALSE]
  rownames(d) <- NULL
  digest_chr <- paste(capture.output(print(d, max = .Machine$integer.max)), collapse = "\n")
  substr(openssl::sha256(digest_chr), 1, 32)
}

n_pos <- 0L; n_neg <- 0L

# --- 1. the ZIP->county crosswalk, under permutation -------------------------
cat("\n-- the crosswalk is invariant to the order of its source rows --\n")
raw <- readLines(XW, warn = FALSE)
hdr <- raw[1]; body <- raw[-1]
perm_file <- function(idx, path) { writeLines(c(hdr, body[idx]), path); path }

tmp <- file.path(tempdir(), "det"); dir.create(tmp, showWarnings = FALSE)
base_fp <- fingerprint(zip_county_dominant(XW))
set.seed(8L)
for (i in 1:3) {
  p <- perm_file(sample(seq_along(body)), file.path(tmp, sprintf("perm%d.txt", i)))
  n_neg <- n_neg + 1L
  chk(identical(fingerprint(zip_county_dominant(p)), base_fp),
      sprintf("permutation %d of %s source rows leaves the crosswalk identical",
              i, format(length(body), big.mark = ",")))
}
n_neg <- n_neg + 1L
chk(identical(fingerprint(zip_county_dominant(XW)), base_fp),
    "and a repeated run of the unpermuted file agrees with itself")

# --- 2. the cache assembly, under chunk size and enumeration order ----------
cat("\n-- cache assembly is invariant to chunk size --\n")
mk_entry <- function(dir, lat, lng, band) {
  poly <- sf::st_sf(contour = band,
                    geometry = sf::st_sfc(sf::st_polygon(list(rbind(
                      c(lng, lat), c(lng + .01, lat), c(lng + .01, lat + .01),
                      c(lng, lat + .01), c(lng, lat)))), crs = 4326))
  osmde_cache_put(dir, sprintf("%.6f_%.6f", lat, lng), poly, "2026-01-01T00:00:00")
}
cdir <- file.path(tempdir(), "det_cache"); unlink(cdir, recursive = TRUE); dir.create(cdir)
set.seed(11L)
for (i in 1:24) mk_entry(cdir, 39 + i / 100, -104 - i / 100, if (i %% 2) 30 else 60)

asm <- function(ch) fingerprint(sf::st_drop_geometry(
  suppressMessages(osmde_assemble(cdir, chunk = ch, verbose = FALSE))))
a_default <- asm(500L)
for (ch in c(1L, 3L, 7L, 1000L)) {
  n_neg <- n_neg + 1L
  chk(identical(asm(ch), a_default), sprintf("chunk = %-5d gives the same assembly", ch))
}

cat("\n-- and to the order the cache is enumerated in --\n")
# osmde_cache_keys() uses list.files(), whose order is not guaranteed across
# filesystems. Rebuild the same entries under names that enumerate differently
# and require the same scientific content.
cdir2 <- file.path(tempdir(), "det_cache2"); unlink(cdir2, recursive = TRUE); dir.create(cdir2)
ks <- osmde_cache_keys(cdir)
for (k in rev(ks)) file.copy(osmde_cache_path(cdir, k), osmde_cache_path(cdir2, k))
n_neg <- n_neg + 1L
chk(identical(asm(500L), fingerprint(sf::st_drop_geometry(
      suppressMessages(osmde_assemble(cdir2, chunk = 500L, verbose = FALSE))))),
    "a cache written in reverse order assembles identically")

# --- 3. POSITIVE CONTROL -----------------------------------------------------
# Without this, a function returning a constant passes every assertion above.
cat("\n-- positive control: a real input change MUST move the fingerprint --\n")
# CHOSEN, not arbitrary. The first attempt removed row 1 and the fingerprint did
# not move -- correctly, because that row is not the winning county for its ZCTA,
# so the dominant-county answer is unchanged. A positive control that removes
# something which does not matter proves nothing; it has to remove something that
# does. Every row for one ZCTA is dropped, so that ZCTA must leave the crosswalk.
# BY FIELD, not by regex on the line. GEOID_ZCTA5_20 is the SECOND column --
# the first is OID_ZCTA5_20 -- so anchoring the ZCTA to the start of the line
# matched nothing and the control silently removed no rows at all. A positive
# control that removes nothing looks exactly like a pipeline that ignores its
# input, which is the failure it exists to rule out.
zcta_col <- match("GEOID_ZCTA5_20", strsplit(sub("^\ufeff", "", hdr), "|", fixed = TRUE)[[1]])
stopifnot(!is.na(zcta_col))
body_zcta <- vapply(strsplit(body, "|", fixed = TRUE),
                    function(p) if (length(p) >= zcta_col) p[zcta_col] else NA_character_,
                    character(1))
victim <- zip_county_dominant(XW)$zip5[1]
keep <- !(pad5(body_zcta) %in% victim)
drop1 <- perm_file(which(keep), file.path(tmp, "drop1.txt"))
n_pos <- n_pos + 1L
dropped <- zip_county_dominant(drop1)
chk(!identical(fingerprint(dropped), base_fp) && !(victim %in% dropped$zip5),
    sprintf("removing every source row for ZCTA %s drops it and moves the fingerprint", victim))

cdir3 <- file.path(tempdir(), "det_cache3"); unlink(cdir3, recursive = TRUE); dir.create(cdir3)
for (k in ks[-1]) file.copy(osmde_cache_path(cdir, k), osmde_cache_path(cdir3, k))
n_pos <- n_pos + 1L
chk(!identical(fingerprint(sf::st_drop_geometry(
      suppressMessages(osmde_assemble(cdir3, chunk = 500L, verbose = FALSE)))), a_default),
    "removing one cache entry changes the assembly fingerprint")

n_pos <- n_pos + 1L
chk(nchar(base_fp) == 32L && base_fp != fingerprint(data.frame(x = 1)),
    "the fingerprint distinguishes different content at all")

# --- 4. the latent tie-break, stated -----------------------------------------
cat("\n-- the latent tie-break, checked rather than assumed --\n")
z <- read_delim(XW, delim = "|", show_col_types = FALSE, progress = FALSE) %>%
  transmute(zip5 = pad5(GEOID_ZCTA5_20),
            land = suppressWarnings(as.numeric(AREALAND_PART))) %>%
  filter(!is.na(zip5))
ties <- z %>% group_by(zip5) %>% filter(n() > 1, land == max(land)) %>%
  tally() %>% filter(n > 1)
n_neg <- n_neg + 1L
chk(nrow(ties) == 0L,
    sprintf("no ZCTA has a tied largest land part (%d found)", nrow(ties)))
if (nrow(ties)) cat("       slice_max(with_ties = FALSE) would decide these by ROW ORDER.\n")

cat("\n")
cat("[LAW] L8 EXERCISED\n")
cat(sprintf("[CONTROL] L8 negative n=%d\n", n_neg))
cat(sprintf("[CONTROL] L8 positive n=%d\n", n_pos))
if (fails) { cat(sprintf("FAILED (%d)\n", fails)); quit(status = 1) }
cat("PASS (0 failures)\n")
