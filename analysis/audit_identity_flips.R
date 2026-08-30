suppressMessages({library(data.table); library(duckdb); library(DBI)})
source(file.path("R", "analysis_args.R"))   # arg_or()

setwd(arg_or(3, "REPO_ROOT", "."))
source("R/amcb_name_keys.R"); source("R/amcb_match_rules.R")
con <- fread(arg_or(2, "CONTROL_ARTIFACT"), colClasses="character")
TRT <- commandArgs(TRUE)[1]
cat("treatment artifact:", basename(TRT), "\n")
trt <- fread(TRT, colClasses="character")

m <- merge(con[, .(amcb_id, first_name, middle_name, last_name,
                   nl=normalized_last_name, nf=normalized_first_name, nm=normalized_middle_name,
                   npi.c=npi, cls.c=name_evidence_class, tax.c=npi_tax_class, st.c=nppes_state)],
           trt[, .(amcb_id, npi.t=npi, cls.t=name_evidence_class, tax.t=npi_tax_class, st.t=nppes_state)],
           by="amcb_id")
fl <- m[nzchar(npi.c) & nzchar(npi.t) & npi.c != npi.t]
cat("identity flips:", nrow(fl), "\n\n")

# pull both NPIs' recorded names from the narrow panel
dc <- dbConnect(duckdb()); invisible(dbExecute(dc,"SET threads=3"))
ids <- unique(c(fl$npi.c, fl$npi.t))
duckdb_register(dc, "want", data.frame(npi=ids))
PANEL <- arg_or(4, "MIDWIFE_PANEL", "midwife_panel.csv")
p <- as.data.table(dbGetQuery(dc, sprintf("
  SELECT DISTINCT p.npi, p.last_name, p.first_name, p.middle_name, p.tax_class, p.credential
  FROM read_csv_auto('%s', ALL_VARCHAR=TRUE, SAMPLE_SIZE=-1) p
  JOIN want w ON w.npi = p.npi", PANEL)))
dbDisconnect(dc, shutdown=TRUE)
p[, `:=`(k_last=amcb_blank_na(last_name), k_first=amcb_blank_na(first_name), k_mid=amcb_blank_na(middle_name))]

# For one (amcb middle, npi) show the verdict under BOTH rules.
verdict <- function(amcb_mid, npi_i) {
  v <- p[npi == npi_i]
  if (!nrow(v)) return(c(old=NA, new=NA, mids=NA))
  ai <- substr(amcb_mid,1,1); bi <- substr(v$k_mid,1,1)
  both <- amcb_has_name_information(ai) & amcb_has_name_information(bi)
  old <- if (any(both & ai==bi)) "match" else if (any(both)) "conflict" else "no info"
  nw <- amcb_middle_agreement(rep(list(amcb_middle_tokens(amcb_mid)[[1]]), nrow(v)),
                              amcb_middle_tokens(v$k_mid))
  new <- if (any(nw=="corroborates")) "corroborates" else if (any(nw=="conflicts")) "conflicts" else "uninformative"
  c(old=old, new=new, mids=paste(unique(v$k_mid[nzchar(v$k_mid)]), collapse="|"))
}
out <- rbindlist(lapply(seq_len(nrow(fl)), function(i) {
  r <- fl[i]
  vc <- verdict(r$nm, r$npi.c); vt <- verdict(r$nm, r$npi.t)
  data.table(amcb_id=r$amcb_id,
             amcb=trimws(paste(r$first_name, r$middle_name, r$last_name)),
             amcb_mid=r$nm,
             npi_control=r$npi.c, ctrl_mid=vc["mids"], ctrl_old=vc["old"], ctrl_new=vc["new"],
             cls_c=r$cls.c, tax_c=r$tax.c,
             npi_treat=r$npi.t, treat_mid=vt["mids"], treat_old=vt["old"], treat_new=vt["new"],
             cls_t=r$cls.t, tax_t=r$tax.t)
}))
cat("== why each flipped: verdict on the CONTROL npi under each rule ==\n")
print(out[, .N, .(ctrl_old, ctrl_new)][order(-N)])
cat("\n== and on the TREATMENT npi ==\n")
print(out[, .N, .(treat_old, treat_new)][order(-N)])
cat("\n== evidence class before -> after ==\n"); print(out[, .N, .(cls_c, cls_t)][order(cls_c)])
cat("\n== taxonomy before -> after ==\n"); print(out[, .N, .(tax_c, tax_t)][order(-N)])
fwrite(out, file.path(Sys.getenv("SP"), "identity_flips_after_fix.csv"))
cat("\n== the flips ==\n")
print(out[, .(amcb, amcb_mid, ctrl=paste0(npi_control," [",ctrl_mid,"] ",ctrl_old,"->",ctrl_new),
              trt=paste0(npi_treat," [",treat_mid,"] ",treat_old,"->",treat_new))], nrows=40)
