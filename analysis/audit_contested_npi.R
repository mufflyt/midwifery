suppressMessages(library(data.table))
source(file.path("R", "analysis_args.R"))   # arg_or()

CW <- arg_or(1, "CONTROL_WORKTREE", ".")
con <- fread(file.path(CW,"artifacts","amcb_npi_linkage_panel-midwifery-plus-nursing_years-2007-2025.csv"), colClasses="character")
ca  <- fread(file.path(CW,"artifacts","linkage_candidate_audit.csv"))
ps  <- fread(file.path(CW,"artifacts","linkage_pool_diagnostics.csv"))
cid <- con[npi_match_status=="ambiguous_contested_npi", amcb_id]
cat("contested rows in control:", length(cid), "\n")
# per (amcb_id, npi) strongest class, then each person's best class and the
# NPI(s) they hold at it -- the 'provisional' claim rank_one_to_one computed.
pn <- ca[, .(cls=min(name_evidence_class)), .(amcb_id, npi)]
pn[, best := min(cls), amcb_id][, n_best := sum(cls==best), amcb_id]
claim <- pn[cls==best & n_best==1L & amcb_id %in% cid]
cat("contested ids with a single best-class claim:", uniqueN(claim$amcb_id), "\n")
g <- claim[, .(n_claimants=.N, best_cls=min(best), n_at_top=sum(best==min(best))), npi]
g <- g[n_claimants > 1L]
cat("\ncontested NPIs:", nrow(g), "\n")
cat("\n== is one claimant STRICTLY better on evidence class? ==\n")
print(g[, .N, .(strictly_separable = n_at_top == 1L)])
cat("\n== claimants per contested NPI ==\n"); print(g[, .N, n_claimants][order(n_claimants)])
cat("\n== evidence class of the winning claim, where separable ==\n")
print(g[n_at_top==1L, .N, best_cls][order(best_cls)])
cat("\n== where NOT separable, what class do they tie at ==\n")
print(g[n_at_top>1L, .N, best_cls][order(best_cls)])
sep <- g[n_at_top==1L]
recover <- claim[npi %in% sep$npi][, .SD[best==min(best)], npi][, .N]
cat(sprintf("\nrecords a strict-dominance rule would resolve: %d\nrecords left quarantined: %d\n",
    nrow(sep), uniqueN(claim$amcb_id) - nrow(sep)))
