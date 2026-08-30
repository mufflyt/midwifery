suppressMessages({library(data.table); library(duckdb); library(DBI)})
source(file.path("R", "analysis_args.R"))   # arg_or()

setwd(arg_or(3, "REPO_ROOT", "."))
source("R/amcb_name_keys.R"); source("R/amcb_match_rules.R")
hi <- amcb_has_name_information

amcb <- fread("midwives.csv", colClasses="character")
sp <- amcb_split_first(amcb$first_name)
amcb[, `:=`(amcb_id=certification_number, last=amcb_blank_na(last_name), first=sp$given)]
amcb[, mid := trimws(paste(amcb_blank_na(middle_name), sp$middle_from_first))]
A <- amcb[hi(last) & hi(first), .(amcb_id, last, first, mid)]

con <- dbConnect(duckdb()); invisible(dbExecute(con,"SET threads=3"))
duckdb_register(con, "a", A[, .(last, first)])
# only identity rows whose name a certificant actually carries -- keeps this in RAM
read_identity_rows <- function(f) as.data.table(dbGetQuery(con, sprintf("
  SELECT DISTINCT p.npi, upper(trim(p.last_name)) nl, upper(trim(p.first_name)) nf,
         upper(trim(coalesce(p.middle_name,''))) nmid, p.tax_class
  FROM read_csv_auto('%s', ALL_VARCHAR=TRUE, SAMPLE_SIZE=-1) p
  JOIN (SELECT DISTINCT last, first FROM a) k
    ON k.last = upper(trim(p.last_name)) AND k.first = upper(trim(p.first_name))", f)))
W <- read_identity_rows("midwife_panel_wide_scoped.csv"); N <- read_identity_rows(arg_or(2, "MIDWIFE_PANEL", "midwife_panel.csv"))
dbDisconnect(con, shutdown=TRUE)
cat(sprintf("exact-name identity rows: narrow %s, wide %s\n",
            format(nrow(N),big.mark=","), format(nrow(W),big.mark=",")))

resolve_exact_tier <- function(P) {
  m <- merge(A, P, by.x=c("last","first"), by.y=c("nl","nf"), allow.cartesian=TRUE)
  if (!nrow(m)) return(data.table(amcb_id=character(0)))
  m[, agr := amcb_middle_agreement(amcb_middle_tokens(mid), amcb_middle_tokens(nmid))]
  m <- m[agr != "conflicts"]                       # the veto, as shipped
  m[, cls := fifelse(agr=="corroborates", 1L, 2L)]
  pn <- m[, .(cls=min(cls), tax=fifelse(any(tax_class=="midwife"),"midwife","nursing")), .(amcb_id, npi)]
  pn[, best := min(cls), amcb_id]
  pn[cls==best, .(n_at_best=uniqueN(npi), best=best[1],
                  mid_at_best=uniqueN(npi[tax=="midwife"])), amcb_id]
}
rn <- resolve_exact_tier(N); rw <- resolve_exact_tier(W)
ctrl <- fread(arg_or(1, "CONTROL_ARTIFACT"), colClasses="character")
st <- ctrl[, .(amcb_id, s=npi_match_status)]
j <- merge(st, rn[, .(amcb_id, n_nar=n_at_best)], by="amcb_id", all.x=TRUE)
j <- merge(j,  rw[, .(amcb_id, n_wid=n_at_best, mid_wid=mid_at_best)], by="amcb_id", all.x=TRUE)
j[is.na(n_nar), n_nar:=0L][is.na(n_wid), n_wid:=0L][is.na(mid_wid), mid_wid:=0L]

cat("\n=== POST-VETO, POST-RESOLUTION at the exact-name tier ===\n")
cat("--- RECOVERABLE: the 2,108 'no candidate' rows ---\n")
u <- j[s=="unmatched"]
cat("  resolve_exact_tier uniquely, narrow pool :", u[n_nar==1L, .N], "\n")
cat("  resolve_exact_tier uniquely, WIDE pool   :", u[n_wid==1L, .N], "\n")
cat("  ...of which midwifery taxonomy:", u[n_wid==1L & mid_wid==1L, .N], "\n")
cat("  gain candidates but TIE (wide):", u[n_wid>1L, .N], "\n")
cat("\n--- COST: rows resolved in the control ---\n")
r <- j[s %in% c("matched","matched_nursing_taxonomy")]
cat("  examined                      :", nrow(r), "\n")
cat("  unique in narrow, TIED in wide:", r[n_nar==1L & n_wid>1L, .N], "\n")
cat("  unique in both                :", r[n_nar==1L & n_wid==1L, .N], "\n")
