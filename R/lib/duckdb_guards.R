# =============================================================================
# Refuse to pull a large table into R
# =============================================================================
# This exists because a memory note failed three times in one session.
#
# The NPPES dissemination holds ~8.9 million live NPIs and ~1.9 million Type-2
# organizations. Three separate scripts pulled tables of that size into R to
# apply regex address normalisation with dplyr. Each one garbage-collection
# thrashed at under 20% CPU and had to be killed -- one after 25 minutes, one
# after 20 minutes of CPU time, having produced nothing. The same work in
# DuckDB runs multithreaded in seconds.
#
# Knowing the rule was not enough; it is now enforced at the point of the
# mistake. A caller that trips this should push the aggregation into SQL and
# return only the small result, not raise the limit.
# =============================================================================

#' Stop if a query returned more rows than R should be asked to process
#'
#' @param d [data.frame] the result about to enter R.
#' @param what [character] label naming the query, for the error message.
#' @param limit [numeric] row ceiling. Raising this is almost always the wrong
#'   fix -- the right one is to aggregate in SQL first.
#' @return `d` invisibly, so this can be used inline.
#' @examples
#' \dontrun{
#'   orgs <- refuse_if_large(dbGetQuery(con, big_query), "organization scan")
#' }
refuse_if_large <- function(d, what, limit = 1e6) {
  if (nrow(d) > limit)
    stop(sprintf(paste("%s returned %s rows to R (limit %s).\n",
                       " Push this aggregation into DuckDB and return only the",
                       "result. An R-side mutate over a table this size",
                       "garbage-collection thrashes and does not finish."),
                 what, format(nrow(d), big.mark = ","),
                 format(limit, big.mark = ",")), call. = FALSE)
  invisible(d)
}
