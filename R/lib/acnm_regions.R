# =============================================================================
# ACNM Board of Directors regions for Table 1
# =============================================================================
# The regional grouping is the ACNM Board representation table supplied for
# this analysis. This is intentionally local to the midwifery repository:
# Table 1 should not depend on ACOG geography or an isochrones checkout.
#
# State/jurisdiction grouping:
#   I   CT ME MA NH NY RI VT PR
#   II  DE MD NJ PA VA WV DC International
#   III AL FL GA LA MS NC SC TN
#   IV  AR IL IN KY MI MO OH
#   V   IA KS MN NE ND OK SD WI
#   VI  AZ CO MT NM TX UT WY Indigenous Peoples Affiliate
#   VII AK CA HI ID NV OR WA Uniformed Services Samoa Guam
#
# NPPES uses AA/AE/AP for military addresses. Those are treated as the
# Uniformed Services representation in Region VII. Foreign administrative-area
# text is treated as Region II International. Jurisdictions absent from the
# supplied table are left NA rather than guessed.
# =============================================================================

ACNM_REGION_LEVELS <- paste(
  "Region",
  c("I", "II", "III", "IV", "V", "VI", "VII")
)

ACNM_REGION_MEMBERS <- list(
  "Region I" = c(
    "CT", "ME", "MA", "NH", "NY", "RI", "VT", "PR"
  ),
  "Region II" = c(
    "DE", "MD", "NJ", "PA", "VA", "WV", "DC", "INTERNATIONAL"
  ),
  "Region III" = c(
    "AL", "FL", "GA", "LA", "MS", "NC", "SC", "TN"
  ),
  "Region IV" = c(
    "AR", "IL", "IN", "KY", "MI", "MO", "OH"
  ),
  "Region V" = c(
    "IA", "KS", "MN", "NE", "ND", "OK", "SD", "WI"
  ),
  "Region VI" = c(
    "AZ", "CO", "MT", "NM", "TX", "UT", "WY",
    "INDIGENOUS PEOPLES AFFILIATE"
  ),
  "Region VII" = c(
    "AK", "CA", "HI", "ID", "NV", "OR", "WA",
    "UNIFORMED SERVICES", "AS", "GU"
  )
)

ACNM_REGION_LOOKUP <- stats::setNames(
  rep(names(ACNM_REGION_MEMBERS), lengths(ACNM_REGION_MEMBERS)),
  unlist(ACNM_REGION_MEMBERS, use.names = FALSE)
)

ACNM_REGION_ALIASES <- c(
  "WASHINGTON D.C." = "DC",
  "WASHINGTON DC" = "DC",
  "DISTRICT OF COLUMBIA" = "DC",
  "PUERTO RICO" = "PR",
  "AMERICAN SAMOA" = "AS",
  "SAMOA" = "AS",
  "GUAM" = "GU",
  "AA" = "UNIFORMED SERVICES",
  "AE" = "UNIFORMED SERVICES",
  "AP" = "UNIFORMED SERVICES"
)

ACNM_REGION_EXPLICIT_UNMAPPED <- c(
  "VI",
  "VIRGIN ISLANDS",
  "US VIRGIN ISLANDS",
  "U.S. VIRGIN ISLANDS",
  "MP",
  "NORTHERN MARIANA ISLANDS",
  "FM",
  "FEDERATED STATES OF MICRONESIA",
  "PW",
  "PALAU",
  "MH",
  "MARSHALL ISLANDS"
)

normalize_acnm_region_key <- function(x) {
  key <- toupper(trimws(as.character(x)))
  key[!nzchar(key)] <- NA_character_

  state_aliases <- stats::setNames(
    state.abb,
    toupper(state.name)
  )
  aliases <- c(state_aliases, ACNM_REGION_ALIASES)

  idx <- match(key, names(aliases))
  has_alias <- !is.na(idx)
  key[has_alias] <- unname(aliases[idx[has_alias]])
  key
}

map_state_to_acnm_region <- function(x) {
  key <- normalize_acnm_region_key(x)
  region <- unname(ACNM_REGION_LOOKUP[key])

  # The supplied grouping places International representation in Region II.
  # NPPES foreign addresses can carry province/state text rather than a US
  # postal code. Long non-US text is therefore International, except for
  # jurisdictions explicitly absent from the supplied ACNM table.
  foreign_text <- is.na(region) &
    !is.na(key) &
    nchar(key) > 2L &
    !key %in% ACNM_REGION_EXPLICIT_UNMAPPED

  region[foreign_text] <- "Region II"
  region
}
