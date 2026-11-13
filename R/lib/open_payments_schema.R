# =============================================================================
# Open Payments column names, which CMS changed twice
# =============================================================================
# The general-payment file renamed its recipient columns as the programme
# widened beyond physicians, so the column holding an NPI -- or a profile id --
# depends on the program year:
#
#   2013-2014  no NPI column at all. CMS published these years before the NPI
#              was carried on the payment record, which is why those two years
#              can only be recovered by joining the profile id to a lookup
#              learned from a later year.
#   2015       Physician_NPI / Physician_Profile_ID
#   2016+      Covered_Recipient_NPI, and from 2016 also
#              Covered_Recipient_Profile_ID
#
# Note the two boundaries do NOT coincide: the NPI column changes name at 2016
# while 2015 still uses Physician_NPI, and the profile column also changes at
# 2016. An off-by-one on either reads a column that does not exist, and the
# year silently drops out of the series.
#
# Defined once, here, because two scripts need them and ci_hygiene H4 fails on
# a function defined at top level in two tracked files -- which is exactly what
# happened when they were copied into both.
# Tested by tests/test_source_series_reconstruction.R section [20].

#' Name of the NPI column for an Open Payments program year
#'
#' @param year [integer]: program year.
#' @return [character] the column name, or NA for years that carry no NPI.
op_npi_column <- function(year) {
  if (year <= 2014L) return(NA_character_)
  if (year == 2015L) return("Physician_NPI")
  "Covered_Recipient_NPI"
}

#' Name of the profile-id column for an Open Payments program year
#'
#' @param year [integer]: program year.
#' @return [character] the column name.
op_profile_column <- function(year) {
  if (year <= 2015L) "Physician_Profile_ID" else "Covered_Recipient_Profile_ID"
}
