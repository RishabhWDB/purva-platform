#!/usr/bin/env bash
# A timer in Azure that starts the Deploy workflow every 5 minutes.
#
# GitHub's own schedule ("cron" in deploy.yml) is unreliable on this repo: it ran
# about once every 9 hours instead of every 5 minutes. This Logic App calls GitHub's
# "run workflow" API on a fixed timer instead. The GitHub cron stays as a backup.
#
# Run in Azure Cloud Shell (Bash) as the subscription Owner, from a clone of this repo:
#
#   bash scripts/deploy-timer.sh setup    create or update the timer (asks for a GitHub token)
#   bash scripts/deploy-timer.sh status   is it on, and how did its last runs go
#   bash scripts/deploy-timer.sh pause    stop it (costs nothing while paused)
#   bash scripts/deploy-timer.sh resume   start it again
#   bash scripts/deploy-timer.sh remove   delete it
#
# The GitHub token: a fine-grained token with access to this repo only and one
# permission, "Actions: Read and write". With it, the timer can start, cancel or
# re-run this repo's workflows, and nothing else: it can't read or change code.
# The token is kept in the Logic App as a secure value, hidden from run history.
#
# Cost (Central India, Consumption plan, checked 2026-11-24): every tick is 2 built-in
# actions (the timer and the call to GitHub). 8,640 ticks a month = 17,280 actions;
# the first 4,000 are free, the rest are $0.000028 each: about $0.37 (~₹35) a month.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
. scripts/lib.sh

ACTION="${1:-status}"
NAME="${TIMER_NAME:-deploy-timer}"
INTERVAL_MINUTES="${INTERVAL_MINUTES:-5}"
API="2019-05-01"
case "$ACTION" in setup|status|pause|resume|remove) ;; *) die "usage: bash scripts/deploy-timer.sh setup|status|pause|resume|remove" ;; esac
printf '%s' "$INTERVAL_MINUTES" | grep -Eq '^[1-9][0-9]*$' && [ "$INTERVAL_MINUTES" -ge 5 ] \
  || die "INTERVAL_MINUTES must be a whole number, 5 or more"

load_platform
command -v jq >/dev/null || die "jq not found"
command -v curl >/dev/null || die "curl not found"
sub="$(az account show --query id -o tsv 2>/dev/null)" || die "not signed in (az login)"
[ "$sub" = "$P_SUB" ] || die "signed in to subscription $sub, expected $P_SUB (az account set --subscription $P_SUB)"
ID="/subscriptions/$P_SUB/resourceGroups/$P_GROUP/providers/Microsoft.Logic/workflows/$NAME"
URL="https://management.azure.com$ID?api-version=$API"
WORKFLOW_API="https://api.github.com/repos/$P_REPO/actions/workflows/deploy.yml"

exists() { az rest --method get --url "$URL" -o none >/dev/null 2>&1; }

show_status() {
  local wf
  wf="$(az rest --method get --url "$URL" 2>/dev/null)" || { info "No timer '$NAME' in group $P_GROUP."; return 0; }
  info "Timer $NAME (group $P_GROUP): $(printf '%s' "$wf" | jq -r '.properties.state')," \
    "every $(printf '%s' "$wf" | jq -r '.properties.definition.triggers[].recurrence.interval') minutes"
  info "Last runs (UTC):"
  az rest --method get --url "https://management.azure.com$ID/runs?api-version=$API&\$top=8" 2>/dev/null \
    | jq -r '.value[] | "  \(.properties.startTime[0:19])  \(.properties.status)"' \
    || info "  (couldn't read run history)"
  info "Failed runs usually mean the GitHub token expired or was revoked: rerun setup with a new one."
}

case "$ACTION" in
  status) show_status; exit 0 ;;
  pause|resume)
    exists || die "no timer '$NAME' in group $P_GROUP (run setup first)"
    verb=disable; [ "$ACTION" = resume ] && verb=enable
    az rest --method post --url "https://management.azure.com$ID/$verb?api-version=$API" -o none || die "couldn't $ACTION"
    show_status; exit 0 ;;
  remove)
    exists || { info "No timer '$NAME' in group $P_GROUP; nothing to remove."; exit 0; }
    az rest --method delete --url "$URL" -o none || die "couldn't delete $NAME"
    info "Deleted $NAME. Deploys now run only on GitHub's own schedule, a push, or by hand."; exit 0 ;;
esac

# --- setup ---
az group show --name "$P_GROUP" -o none 2>/dev/null || die "group $P_GROUP not found (run scripts/azure-setup.sh setup first)"
state="$(az provider show --namespace Microsoft.Logic --query registrationState -o tsv 2>/dev/null)"
if [ "$state" != Registered ]; then
  info "Turning on Logic Apps for this subscription (one-time, free)..."
  az provider register --namespace Microsoft.Logic --wait -o none || die "couldn't register Microsoft.Logic"
fi

umask 077
tmp="$(mktemp -d "${TMPDIR:-/tmp}/timer.XXXXXX")" || die "mktemp failed"
trap 'rm -rf "$tmp"' EXIT

info "Paste the GitHub token (fine-grained, repo $P_REPO only, Actions: Read and write)."
info "It isn't shown while you type."
IFS= read -rs token || die "no token"; echo
token="$(printf '%s' "$token" | tr -d '[:space:]')"
printf '%s' "$token" | grep -Eq '^(github_pat_|ghp_)[A-Za-z0-9_]{20,}$' || die "that doesn't look like a GitHub token"
case "$token" in ghp_*) warn "this is a classic token: it can usually reach every repo you own. A fine-grained token limited to $P_REPO is safer." ;; esac

printf 'Authorization: Bearer %s\n' "$token" > "$tmp/auth"
code="$(curl -s -o /dev/null -w '%{http_code}' -H @"$tmp/auth" -H 'Accept: application/vnd.github+json' \
  -H 'X-GitHub-Api-Version: 2022-11-28' "$WORKFLOW_API")"
[ "$code" = 200 ] || die "GitHub answered $code for $WORKFLOW_API with this token: it needs access to $P_REPO"

printf '%s' "$token" > "$tmp/token"
jq -n --arg loc "$P_LOCATION" --rawfile token "$tmp/token" --arg uri "$WORKFLOW_API/dispatches" \
  --arg auth "@{concat('Bearer ', parameters('githubToken'))}" --argjson every "$INTERVAL_MINUTES" '{
  location: $loc,
  properties: {
    state: "Enabled",
    parameters: { githubToken: { value: $token } },
    definition: {
      "$schema": "https://schema.management.azure.com/providers/Microsoft.Logic/schemas/2016-06-01/workflowdefinition.json#",
      contentVersion: "1.0.0.0",
      parameters: { githubToken: { type: "securestring" } },
      triggers: { Every_few_minutes: { type: "Recurrence", recurrence: { frequency: "Minute", interval: $every } } },
      actions: {
        Start_Deploy_workflow: {
          type: "Http",
          runAfter: {},
          inputs: {
            method: "POST",
            uri: $uri,
            headers: {
              Accept: "application/vnd.github+json",
              Authorization: $auth,
              "X-GitHub-Api-Version": "2022-11-28",
              "User-Agent": "deploy-timer"
            },
            body: { ref: "main" },
            retryPolicy: { type: "none" }
          },
          runtimeConfiguration: { secureData: { properties: ["inputs"] } }
        }
      },
      outputs: {}
    }
  }
}' > "$tmp/body.json" || die "couldn't build the timer definition"
unset token

info "Creating/updating Logic App $NAME in $P_GROUP ($P_LOCATION), every $INTERVAL_MINUTES minutes..."
az rest --method put --url "$URL" --body @"$tmp/body.json" -o none || die "couldn't create $NAME"
info "Done. The first tick runs now; check in a minute with: bash scripts/deploy-timer.sh status"
info "and on GitHub: Actions should show Deploy runs started by 'workflow_dispatch'."
