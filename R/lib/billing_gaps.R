# =============================================================================
# Interior gaps in a per-midwife year series
# =============================================================================
# Shared by audit_billing_gaps_vs_registry_status.R (what explains a gap) and
# audit_billing_gap_mechanisms.R (how big was she before it). One definition,
# because two copies of a gap rule is how two analyses come to disagree about
# how many gaps there are.
#
# @family data-quality
# =============================================================================

#' Interior gap episodes in one source's per-midwife year sequence
#'
#' An episode is a maximal run of consecutive missing years strictly INSIDE a
#' midwife's own observed span. Years before her first observation or after
#' her last are deliberately not gaps: the first is indistinguishable from
#' not having started, the second from having stopped, and calling either a
#' gap assumes the conclusion. This is why the rate is a statement about
#' intermittency, not about entry or exit.
#'
#' @param d [data.frame] `npi`, `year`; one row per observed midwife-year.
#'   Duplicates are collapsed, so a source listing a midwife twice in a year
#'   cannot create or close a gap.
#' @return [data.frame] npi, gap_start, gap_end, gap_len, span_start,
#'   span_end, n_observed. Zero rows when no midwife has an interior gap.
#' @examples
#' d <- data.frame(npi = c("A", "A", "A"), year = c(2015L, 2017L, 2018L))
#' gap_episodes(d)  # one episode, 2016-2016
gap_episodes <- function(d) {
  d <- unique(d[, c("npi", "year")])
  d <- d[!is.na(d$npi) & !is.na(d$year), , drop = FALSE]
  if (!nrow(d)) return(gap_episodes_empty())
  have <- split(d$year, d$npi)
  out <- lapply(names(have), function(n) {
    ys <- sort(unique(have[[n]]))
    if (length(ys) < 2L) return(NULL)
    miss <- setdiff(seq.int(min(ys), max(ys)), ys)
    if (!length(miss)) return(NULL)
    brk <- c(0L, which(diff(miss) != 1L), length(miss))
    do.call(rbind, lapply(seq_len(length(brk) - 1L), function(i) {
      run <- miss[(brk[i] + 1L):brk[i + 1L]]
      data.frame(npi = n, gap_start = min(run), gap_end = max(run),
                 gap_len = length(run), span_start = min(ys),
                 span_end = max(ys), n_observed = length(ys),
                 stringsAsFactors = FALSE)
    }))
  })
  out <- out[!vapply(out, is.null, logical(1))]
  if (!length(out)) return(gap_episodes_empty())
  do.call(rbind, out)
}

#' The empty result, with the full schema
#'
#' Returned instead of `data.frame()` so a caller binding or selecting on the
#' result gets the same columns whether or not any gap was found.
#'
#' @return [data.frame] zero rows, the columns `gap_episodes()` produces.
gap_episodes_empty <- function() {
  data.frame(npi = character(0), gap_start = integer(0), gap_end = integer(0),
             gap_len = integer(0), span_start = integer(0),
             span_end = integer(0), n_observed = integer(0),
             stringsAsFactors = FALSE)
}
