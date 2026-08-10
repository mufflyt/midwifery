#!/usr/bin/env Rscript
#' @title CDC WONDER Natality (D66) API client
#'
#' @description
#' Minimal client for the CDC WONDER Natality API, used to pull county-level
#' births by Medical Attendant so that midwife-attended births can be measured
#' rather than inferred.
#'
#' @section Request grammar, which is not guessable:
#' WONDER rejects partial requests. A valid POST carries the FULL default
#' parameter set (74 entries for D66) with only the fields of interest
#' overridden; omitting the `V_`, `F_`, `I_` and `O_` scaffolding produces
#' "To Group Results By {0} you must also select the {1} button" with no
#' indication of which button. The defaults are therefore vendored to
#' `data/wonder/D66_Defaults.xml` rather than reconstructed.
#'
#' Two codes are easy to get wrong, and both fail confusingly:
#' \itemize{
#'   \item `D66.V9` is **Infant Birth Weight**, not county. Grouping by it
#'     yields "You are only allowed to request Birth Rates when ... County ...",
#'     which reads like a permissions problem and is actually a wrong variable.
#'   \item County is not a plain variable at all. Location is the *finder*
#'     variable `D66.V21` (residence), grouped as `D66.V21-level3` for state and
#'     `D66.V21-level4` for county.
#' }
#' `D66.V29` is Medical Attendant, whose values include CNM and Other Midwife.
#'
#' @section Suppression is data, not absence:
#' WONDER suppresses any sub-national cell below 10 births. Suppressed cells
#' come back as "Suppressed"/"Unreliable", NOT as zero, and this client keeps
#' them as `NA` with an explicit flag. Coercing them to 0 would understate
#' midwife-attended births in precisely the low-volume rural counties a
#' midwifery access analysis is about, and would do so invisibly.
#'
#' @section Rate limit:
#' The API requires >= 15 seconds between consecutive requests and says so only
#' after you exceed it. `wonder_post()` sleeps to enforce this itself.
#'
#' @family wonder
#' @author Tyler Muffly, MD + Claude Code
#' @name wonder_natality
NULL

WONDER_URL      <- "https://wonder.cdc.gov/controller/datarequest/D66"
WONDER_MIN_WAIT <- 16  # seconds; the documented floor is 15
.wonder_last    <- new.env(parent = emptyenv())
.wonder_last$t  <- NULL

#' Build the request XML from vendored defaults plus overrides
#'
#' @param overrides [named list]: parameters to set, e.g. `list(B_1 = "D66.V21-level4")`.
#' @param defaults_path [character(1)]: vendored D66 defaults.
#' @return [character(1)] request XML.
#' @family wonder
#' @export
wonder_request_xml <- function(overrides = list(),
                               defaults_path = file.path("data", "wonder", "D66_Defaults.xml")) {
  if (!file.exists(defaults_path)) {
    stop("wonder_request_xml: defaults not found at ", defaults_path,
         ". A partial request is always rejected; the full set is required.",
         call. = FALSE)
  }
  doc <- xml2::read_xml(defaults_path)
  nodes <- xml2::xml_find_all(doc, "//parameter")
  names_v <- xml2::xml_text(xml2::xml_find_first(nodes, "./name"))

  for (nm in names(overrides)) {
    val <- overrides[[nm]]
    idx <- which(names_v == nm)
    if (length(idx) == 1L) {
      # Multi-valued parameters (several <value> children) must be replaced
      # wholesale, not appended to, or the old value survives alongside the new.
      node <- nodes[[idx]]
      for (v in xml2::xml_find_all(node, "./value")) xml2::xml_remove(v)
      for (v in val) xml2::xml_add_child(node, "value", as.character(v))
    } else {
      p <- xml2::xml_add_child(doc, "parameter")
      xml2::xml_add_child(p, "name", nm)
      for (v in val) xml2::xml_add_child(p, "value", as.character(v))
    }
  }
  as.character(doc)
}

#' POST a request to WONDER, enforcing the rate limit
#'
#' @param request_xml [character(1)]: from `wonder_request_xml()`.
#' @return [xml_document] the response.
#' @family wonder
#' @export
wonder_post <- function(request_xml) {
  # The stamp is persisted to disk, not just held in memory: WONDER rate-limits
  # per CLIENT, so two consecutive Rscript invocations trip the limit even
  # though each process believes it has made no prior request. An in-process
  # throttle alone silently fails the first call of every session with HTTP 429.
  stamp <- path.expand("~/.wonder_last_request")
  last <- if (file.exists(stamp)) as.POSIXct(readLines(stamp, warn = FALSE)[1]) else .wonder_last$t
  if (!is.null(last) && !is.na(last)) {
    waited <- as.numeric(difftime(Sys.time(), last, units = "secs"))
    if (waited < WONDER_MIN_WAIT) Sys.sleep(WONDER_MIN_WAIT - waited)
  }
  on.exit(writeLines(format(Sys.time()), stamp), add = TRUE)
  resp <- httr::POST(WONDER_URL, body = list(request_xml = request_xml),
                     encode = "form", httr::timeout(900))
  .wonder_last$t <- Sys.time()

  txt <- httr::content(resp, as = "text", encoding = "UTF-8")
  doc <- xml2::read_xml(txt)
  # WONDER returns HTTP 200 for errors, with the failure in the body -- so
  # status_code alone is not a success test.
  if (identical(xml2::xml_text(xml2::xml_find_first(doc, "//title")), "Processing Error")) {
    msgs <- xml2::xml_text(xml2::xml_find_all(doc, "//message"))
    stop("WONDER rejected the request:\n  ", paste(unique(msgs), collapse = "\n  "),
         call. = FALSE)
  }
  doc
}

#' Parse a WONDER response into a tidy data frame
#'
#' Suppressed, unreliable and not-applicable cells are returned as `NA` with a
#' companion flag rather than silently becoming zero.
#'
#' @param doc [xml_document]: from `wonder_post()`.
#' @return [data.frame] one row per data-table row.
#' @family wonder
#' @export
wonder_parse <- function(doc, n_group = 1L) {
  rows <- xml2::xml_find_all(doc, "//data-table/r")
  if (length(rows) == 0L) return(data.frame())

  labs <- vector("list", length(rows))
  vals <- vector("list", length(rows))
  for (i in seq_along(rows)) {
    cells <- xml2::xml_find_all(rows[[i]], "./c")
    l <- xml2::xml_attr(cells, "l"); v <- xml2::xml_attr(cells, "v")
    labs[[i]] <- l[!is.na(l)]
    vals[[i]] <- v[!is.na(v)]
  }

  # CRITICAL: with more than one group-by variable, WONDER emits the OUTER
  # label only on the first row of each group, exactly like a row-spanned HTML
  # table. A flat read therefore shifts every continuation row one column left,
  # silently pairing the wrong year with the wrong attendant. Missing outer
  # labels are carried down from the previous row instead.
  carried <- rep(NA_character_, n_group)
  filled <- vector("list", length(rows))
  for (i in seq_along(rows)) {
    l <- labs[[i]]
    if (length(l) >= n_group) {
      carried <- l[seq_len(n_group)]
    } else if (length(l) > 0L) {
      # k labels present means they fill the INNERMOST k slots.
      k <- length(l)
      carried[seq(n_group - k + 1L, n_group)] <- l
    }
    filled[[i]] <- carried
  }

  nv <- max(vapply(vals, length, integer(1)), 1L)
  vals <- lapply(vals, function(x) c(x, rep(NA_character_, nv - length(x))))

  df <- as.data.frame(do.call(rbind, filled), stringsAsFactors = FALSE)
  names(df) <- paste0("group", seq_len(n_group))
  vdf <- as.data.frame(do.call(rbind, vals), stringsAsFactors = FALSE)
  names(vdf) <- paste0("value", seq_len(nv))
  cbind(df, vdf)
}

#' Coerce a WONDER count, preserving suppression
#'
#' @param x [character]: raw cell values.
#' @return [list] with `value` (numeric, NA when not a count) and `flag`.
#' @family wonder
#' @export
wonder_count <- function(x) {
  x <- trimws(as.character(x))
  flag <- dplyr::case_when(
    grepl("^Suppressed$", x, ignore.case = TRUE)     ~ "suppressed",
    grepl("^Unreliable$", x, ignore.case = TRUE)     ~ "unreliable",
    grepl("^Not Applicable$", x, ignore.case = TRUE) ~ "not_applicable",
    # CYCLE 3. This was "^[0-9,]+$", which accepts a string of bare commas.
    # ",,," was flagged "ok" while as.numeric("") made its value NA, so a cell
    # that parsed to nothing advertised itself as a publishable count. Downstream
    # code tests flag == "ok" to decide whether a county's births can be
    # reported, so the flag must imply a real number. Require at least one
    # digit, and either plain digits or proper thousands grouping.
    grepl("^[0-9]+$|^[0-9]{1,3}(,[0-9]{3})+$", x)    ~ "ok",
    TRUE                                             ~ "unparsed")
  value <- suppressWarnings(as.numeric(gsub(",", "", x)))
  value[flag != "ok"] <- NA_real_
  list(value = value, flag = flag)
}
