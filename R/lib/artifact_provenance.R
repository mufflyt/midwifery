#' @title Artifact freshness, by content rather than by clock
#'
#' @description
#' CYCLE 18. Two rate corrections (cycles 16 and 17) rebuilt
#' `data/county_base.csv` and left **seven** downstream artifacts describing the
#' old numbers, with nothing to say so. A reader opening
#' `geocoding_completeness_rucc.csv` sees a table, not a date.
#'
#' @section Why not modification time:
#' `file.mtime()` finds this today and will lie tomorrow. `git checkout`, `cp`,
#' `rsync` and archive extraction all rewrite mtimes, in either direction, so a
#' fresh clone can show every artifact "newer" than its inputs while containing
#' stale numbers. mtime is a useful smoke alarm and a bad contract.
#'
#' Provenance is therefore recorded by CONTENT: when an artifact is written, the
#' SHA-256 of every input that produced it is written beside it. An artifact is
#' stale when an input's current hash differs from the one recorded, which
#' survives copying, cloning and restoring from backup.
#'
#' Uses the canonical `sha256_of()` from R/lib/provenance.R rather than a
#' seventh local copy (see cycle 9).
#'
#' @family provenance

source(file.path("R", "lib", "provenance.R"))

#' Write an artifact together with the hashes of its inputs
#'
#' @param x [data.frame]: the artifact.
#' @param path [character(1)]: where to write it.
#' @param inputs [character]: paths this artifact was computed from.
#' @return `path`, invisibly.
#' @family provenance
#' Make a path repo-relative
#'
#' CYCLE 21. The first version recorded whatever path the caller passed, which
#' for `R/01` meant an ABSOLUTE one:
#'   "/Users/tylermuffly/midwifery/data/rucc_2023.xlsx"
#' On any other machine -- a clone, a collaborator, CI -- that file does not
#' exist, `check_provenance()` reports `current = NA`, and every artifact is
#' declared stale. That is the precise opposite of the property cycle 18 claimed
#' for this mechanism, which was that it survives copying and cloning where
#' mtime does not. Paths are therefore stored relative to the repo root.
#' @keywords internal
#' @noRd
.repo_relative <- function(p) {
  root <- normalizePath(".", winslash = "/", mustWork = FALSE)
  ab <- normalizePath(p, winslash = "/", mustWork = FALSE)
  ifelse(startsWith(ab, paste0(root, "/")), substring(ab, nchar(root) + 2L), p)
}

#' @param x [data.frame]: the artifact to write.
#' @param path [character(1)]: destination CSV path. The provenance sidecar is
#'   written alongside it as `<path>.provenance.json`.
#' @param inputs [character]: paths this artifact was derived from. Each is
#'   hashed with `sha256_of()` so a rerun against changed inputs is detectable
#'   rather than silent.
#' @param ... passed through to `readr::write_csv()`.
#' @return `path`, invisibly, so the call can be piped or assigned.
#' @examples
#' \dontrun{
#' write_with_provenance(county_tbl, "artifacts/county_base.csv",
#'                       inputs = c("data/acs.csv", "data/rucc.csv"))
#' check_provenance("artifacts/county_base.csv")   # stale inputs?
#' }
#' @seealso [check_provenance()], and `sha256_of()` in R/lib/provenance.R.
#'
#' CYCLE 21b. This used to hard-code `na = ""`. Of the 47 write sites in the
#' pipeline only 10 pass `na = ""` explicitly; the other 37 rely on readr's
#' default of `"NA"`. Converting them to a wrapper that forces `""` would have
#' rewritten every one of those artifacts -- silently changing how missingness
#' is represented in files this project has spent six cycles proving treat
#' missing and zero as different things. The wrapper now changes provenance
#' only, never content.
#' The code that produced an artifact, not just the data
#'
#' Provenance recorded input SHAs and nothing else, so a change to the CODE
#' left every sidecar unchanged and every artifact validating. That is not
#' hypothetical: removing the middle-name edit-distance tolerance moved the
#' linkage cohort by 19 records while touching only R/amcb_match_rules.R, and
#' no artifact, no sidecar and no gate in this repository could say so. An
#' artifact whose inputs are unchanged but whose producing code has changed is
#' exactly as stale as one whose inputs moved, and until now only the second
#' kind was detectable.
#'
#' The set is derived by following `source()` calls from the entry script,
#' transitively. Call sites here write `source(file.path(root_dir, "R",
#' "amcb_name_keys.R"))`, so the string literals inside the call are joined as
#' a path and resolved the same way `prov_inputs()` resolves a bare name. A
#' file that cannot be resolved is reported, never silently dropped -- the
#' lesson prov_inputs() already paid for.
#'
#' @param entry [character(1)]: the script to start from; defaults to the
#'   running script, from `commandArgs()`.
#' @param max_depth [integer(1)]: recursion cap, so a source() cycle cannot hang.
#' @return [character] repo-relative paths, sorted and deduplicated.
#' @keywords internal
#' @noRd
.code_closure <- function(entry = NULL, max_depth = 8L) {
  if (is.null(entry)) {
    a <- grep("^--file=", commandArgs(), value = TRUE)
    entry <- if (length(a)) sub("^--file=", "", a[[1L]]) else NA_character_
  }
  if (is.na(entry) || !file.exists(entry)) return(character(0))

  seen <- character(0)
  visit <- function(f, depth) {
    f <- .repo_relative(f)
    if (f %in% seen || depth > max_depth || !file.exists(f)) return(invisible(NULL))
    seen <<- c(seen, f)
    ex <- tryCatch(parse(f), error = function(e) NULL)
    if (is.null(ex)) return(invisible(NULL))
    # Walk the parse tree for source()/sys.source() and rebuild the path from
    # the string literals in the call, which is how this repo writes them.
    walk <- function(node) {
      if (is.call(node)) {
        fn <- node[[1L]]
        if (is.name(fn) && as.character(fn) %in% c("source", "sys.source")) {
          lits <- unlist(lapply(as.list(node)[-1L], function(a)
            if (is.character(a)) a
            else if (is.call(a)) Filter(is.character, as.list(a)[-1L])
            else NULL), use.names = FALSE)
          lits <- unlist(lits, use.names = FALSE)
          if (length(lits)) {
            cand <- do.call(file.path, as.list(lits))
            hit <- .resolve_code_path(cand)
            if (!is.na(hit)) visit(hit, depth + 1L)
          }
        }
        # The gap in `x[, 1]` parses to the empty symbol. Binding it to a loop
        # variable makes ANY later use of that variable raise "argument is
        # missing", so it cannot be tested after binding -- compare the
        # one-element sublist instead, which never evaluates it.
        args <- as.list(node)[-1L]
        for (i in seq_along(args)) {
          if (identical(args[i], list(quote(expr = )))) next
          walk(args[[i]])
        }
      } else if (is.pairlist(node) || is.expression(node) || is.list(node)) {
        args <- as.list(node)
        for (i in seq_along(args)) {
          if (identical(args[i], list(quote(expr = )))) next
          walk(args[[i]])
        }
      }
      invisible(NULL)
    }
    for (e in as.list(ex)) walk(e)
    invisible(NULL)
  }
  visit(entry, 0L)
  sort(unique(seen))
}

#' @keywords internal
#' @noRd
.resolve_code_path <- function(x) {
  if (file.exists(x)) return(x)
  cand <- file.path(c(".", "R", "R/lib"), x)
  hit <- cand[file.exists(cand)]
  if (length(hit)) return(hit[[1L]])
  NA_character_
}

#' A single fingerprint over the producing code
#'
#' One value the reader can compare at a glance, alongside the per-file list.
#' @keywords internal
#' @noRd
.code_fingerprint <- function(paths) {
  if (!length(paths)) return(NA_character_)
  h <- vapply(paths, sha256_of, character(1), USE.NAMES = FALSE)
  digest::digest(paste(sort(paste(paths, h)), collapse = "\n"),
                 algo = "sha256", serialize = FALSE)
}

write_with_provenance <- function(x, path, inputs = character(0), ...) {
  readr::write_csv(x, path, ...)
  inputs <- inputs[file.exists(inputs)]
  side <- paste0(path, ".provenance.json")
  code <- tryCatch(.code_closure(), error = function(e) character(0))
  jsonlite::write_json(
    list(artifact = basename(path),
         written_utc = format(Sys.time(), tz = "UTC", usetz = TRUE),
         inputs = if (length(inputs))
           lapply(inputs, function(p) list(path = .repo_relative(p),
                                           sha256 = sha256_of(p)))
         else list(),
         # The producing code, by content. See .code_closure().
         code_sha256 = .code_fingerprint(code),
         code = if (length(code))
           lapply(code, function(p) list(path = p, sha256 = sha256_of(p)))
         else list()),
    side, auto_unbox = TRUE, pretty = TRUE)
  invisible(path)
}

#' Check an artifact against the inputs it recorded
#'
#' @param path [character(1)]: the artifact.
#' @return [data.frame] one row per input: `path`, `recorded`, `current`,
#'   `stale`. Zero rows when no sidecar exists, which is itself reportable.
#' @family provenance
check_provenance <- function(path) {
  side <- paste0(path, ".provenance.json")
  empty <- data.frame(path = character(0), recorded = character(0),
                      current = character(0), stale = logical(0),
                      kind = character(0))
  if (!file.exists(side)) return(empty)
  m <- jsonlite::read_json(side, simplifyVector = FALSE)
  rows <- function(entries, kind) {
    if (!length(entries)) return(NULL)
    do.call(rbind, lapply(entries, function(i) {
      cur <- if (file.exists(i$path)) sha256_of(i$path) else NA_character_
      data.frame(path = i$path, recorded = i$sha256, current = cur,
                 stale = !identical(cur, i$sha256), kind = kind,
                 stringsAsFactors = FALSE)
    }))
  }
  # `code` is reported exactly like `inputs`. An artifact whose data is
  # untouched but whose producing code has changed is stale in the only sense
  # that matters -- rerunning would not reproduce it -- and reporting only the
  # first kind is how a matcher change moved the cohort by 19 records with
  # every sidecar still validating.
  out <- rbind(rows(m$inputs, "input"), rows(m$code, "code"))
  if (is.null(out)) return(empty)
  out
}

#' Collect the input paths that exist
#'
#' @description
#' CYCLE 21b. The first wiring gave each of the 14 numbered scripts its own
#' `.prov_inputs()` definition -- fourteen copies of one function, which is
#' precisely the duplicate-definition class this project has paid for six times
#' and which cycle 9's T84 exists to catch. It caught this one, in code written
#' by the cycle that added the guard's sibling.
#'
#' One definition; each script passes its own paths.
#'
#' @param ... paths, given as literals or as the script's own path constants.
#' @return [character] those that exist, in the order supplied.
#' @family provenance
#' Declare the geocoding cache as an input, by content
#'
#' A cache that decides coordinates is a scientific input, and until this
#' existed none of the 112 provenance sidecars in this repository named one:
#' 14 artifacts were transitively cache-dependent and 0 recorded which cache
#' they used. Any stage that consults the cache should append this to its
#' inputs so a later reader can tell C_v from C_v+1.
#'
#' Content-derived, not mtime. See R/lib/cache_vintage.R for why, and for what
#' counts as scientifically relevant.
#'
#' @param path [character]: the DuckDB cache.
#' @return [character] one declared-input token carrying entry count and hash,
#'   or a token that says the cache was unavailable -- never nothing, because a
#'   silently absent declaration is the defect this replaces.
#' @keywords internal
#' @noRd
prov_cache_input <- function(path) {
  vf <- file.path("R", "lib", "cache_vintage.R")
  if (!exists("geocode_cache_fingerprint", mode = "function")) {
    if (!file.exists(vf)) return(sprintf("geocode_cache:UNAVAILABLE:%s", basename(path)))
    source(vf, local = FALSE)
  }
  fp <- geocode_cache_fingerprint(path)
  if (!isTRUE(fp$available))
    return(sprintf("geocode_cache:UNAVAILABLE:%s:%s", basename(path), fp$reason))
  sprintf("geocode_cache:%s:n=%d:sha256=%s", basename(path), fp$n_entries,
          substr(fp$content_sha256, 1, 32))
}

prov_inputs <- function(..., roots = c(".", "artifacts", "data"), quiet = FALSE) {
  p <- unlist(list(...), use.names = FALSE)
  p <- p[!is.na(p) & nzchar(p)]

  # WHY THIS IS NOT `p[file.exists(p)]` ANY MORE.
  #
  # It was, and that one expression is why provenance in this repository looks
  # complete and is not. Call sites pass bare basenames -- prov_inputs(
  # "county_base.csv") -- while the file lives at data/county_base.csv. The
  # path did not resolve, so it was dropped, so the sidecar recorded one fewer
  # input, and nothing said a word. An audit found 71 of 93 literal input paths
  # in this repository being discarded exactly that way: 76% of every input
  # anyone declared.
  #
  # A silently short provenance record is worse than none. It answers "what
  # produced this?" with a confident, incomplete list, and the reader cannot
  # tell the difference. Recovering one such omission -- which coordinate file
  # built the geography artifact -- took hours of comparing GEOID fill rates
  # against a percentage quoted in the README.
  #
  # So: resolve a bare name against the roots it is almost certainly relative
  # to, and if it still cannot be found, SAY SO. A declared input that is not
  # there is either a typo or a missing file, and both are worth knowing before
  # the artifact is written rather than after it is published.
  # artifacts/ has one level of subdirectories -- frozen_cohort, county_profiles,
  # district_profiles, ab_middle_name, bc_resolver -- and 20 of the 22 inputs
  # that still could not be found were simply in one of them. Search them too,
  # one level only: deeper recursion starts matching same-named files in
  # unrelated trees, and an input resolved to the wrong file is worse than one
  # reported missing.
  search_roots <- unique(c(roots,
    list.dirs("artifacts", recursive = FALSE, full.names = TRUE)))

  resolve_one <- function(x) {
    if (file.exists(x)) return(x)
    cand <- file.path(search_roots, x)
    hit <- cand[file.exists(cand)]
    if (length(hit) == 1L) return(hit)
    if (length(hit) > 1L) {
      warning(sprintf(
        "prov_inputs(): '%s' is ambiguous -- it exists at %s. Pass the path you mean.",
        x, paste(hit, collapse = " and ")), call. = FALSE)
      return(hit[[1L]])
    }
    NA_character_
  }

  resolved <- vapply(p, resolve_one, character(1), USE.NAMES = FALSE)

  missing <- p[is.na(resolved)]
  if (length(missing) && !isTRUE(quiet)) {
    warning(sprintf(paste0(
      "prov_inputs(): %d declared input(s) could not be found and will NOT be ",
      "recorded in the sidecar:\n  %s\nSearched: %s. ",
      "An input that is not recorded cannot be traced later."),
      length(missing), paste(missing, collapse = "\n  "),
      paste(roots, collapse = ", ")), call. = FALSE)
  }

  resolved[!is.na(resolved)]
}
