#!/usr/bin/env Rscript
# =============================================================================
# osmde_assemble() must assemble in BOUNDED CHUNKS, not one giant bind
# =============================================================================
# WHY THIS TEST EXISTS AND WHAT IT IS GUARDING.
#
# Commit 5408ce5 (#68) merged an intermediate osmde_assemble() into main that
# rebinds the accumulated result once per chunk:
#
#     out <- if (is.null(out)) part else rbind(out, part)
#
# That copies the entire accumulated `sf` on every iteration. At the 8,359
# locations this project actually routed, it is quadratic in what is already the
# largest object in memory. The fix accumulates chunks in a list and binds once.
#
# A test that only checked "does assembly return the right rows" would pass
# against BOTH implementations, so it would not prove the slow one is gone. This
# test therefore asserts the property that distinguishes them, two independent
# ways:
#
#   1. BEHAVIOURAL. Peak intermediate size is bounded. The quadratic version
#      materialises an object of the full N on every chunk; the chunked version
#      never materialises more than one chunk until the final bind. We observe
#      this by counting rbind() calls and the sizes they are handed.
#
#   2. STRUCTURAL. The accumulate-onto-a-growing-object pattern is absent from
#      the source. This is the direct "replaced, not supplemented" check, and it
#      is the one that fails loudly if someone reintroduces #68's loop.
#
# Correctness is checked too -- a fast assembler that drops rows is worse than a
# slow one.
# =============================================================================
suppressPackageStartupMessages({ library(sf) })

root <- if (basename(getwd()) == "tests") ".." else "."
source(file.path(root, "R", "lib", "osmde_cache.R"))

pass <- 0L; fail <- 0L
ok <- function(what, cond) {
  if (isTRUE(cond)) { pass <<- pass + 1L; cat(sprintf("  PASS  %s\n", what)) }
  else { fail <<- fail + 1L; cat(sprintf("  FAIL  %s\n", what)) }
}

# --- a synthetic cache large enough that the distinction matters -------------
# 1,200 locations over 3 chunks of 500. Small enough to run in CI, large enough
# that a quadratic accumulator is unambiguously doing the wrong thing.
N <- 1200L
tmp <- file.path(tempdir(), paste0("osmde_cache_test_", Sys.getpid()))
dir.create(tmp, recursive = TRUE, showWarnings = FALSE)
on.exit(unlink(tmp, recursive = TRUE), add = TRUE)

square <- function(lon, lat, r) {
  sf::st_polygon(list(cbind(
    c(lon - r, lon + r, lon + r, lon - r, lon - r),
    c(lat - r, lat - r, lat + r, lat + r, lat - r))))
}
set.seed(1)
lons <- round(runif(N, -120, -70), 6)
lats <- round(runif(N,   26,  48), 6)
keys <- sprintf("%.6f_%.6f", lats, lons)
keys <- make.unique(keys, sep = "0")   # collisions would silently shrink N

for (i in seq_len(N)) {
  g <- sf::st_sf(
    contour  = c(30, 60),
    geometry = sf::st_sfc(square(lons[i], lats[i], 0.10),
                          square(lons[i], lats[i], 0.20), crs = 4326))
  osmde_cache_put(tmp, keys[i], g, "2026-08-16T00:00:00Z")
}
cat(sprintf("synthetic cache: %s locations, %s files\n\n",
            N, length(list.files(tmp))))

# --- 1. BEHAVIOURAL: no bind ever receives the whole accumulated object ------
cat("[1] assembly binds bounded chunks, never a growing accumulator\n")
seen <- new.env(parent = emptyenv())
seen$sizes <- integer(0)
trace_rbind <- function(...) {
  args <- list(...)
  # Record the largest single operand handed to each rbind of sf objects.
  sz <- vapply(args, function(a) if (inherits(a, "sf")) nrow(a) else 0L, integer(1))
  seen$sizes <- c(seen$sizes, max(sz, 0L))
  base::rbind(...)
}

env <- new.env(parent = environment(osmde_assemble))
assign("rbind", trace_rbind, envir = env)
probe <- osmde_assemble
environment(probe) <- env

out <- probe(tmp, chunk = 500L, verbose = FALSE)

# The final bind legitimately sees chunk-sized operands (500 locations x 2
# bands = 1,000 rows). What must NEVER appear is an operand approaching the full
# 2N, which is the signature of rbind(out, part) on a growing `out`.
CHUNK_ROWS <- 500L * 2L
worst <- max(seen$sizes)
cat(sprintf("      rbind calls observed : %s\n", length(seen$sizes)))
cat(sprintf("      largest operand rows : %s (one chunk = %s, full set = %s)\n",
            worst, CHUNK_ROWS, N * 2L))
ok("no rbind operand exceeds one chunk", worst <= CHUNK_ROWS)

# Scale sensitivity is the sharp discriminator. Under the chunked version the
# largest operand tracks CHUNK SIZE, so halving the chunk halves it. Under an
# accumulator it tracks TOTAL SIZE, so shrinking the chunk makes the peak worse,
# not better -- more iterations means the growing object is copied at a larger
# size more often.
#
# An earlier draft asserted only `worst < N * 2`, which the #68 implementation
# satisfied (its final bind peaks at 2/3 of the full set with three chunks) and
# therefore green-lit the bug it was written to catch.
seen$sizes <- integer(0)
invisible(probe(tmp, chunk = 250L, verbose = FALSE))
worst_half <- max(seen$sizes)
cat(sprintf("      halving chunk 500->250 moves peak %s -> %s\n", worst, worst_half))
ok("peak operand scales with CHUNK size, not total size",
   worst_half <= 250L * 2L)

# The quadratic version calls rbind once per chunk to grow `out`, PLUS once per
# chunk to build the chunk = ~2 per chunk with a growing operand. The chunked
# version binds each chunk, then binds the list once.
ok("bind count is O(chunks), not O(chunks) with growth",
   length(seen$sizes) <= (ceiling(N / 500) * 2L) + 2L)

# --- 2. STRUCTURAL: #68's accumulator pattern is absent ----------------------
cat("\n[2] the accumulate-onto-growing-object pattern is gone from source\n")
src <- paste(readLines(file.path(root, "R", "lib", "osmde_cache.R"),
                       warn = FALSE), collapse = "\n")
body_txt <- paste(deparse(body(osmde_assemble)), collapse = "\n")

# The exact shape merged in #68.
ok("no `rbind(out, part)` accumulator",
   !grepl("rbind\\s*\\(\\s*out\\s*,", body_txt))
ok("no `out <- if (is.null(out))` growth idiom",
   !grepl("out\\s*<-\\s*if\\s*\\(\\s*is\\.null\\s*\\(\\s*out\\s*\\)", body_txt))
ok("binds a collected list exactly once",
   grepl("do\\.call\\s*\\(\\s*rbind\\s*,\\s*parts\\s*\\)", body_txt))
ok("source documents why (regression note present)",
   grepl("quadratic", src))

# --- 3. correctness: fast must not mean lossy --------------------------------
cat("\n[3] assembly is still correct\n")
ok("one row per location per band", nrow(out) == N * 2L)
ok("all locations present",         dplyr::n_distinct(out$location_key) == N)
ok("both bands, nothing else",      identical(sort(unique(out$drive_time_minutes)),
                                              c(30, 60)))
ok("CRS is 4326",                   sf::st_crs(out)$epsg == 4326L)
ok("geometry cast to MULTIPOLYGON",
   all(as.character(sf::st_geometry_type(out)) == "MULTIPOLYGON"))
ok("provenance columns survive assembly",
   all(c("routing_engine", "routing_scope", "generated_utc") %in% names(out)) &&
     all(out$routing_engine == "valhalla1.openstreetmap.de"))

# --- 4. a chunk size that does not divide N evenly ---------------------------
# The final partial chunk is where an off-by-one drops locations silently.
cat("\n[4] ragged final chunk loses nothing\n")
out7 <- osmde_assemble(tmp, chunk = 7L, verbose = FALSE)
ok("chunk=7 yields the same locations",
   setequal(unique(out7$location_key), unique(out$location_key)))
ok("chunk=7 yields the same row count", nrow(out7) == nrow(out))

# --- 5. an unreadable cache entry is skipped, not fatal ----------------------
cat("\n[5] a corrupt cache file degrades gracefully\n")
writeLines("not an rds", file.path(tmp, "0.000000_0.000000.rds"))
out_c <- suppressWarnings(osmde_assemble(tmp, chunk = 500L, verbose = FALSE))
ok("corrupt entry skipped, rest assembled", nrow(out_c) == N * 2L)

cat(sprintf("\n%s passed, %s failed\n", pass, fail))
if (fail) quit(status = 1L)
