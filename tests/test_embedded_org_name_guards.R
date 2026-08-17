# =============================================================================
# The guards on the embedded-organization-name arm
# =============================================================================
# This arm reads an organization name out of an ADDRESS field, which is the
# loosest evidence in the project. It is safe only because of four rules, and
# each one is asserted here:
#
#   E1  A generic name resolves nothing. "NAVAL MEDICAL CENTER" describes
#       several facilities and identifies none. Without this guard the arm
#       attaches every Navy midwife to whichever Naval medical centre happens to
#       be first, at scale, and it would look like a successful yield.
#   E2  Distinctive names survive. A guard that rejected everything would be
#       trivially safe and useless, so the converse is asserted too.
#   E3  A letter-prefixed grid address is NOT name-based. Wisconsin issues
#       "N8150 AMUNDSON COULEE RD"; a bare ^[0-9] test sent twelve ordinary
#       rural street addresses into name matching, where they can only fail.
#   E4  Structurally nameless forms are excluded: PO boxes, mail stops,
#       highways, and a certificant's OWN NAME in the address field.
#
# The functions under test are extracted from build_embedded_org_name_arm.R by
# source, not retyped. A hand-copied stoplist that drifts from the script would
# pass this suite while the script did something else.
#
# Pure functions over literal strings. No artifact, no network, no NPPES.
# =============================================================================

root <- "."
if (!dir.exists(file.path(root, ".git")) && dir.exists("../.git")) root <- ".."
suppressPackageStartupMessages(library(stringr))
source(file.path(root, "R", "lib", "org_names.R"))

SCRIPT <- file.path(root, "build_embedded_org_name_arm.R")
stopifnot(file.exists(SCRIPT))
src <- readLines(SCRIPT, warn = FALSE)

# Pull a top-level definition out of the script by name.
#
# Ends the definition by BALANCING delimiters, not by matching a closing token.
# A regex for a trailing ")" stopped inside has_distinctive_token() on the line
# `keep <- setdiff(tok, GENERIC)` and produced an unparseable fragment.
extract <- function(pattern) {
  s <- grep(pattern, src)
  if (!length(s)) stop("not found in the script: ", pattern, call. = FALSE)
  s <- s[1]
  depth <- 0L
  for (i in s:length(src)) {
    ln <- gsub('"[^"]*"|\'[^\']*\'|#.*$', "", src[i])
    depth <- depth + lengths(regmatches(ln, gregexpr("[({]", ln))) -
                     lengths(regmatches(ln, gregexpr("[)}]", ln)))
    if (i > s || depth == 0L) if (depth <= 0L)
      return(paste(src[s:i], collapse = "\n"))
  }
  stop("unbalanced definition starting at line ", s, call. = FALSE)
}
eval(parse(text = extract("^GENERIC <- c\\(")))
eval(parse(text = extract("^has_distinctive_token <- function")))
eval(parse(text = extract("^has_house_number <- function")))
eval(parse(text = extract("^NOT_A_NAME <- paste0\\(")))

failures <- character(0)
chk <- function(ok, msg) {
  if (isTRUE(ok)) cat(sprintf("  ok   %s\n", msg))
  else failures <<- c(failures, msg)
}
gen <- function(x) !has_distinctive_token(norm_org(x))

cat(sprintf("\n-- E1 generic names are rejected (%d stoplist tokens) --\n", length(GENERIC)))
for (x in c("NAVAL MEDICAL CENTER", "MEDICAL CENTER", "HOSPITAL", "CLINIC",
            "ARMY", "NAVY", "US NAVAL HOSPITAL", "MILITARY TREATMENT FACILITY",
            "AIR FORCE MEDICAL CENTER", "REGIONAL MEDICAL CENTER",
            "COMMUNITY HEALTH CENTER", "DEPARTMENT OF NURSING"))
  chk(gen(x), sprintf("rejected as generic: %s", x))

cat("\n-- E2 distinctive names survive --\n")
for (x in c("LANDSTUHL REGIONAL MEDICAL CENTER", "WOMACK ARMY MEDICAL CENTER",
            "MADIGAN ARMY MEDICAL CTR", "WALTER REED NATIONAL MILITARY CTR",
            "US NAVAL HOSPITAL OKINAWA", "NMRTC PORTSMOUTH",
            "UNIVERSITY OF WASHINGTON", "UNIVERSITY OF CALIFORNIA IRVINE",
            "VANDERBILT DEPT OF OBGYN"))
  chk(!gen(x), sprintf("retained as distinctive: %s", x))

cat("\n-- E3 letter-prefixed grid addresses have a house number --\n")
for (x in c("N8150 AMUNDSON COULEE RD", "N2930 BAUER LN",
            "S34W34601 COUNTY ROAD C", "N20302 SUNSET RIDGE LN",
            "W180N8085 TOWN HALL RD"))
  chk(has_house_number(x), sprintf("numbered (grid): %s", x))
for (x in c("3130 HIGHLAND AVE", "80 JESSE HILL JR DR SE"))
  chk(has_house_number(x), sprintf("numbered (plain): %s", x))
for (x in c("LANDSTUHL REGIONAL MEDICAL CENTER", "NAVAL MEDICAL CENTER",
            "LRMC", "TODEE JUNCTION ROAD"))
  chk(!has_house_number(x), sprintf("no house number: %s", x))

cat("\n-- E4 structurally nameless forms are excluded --\n")
for (x in c("PO BOX 555191", "P.O. BOX 71054", "ATTN: DQS-CR", "MSC 09 5350",
            "HIGHWAY 191 AND HOSPITAL ROAD",
            "INTERSECTION OF HIGHWAYS 7 AND 12", "CARR 167 BUENA VISTA",
            "JANELLE KOMOROWSKI, DNP, CNM", "SOLAR 2"))
  chk(grepl(NOT_A_NAME, toupper(x)), sprintf("excluded as nameless: %s", x))
# The converse: a real institution name must NOT be caught by that filter.
for (x in c("LANDSTUHL REGIONAL MEDICAL CENTER", "WOMACK ARMY MEDICAL CENTER",
            "US NAVAL HOSPITAL OKINAWA", "UNIVERSITY OF WASHINGTON"))
  chk(!grepl(NOT_A_NAME, toupper(x)),
      sprintf("institution name NOT excluded: %s", x))

# Box designators anywhere in the string, not only anchored. This case is why
# the rule changed: "SCHOOL OF NURSING CBX 063" originally survived into name
# matching because NOT_A_NAME anchored CBX at the start, and CBX then counted
# as a distinctive token -- a campus-box number reading as an organization.
for (x in c("SCHOOL OF NURSING CBX 063", "PSC 482 BOX 53", "CMR 402 BOX 1836",
            "UNIVERSITY OF MEXICO MSC 09 5350"))
  chk(grepl(NOT_A_NAME, toupper(x)),
      sprintf("box/mail-stop designator caught mid-string: %s", x))

cat("\n")
if (length(failures)) {
  for (f in failures) cat(sprintf("FAIL %s\n", f))
  cat(sprintf("\nFAILED (%d)\n", length(failures)))
  quit(status = 1)
}
cat("PASS (0 failures)\n")
