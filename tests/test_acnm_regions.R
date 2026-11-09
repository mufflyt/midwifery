#!/usr/bin/env Rscript
# =============================================================================
# ACNM region mapping contract for Table 1
# =============================================================================

src <- file.path("R", "lib", "acnm_regions.R")
source(src)

fails <- 0L
chk <- function(cond, msg) {
  if (isTRUE(cond)) {
    cat(sprintf("  ok   %s\n", msg))
  } else {
    fails <<- fails + 1L
    cat(sprintf("  FAIL %s\n", msg))
  }
}

expected <- c(
  CT = "Region I", ME = "Region I", MA = "Region I",
  NH = "Region I", NY = "Region I", RI = "Region I",
  VT = "Region I", PR = "Region I",
  DE = "Region II", MD = "Region II", NJ = "Region II",
  PA = "Region II", VA = "Region II", WV = "Region II",
  DC = "Region II",
  AL = "Region III", FL = "Region III", GA = "Region III",
  LA = "Region III", MS = "Region III", NC = "Region III",
  SC = "Region III", TN = "Region III",
  AR = "Region IV", IL = "Region IV", IN = "Region IV",
  KY = "Region IV", MI = "Region IV", MO = "Region IV",
  OH = "Region IV",
  IA = "Region V", KS = "Region V", MN = "Region V",
  NE = "Region V", ND = "Region V", OK = "Region V",
  SD = "Region V", WI = "Region V",
  AZ = "Region VI", CO = "Region VI", MT = "Region VI",
  NM = "Region VI", TX = "Region VI", UT = "Region VI",
  WY = "Region VI",
  AK = "Region VII", CA = "Region VII", HI = "Region VII",
  ID = "Region VII", NV = "Region VII", OR = "Region VII",
  WA = "Region VII", AS = "Region VII", GU = "Region VII",
  AA = "Region VII", AE = "Region VII", AP = "Region VII"
)

obs <- map_state_to_acnm_region(names(expected))
chk(
  identical(unname(obs), unname(expected)),
  "every supplied state/jurisdiction maps to its ACNM region"
)

chk(
  identical(
    ACNM_REGION_LEVELS,
    paste("Region", c("I", "II", "III", "IV", "V", "VI", "VII"))
  ),
  "region levels are I through VII in Board representation order"
)

named <- c(
  "Washington D.C.",
  "International",
  "Samoa",
  "Guam",
  "Indigenous Peoples Affiliate",
  "Uniformed Services"
)
named_expected <- c(
  "Region II",
  "Region II",
  "Region VII",
  "Region VII",
  "Region VI",
  "Region VII"
)
chk(
  identical(map_state_to_acnm_region(named), named_expected),
  "named jurisdictions and affiliates map to the supplied regions"
)

foreign <- c("Montserrado", "Rhineland-Pfalz", "Southern Province")
chk(
  identical(
    map_state_to_acnm_region(foreign),
    rep("Region II", length(foreign))
  ),
  "clearly non-US practice-state text maps to Region II International"
)

unmapped <- c("VI", "MP", "FM", "PW", "MH", "XX", NA, "")
chk(
  all(is.na(map_state_to_acnm_region(unmapped))),
  "jurisdictions absent from the supplied ACNM table are not guessed"
)

cat(sprintf(
  "\n%s (%d failure%s)\n",
  if (fails == 0L) "PASS" else "FAILURES",
  fails,
  if (fails == 1L) "" else "s"
))
quit(status = if (fails == 0L) 0L else 1L)
