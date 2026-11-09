#!/usr/bin/env Rscript
# =============================================================================
# CCN -> state resolution contract
# =============================================================================
# The fallback in R/lib/ccn_state.R is only sound while a CCN prefix means a
# state. These cases pin that, pin the precedence (registry beats prefix), and
# pin the refusal: handed a registry where a prefix spans two states, the
# crosswalk must error rather than silently pick one.
# =============================================================================
source(file.path("R", "lib", "ccn_state.R"))

fails <- 0L
chk <- function(cond, msg) {
  if (isTRUE(cond)) cat(sprintf("  ok   %s\n", msg))
  else { fails <<- fails + 1L; cat(sprintf("  FAIL %s\n", msg)) }
}

reg <- data.frame(
  facility_id = c("010001", "010011", "050002", "330101", "01T001"),
  state       = c("AL",     "AL",     "CA",     "NY",     "AL"),
  stringsAsFactors = FALSE)
cw <- ccn_state_crosswalk(reg)

chk(nrow(cw$prefix) == 3L, "one row per prefix (01, 05, 33)")
chk(identical(sort(cw$prefix$state), c("AL", "CA", "NY")), "prefix map carries each state once")

chk(identical(resolve_ccn_state(c("010001", "050002"), cw), c("AL", "CA")),
    "exact CCNs resolve from the registry")

# The whole point: a CCN the registry has never heard of, whose prefix it has.
chk(identical(resolve_ccn_state("019999", cw), "AL"),
    "a CCN absent from the registry resolves by prefix")
chk(identical(resolve_ccn_state_method("019999", cw), "prefix"),
    "and is reported as resolved by prefix, not by registry")
chk(identical(resolve_ccn_state_method("010001", cw), "registry"),
    "an exact hit is reported as registry (precedence holds)")

chk(is.na(resolve_ccn_state("999999", cw)),
    "an unknown prefix stays NA rather than being guessed")
chk(identical(resolve_ccn_state_method("999999", cw), "unresolved"),
    "and is reported unresolved")

# pad_ccn() accepts short and alphanumeric forms; both must still find AL.
chk(identical(resolve_ccn_state("1T001", cw), "AL"),
    "alphanumeric swing-bed CCN resolves through pad_ccn()")
chk(identical(resolve_ccn_state(c(NA, ""), cw), c(NA_character_, NA_character_)),
    "NA and empty stay NA")

chk(identical(resolve_ccn_state(c("010001", "019999", "999999"), cw),
              c("AL", "AL", NA_character_)),
    "vectorised over a mixed batch, in order")

# THE REFUSAL. If a prefix ever spans two states the fallback is unsound, and
# this must stop rather than pick one.
bad <- data.frame(facility_id = c("010001", "010002"),
                  state = c("AL", "CA"), stringsAsFactors = FALSE)
err <- tryCatch({ ccn_state_crosswalk(bad); NULL }, error = function(e) conditionMessage(e))
chk(!is.null(err) && grepl("more than one state", err),
    "a prefix spanning two states errors instead of resolving")

cat(sprintf("\n%s (%d failure%s)\n", if (fails == 0L) "PASS" else "FAILURES",
            fails, if (fails == 1L) "" else "s"))
quit(status = if (fails == 0L) 0L else 1L)
