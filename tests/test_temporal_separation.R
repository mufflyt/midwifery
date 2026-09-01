#!/usr/bin/env Rscript
# =============================================================================
# amcb_temporal_separation: what a temporal tiebreak would and would not do
# =============================================================================
# The function is off by default and promotes nothing. What it must get right is
# the direction of its own uncertainty: a candidate is ruled out only when the
# evidence positively rules it out, and a censored or missing year is not
# evidence. Getting that backwards would manufacture separations out of absence,
# which is the failure the middle-name veto already committed once.
#
# Run: Rscript tests/test_temporal_separation.R
# =============================================================================

root <- {
  a <- grep("--file=", commandArgs(), value = TRUE)
  if (length(a)) normalizePath(file.path(dirname(sub("--file=", "", a[1])), ".."))
  else normalizePath(".")
}
source(file.path(root, "R", "amcb_resolver.R"))

fails <- 0L
chk <- function(cond, m) {
  if (isTRUE(cond)) cat(sprintf("  ok   %s\n", m))
  else { fails <<- fails + 1L; cat(sprintf("  FAIL %s\n", m)) }
}

cand <- function(id, npi, fy, cens = FALSE)
  data.frame(amcb_id = id, npi = npi, name_evidence_class = 2L,
             first_year = fy, first_year_censored = cens,
             stringsAsFactors = FALSE)

cat("\n-- separation --\n")

# One rival enumerated 40 years before certification; the other is contemporary.
d <- rbind(cand("A", "1", 1975), cand("A", "2", 2010))
cy <- data.frame(amcb_id = "A", cert_year = 2012)
r <- amcb_temporal_separation(d, cy, grace = 25)
chk(isTRUE(r$separated) && identical(r$surviving_npi, "2"),
    "T1 a long lead rules one candidate out and separates the pool")

# Both plausible: nothing is separated, and the tie stands.
d <- rbind(cand("B", "1", 2008), cand("B", "2", 2010))
r <- amcb_temporal_separation(d, data.frame(amcb_id = "B", cert_year = 2012),
                              grace = 25)
chk(!isTRUE(r$separated) && r$n_surviving == 2L,
    "T2 two plausible candidates stay tied")

cat("\n-- absence is not evidence --\n")

# THE ONE THAT MATTERS. A censored first year is a bound: the NPI may have
# enumerated before the panel opens, so a long computed lead rules out nothing.
d <- rbind(cand("C", "1", 2007, cens = TRUE), cand("C", "2", 2010))
r <- amcb_temporal_separation(d, data.frame(amcb_id = "C", cert_year = 2050),
                              grace = 25)
# Candidate 2 IS ruled out here, on its own uncensored evidence. What must not
# happen is candidate 1 being promoted in its place: it survived only because
# its year is a bound, so the pool is unseparated and says why.
chk(!isTRUE(r$separated) && isTRUE(r$separation_blocked_by_censoring),
    "T3 a lone survivor that survived only by censoring is NOT a separation")
chk(r$n_censored_unusable == 1L, "T4 the censored candidate is counted as such")

# A missing year is likewise not evidence against.
d <- rbind(cand("D", "1", NA_integer_), cand("D", "2", 2010))
r <- amcb_temporal_separation(d, data.frame(amcb_id = "D", cert_year = 2050),
                              grace = 25)
chk(!isTRUE(r$separated) && isTRUE(r$separation_blocked_by_censoring),
    "T5 a lone survivor that survived only by a MISSING year is not a separation")

# A missing certification year disables the rule entirely for that record.
d <- rbind(cand("E", "1", 1975), cand("E", "2", 2010))
r <- amcb_temporal_separation(d, data.frame(amcb_id = "E",
                                            cert_year = NA_integer_), grace = 25)
chk(!isTRUE(r$separated), "T6 no certification year means no separation")

cat("\n-- it never promotes and never empties a pool --\n")

# Every candidate ruled out would be a pool with no survivor. That is not a
# separation and must not be reported as one.
d <- rbind(cand("F", "1", 1970), cand("F", "2", 1975))
r <- amcb_temporal_separation(d, data.frame(amcb_id = "F", cert_year = 2012),
                              grace = 25)
chk(!isTRUE(r$separated) && r$n_surviving == 0L,
    "T7 ruling out EVERY candidate is not a separation")

# A pool of one was never tied, so there is nothing to separate.
r <- amcb_temporal_separation(cand("G", "1", 2010),
                              data.frame(amcb_id = "G", cert_year = 2012),
                              grace = 25)
chk(!isTRUE(r$separated), "T8 a single-candidate pool is not a separation")

# grace is doing real work, in the right direction.
d <- rbind(cand("H", "1", 1995), cand("H", "2", 2010))
cy <- data.frame(amcb_id = "H", cert_year = 2012)
chk(isTRUE(amcb_temporal_separation(d, cy, grace = 10)$separated) &&
      !isTRUE(amcb_temporal_separation(d, cy, grace = 25)$separated),
    "T9 a wider grace separates strictly less")

cat(sprintf("\n%s (%d failure%s)\n", if (fails) "FAIL" else "PASS", fails,
            if (fails == 1L) "" else "s"))
quit(status = if (fails) 1L else 0L)
