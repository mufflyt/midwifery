# =============================================================================
# Which numbers in the manuscript are allowed to be typed
# =============================================================================
# NOT a "no digits in prose" checker. That rule is wrong about most of a paper
# -- years, citation keys, RUCC bands, section numbers, a 95% confidence level,
# a 60% land-share threshold and a SHA-256 are all legitimate literals -- and a
# checker that is wrong most of the time gets an exemption written for it and
# then protects nothing.
#
# The scope is a REGISTRY of protected scientific quantities: results that have
# a canonical source and must never be independently typed. Everything outside
# the registry is out of scope by design. A number is a defect here only if it
# is a protected result appearing as a literal, which is a narrow claim and a
# checkable one.
#
# Prefixed mn_ because ci_hygiene.R H4 fails on a function defined at top level
# in two tracked files, and `render` is exactly the kind of verb that collides.
# =============================================================================

#' Prose only: no code chunks, no inline `r ...` expressions
#'
#' An inline call carries its own format string -- `"%.1f"` -- and a chunk
#' carries the arithmetic. Neither is prose, and scanning them finds the
#' generator rather than a typed literal, which is backwards.
#' @keywords internal
#' @noRd
mn_prose_lines <- function(lines) {
  fence <- grepl("^```", lines)
  in_chunk <- (cumsum(fence) %% 2) == 1 | fence
  out <- lines
  out[in_chunk] <- ""
  gsub("`r [^`]*`", "", out)
}

#' Catalog keys the manuscript reaches for
#' @keywords internal
#' @noRd
mn_keys_used <- function(lines) {
  m <- regmatches(lines, gregexpr("mw_(safe_stat|stat|n)\\(\"[^\"]+\"", lines))
  k <- sub(".*\\(\"", "", sub("\"$", "", unlist(m)))
  unique(k)
}

#' Fetch a dotted path out of the catalog
#' @keywords internal
#' @noRd
mn_get <- function(catalog, path) {
  v <- catalog
  for (p in strsplit(path, ".", fixed = TRUE)[[1]]) {
    if (!is.list(v) || is.null(v[[p]])) return(NULL)
    v <- v[[p]]
  }
  v
}

#' Every way a protected value could plausibly be typed
#'
#' A count is written 14,861 in prose and 14861 in a table, and both are the
#' same typed literal. A percentage is written at the precision the paper
#' reports it at, which the registry declares, because 89.3 and 89.34 are
#' different literals and only one of them is the one that drifts.
#' @keywords internal
#' @noRd
mn_render <- function(value, fmt) {
  if (is.null(value) || !is.finite(value)) return(character(0))
  out <- character(0)
  for (f in trimws(strsplit(fmt, ",", fixed = TRUE)[[1]])) {
    if (identical(f, "n")) {
      out <- c(out, formatC(value, format = "d", big.mark = ","),
               formatC(value, format = "d"))
    } else {
      out <- c(out, sprintf(f, value))
    }
  }
  unique(out[nzchar(out)])
}

#' Where a literal appears in prose, as a whole number rather than a substring
#'
#' 89.3 must not match inside 189.34 or 89.34. Bounded on both sides by the
#' character classes a number is made of, so a genuine adjacent digit or a
#' thousands separator prevents the match.
#' @keywords internal
#' @noRd
mn_find_literal <- function(prose, literal) {
  pat <- sprintf("(?<![0-9.,])%s(?![0-9])",
                 gsub("([.\\\\])", "\\\\\\1", literal))
  hits <- grep(pat, prose, perl = TRUE)
  hits[nzchar(trimws(prose[hits]))]
}

#' Read a two-or-more column TSV registry, dropping comments and the header
#' @keywords internal
#' @noRd
mn_read_tsv <- function(path) {
  if (!file.exists(path)) return(NULL)
  ln <- readLines(path, warn = FALSE)
  ln <- ln[!grepl("^#", ln) & nzchar(trimws(ln))]
  if (!length(ln)) return(data.frame())
  parts <- strsplit(ln, "\t", fixed = TRUE)
  hdr <- parts[[1]]
  rows <- parts[-1]
  if (!length(rows)) return(data.frame())
  rows <- lapply(rows, function(r) { length(r) <- length(hdr); r })
  d <- as.data.frame(do.call(rbind, rows), stringsAsFactors = FALSE)
  names(d) <- hdr
  d[] <- lapply(d, function(x) trimws(ifelse(is.na(x), "", x)))
  d
}
