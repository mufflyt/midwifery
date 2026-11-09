# =============================================================================
# Resolve a CCN to its state, including the ones no registry lists
# =============================================================================
# Every CCN -> state join in this project goes through cms_hospital_info, and
# that registry is HOSPITALS -- 5,421 of them. Facility affiliation is not
# hospitals: it is hospices, home health agencies, nursing homes, dialysis
# facilities and inpatient rehab too. Measured on the 2026-10 snapshot, the
# registry join resolves 4,528 of 41,034 distinct CCNs. ELEVEN PER CENT. The
# other 89% were not wrong, they were absent, and absent resolved to NA and
# then to "state not resolved".
#
# A CCN CARRIES ITS OWN STATE. The first two characters are CMS's state code,
# which is why '01T001' (an Alabama swing-bed unit) and '010001' share a
# prefix. That is documentation, not folklore -- so this file does not hardcode
# CMS's list from memory. It DERIVES the prefix -> state map from whatever
# registry it is handed and refuses to return one that is not 1:1.
#
# Checked against the hospital registry on 2026-11-09: 57 prefixes, 57
# prefix/state pairs, zero prefixes mapping to two states. And on the 4,528
# CCNs where the registry and the prefix both have an answer, they agree on
# 4,528 -- 100.0%, not approximately. Applying the prefix rule to the facility
# affiliation snapshot takes resolution from 11.0% to 88.0%; the residual 5,000
# carry prefixes no hospital in the registry uses (55, 75, 74, 68, 85, 97, A1,
# A9...), so they stay NA and are counted rather than guessed at.
#
# THE REGISTRY STILL WINS WHERE IT HAS AN ANSWER. The prefix is a fallback, not
# a replacement: an exact CCN match is a fact about that facility, while the
# prefix is a fact about its state code. They agree everywhere they overlap, so
# the ordering costs nothing and keeps the stronger evidence on top.
#
# @family data-quality
# @author Tyler Muffly, MD + Claude Code
# =============================================================================

if (!exists("pad_ccn", mode = "function")) source(file.path("R", "lib", "common_helpers.R"))

#' Build a CCN -> state crosswalk from a facility registry
#'
#' @param registry [data.frame] with a CCN column and a state column.
#' @param ccn_col,state_col [character] their names.
#' @return list(exact, prefix): `exact` is one row per CCN, `prefix` one row
#'   per two-character prefix. Errors if any prefix maps to more than one
#'   state -- that would mean the CCN state code is not what this file says it
#'   is, and every fallback below would be unsound.
ccn_state_crosswalk <- function(registry, ccn_col = "facility_id", state_col = "state") {
  stopifnot(is.data.frame(registry), ccn_col %in% names(registry), state_col %in% names(registry))
  d <- data.frame(ccn = pad_ccn(registry[[ccn_col]]),
                  state = toupper(trimws(as.character(registry[[state_col]]))),
                  stringsAsFactors = FALSE)
  d <- d[!is.na(d$ccn) & nzchar(d$ccn) & !is.na(d$state) & nzchar(d$state), , drop = FALSE]
  if (!nrow(d)) stop("ccn_state_crosswalk(): registry has no usable CCN/state rows.", call. = FALSE)

  exact <- unique(d[, c("ccn", "state")])
  exact <- exact[!duplicated(exact$ccn), , drop = FALSE]

  d$prefix <- substr(d$ccn, 1, 2)
  tab <- unique(d[, c("prefix", "state")])
  dup <- tab$prefix[duplicated(tab$prefix)]
  if (length(dup)) {
    offenders <- tab[tab$prefix %in% unique(dup), ]
    offenders <- offenders[order(offenders$prefix), ]
    stop(sprintf(paste0("ccn_state_crosswalk(): %d CCN prefix(es) map to more than one state, ",
                        "so the prefix is not a state code in this registry and must not be ",
                        "used as a fallback:\n  %s"),
                 length(unique(dup)),
                 paste(sprintf("%s -> %s", offenders$prefix, offenders$state), collapse = "\n  ")),
         call. = FALSE)
  }
  list(exact = exact, prefix = tab)
}

#' Resolve CCNs to states, registry first and prefix second
#'
#' @param ccn [character] CCNs, in any of the forms pad_ccn() accepts.
#' @param crosswalk the value of [ccn_state_crosswalk()].
#' @return [character] same length as `ccn`; NA where neither route resolves.
resolve_ccn_state <- function(ccn, crosswalk) {
  stopifnot(is.list(crosswalk), all(c("exact", "prefix") %in% names(crosswalk)))
  key <- pad_ccn(ccn)
  out <- crosswalk$exact$state[match(key, crosswalk$exact$ccn)]
  gap <- is.na(out) & !is.na(key)
  if (any(gap))
    out[gap] <- crosswalk$prefix$state[match(substr(key[gap], 1, 2), crosswalk$prefix$prefix)]
  out
}

#' How each CCN was resolved, for reporting rather than for joining
#'
#' Returns "registry", "prefix" or "unresolved" per element. A run that starts
#' leaning on the fallback, or that stops resolving at all, should say so in
#' its own log rather than being discovered later.
resolve_ccn_state_method <- function(ccn, crosswalk) {
  key <- pad_ccn(ccn)
  m <- rep("unresolved", length(key))
  by_prefix <- !is.na(crosswalk$prefix$state[match(substr(key, 1, 2), crosswalk$prefix$prefix)])
  m[by_prefix & !is.na(key)] <- "prefix"
  m[!is.na(match(key, crosswalk$exact$ccn))] <- "registry"
  m[is.na(key)] <- "unresolved"
  m
}
