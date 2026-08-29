#!/usr/bin/env bash
# =============================================================================
# Green is not the same as verified
# =============================================================================
# On three consecutive pull requests the science-law coverage check reported
# success in 6, 8 and 10 seconds. It had run nothing. The path filter decided
# the change was irrelevant, every law step was skipped by an `if:`, and the JOB
# still exited zero -- so the tick was green, the required status was satisfied,
# and branch protection could not tell the difference. Duration was the only
# external evidence, read by hand, every time.
#
# This is the check that makes the difference machine-readable. A component
# passes only if it RAN and SUCCEEDED. Four things are not a pass:
#
#   FAILED   the job ran and failed
#   NOT RUN  the job was skipped by a conditional
#   NOT RUN  the job was cancelled
#   NOT RUN  the job is absent from the graph entirely
#
# And a fifth, which is the one that actually bit and which a naive
# result=="success" gate cannot see:
#
#   NOT RUN  the job succeeded while declining to do its work
#
# A job says which it did by declaring an `executed` output. If it declares one
# and that output is not "true", the job exited zero without doing the thing it
# is required for, and this refuses to call that scientifically green. Jobs that
# declare no such output are judged on their result alone.
#
# CONTRACT
#   NEEDS_JSON  toJSON(needs) -- the result and outputs of every dependency
#   REQUIRED    space-separated job ids that must have run and succeeded
#
# Bash and jq only. Both are on the runner image already: a gate that exists to
# say whether the expensive jobs ran should not itself need a toolchain
# installed, and every second it spends is a second added to every pull request.
# =============================================================================
set -uo pipefail

: "${NEEDS_JSON:?NEEDS_JSON is unset -- pass toJSON(needs)}"
: "${REQUIRED:?REQUIRED is unset -- pass the space-separated required job ids}"

if ! printf '%s' "$NEEDS_JSON" | jq -e . >/dev/null 2>&1; then
  echo "FATAL: NEEDS_JSON is not valid JSON. The gate cannot tell what ran, so"
  echo "       it refuses rather than assuming the best." >&2
  exit 1
fi

rows=""
bad_failed=""
bad_notrun=""
n=0

for job in $REQUIRED; do
  n=$((n + 1))
  present=$(printf '%s' "$NEEDS_JSON" | jq -r --arg j "$job" 'has($j)')
  if [ "$present" != "true" ]; then
    verdict="NOT RUN"; detail="absent from the dependency graph"
    bad_notrun="${bad_notrun}${job} (${detail})"$'\n'
    rows="${rows}| \`${job}\` | — | ❌ ${verdict} | ${detail} |"$'\n'
    continue
  fi

  result=$(printf '%s' "$NEEDS_JSON" | jq -r --arg j "$job" '.[$j].result // "unknown"')
  executed=$(printf '%s' "$NEEDS_JSON" | jq -r --arg j "$job" '.[$j].outputs.executed // ""')

  case "$result" in
    success)
      if [ -n "$executed" ] && [ "$executed" != "true" ]; then
        verdict="NOT RUN"; detail="exited zero but reported executed=${executed}"
        bad_notrun="${bad_notrun}${job} (${detail})"$'\n'
      else
        verdict="PASS"
        detail=$([ -n "$executed" ] && echo "ran and succeeded" || echo "succeeded")
      fi
      ;;
    skipped)   verdict="NOT RUN"; detail="skipped by a conditional"
               bad_notrun="${bad_notrun}${job} (${detail})"$'\n' ;;
    cancelled) verdict="NOT RUN"; detail="cancelled"
               bad_notrun="${bad_notrun}${job} (${detail})"$'\n' ;;
    failure)   verdict="FAILED";  detail="the job ran and failed"
               bad_failed="${bad_failed}${job}"$'\n' ;;
    *)         verdict="FAILED";  detail="unrecognised result '${result}'"
               bad_failed="${bad_failed}${job} (${detail})"$'\n' ;;
  esac

  icon=$([ "$verdict" = "PASS" ] && echo "✅" || echo "❌")
  rows="${rows}| \`${job}\` | ${result} | ${icon} ${verdict} | ${detail} |"$'\n'
done

# NON-VACUITY. An empty REQUIRED list would pass every component it was given,
# which is none of them, and report success. That is the exact shape of the
# defect this file exists to catch, so it is a failure here too.
if [ "$n" -eq 0 ]; then
  echo "FATAL: REQUIRED named no jobs. A gate over nothing is not a gate." >&2
  exit 1
fi

summary=$(printf '%s\n%s\n%s\n%s' \
  "## Scientific gate" \
  "| component | result | verdict | detail |" \
  "|---|---|---|---|" \
  "$rows")

echo "$summary"
[ -n "${GITHUB_STEP_SUMMARY:-}" ] && printf '%s\n' "$summary" >> "$GITHUB_STEP_SUMMARY"

if [ -z "$bad_failed" ] && [ -z "$bad_notrun" ]; then
  echo
  echo "PASS: all ${n} required component(s) ran and succeeded."
  exit 0
fi

echo
echo "SCIENTIFICALLY NOT GREEN."
if [ -n "$bad_failed" ]; then
  echo
  echo "  FAILED -- ran and did not pass:"
  printf '%s' "$bad_failed" | sed 's/^/    - /'
fi
if [ -n "$bad_notrun" ]; then
  echo
  echo "  NOT RUN -- never established anything, which is not the same as passing:"
  printf '%s' "$bad_notrun" | sed 's/^/    - /'
  echo
  echo "  A component that did not run has not verified the change. Re-run it, or"
  echo "  widen the filter that decided it was irrelevant. Do not remove it from"
  echo "  REQUIRED to make this green."
fi
exit 1
