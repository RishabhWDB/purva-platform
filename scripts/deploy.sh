#!/usr/bin/env bash
# Brings each container app in line with apps/<app>.conf. Run by
# .github/workflows/deploy.yml, signed in to Azure as the deployer identity.
#
#   bash scripts/deploy.sh [all|<app>] [<tag>]
#
# For each app:
#   image:  <tag> if given (one app only), else the newest image the team uploaded
#           to <registry>/<app>, unless that image was deployed before (a failed or
#           rolled-back image is never retried by itself), else the current image.
#   size:   CPU, MEMORY, MIN_REPLICAS, MAX_REPLICAS from the conf, always.
# The app is changed only if something differs. Then it waits until the new
# revision is ready and HEALTH_PATH answers; if not, it puts the previous image back.
#
# DRY_RUN=1 only says what would change. Exit code 1 if any app failed.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
. scripts/lib.sh

TARGET="${1:-all}"; TAG="${2:-}"
DRY_RUN="${DRY_RUN:-0}"
WAIT_SECONDS="${WAIT_SECONDS:-300}"; SLEEP_SECONDS="${SLEEP_SECONDS:-10}"

summary() { [ -z "${GITHUB_STEP_SUMMARY:-}" ] || printf '%s\n' "$*" >> "$GITHUB_STEP_SUMMARY"; }

load_platform
command -v jq >/dev/null || die "jq not found"
if [ "$TARGET" = all ]; then
  [ -z "$TAG" ] || die "a tag can only be given for one app, not 'all'"
  APPS="$(app_list)"
else
  valid_app_name "$TARGET" && [ -f "apps/$TARGET.conf" ] || die "no app '$TARGET' (apps: $(app_list | tr '\n' ' '))"
  APPS="$TARGET"
fi
[ -z "$TAG" ] || printf '%s' "$TAG" | grep -Eq '^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$' || die "bad tag '$TAG'"

# wait_healthy APP IMAGE -> 0 when the latest revision runs IMAGE, is ready, and
# the health check passes
wait_healthy() {
  local app="$1" image="$2" deadline j latest ready cur fqdn code body ok
  deadline=$(( $(date +%s) + WAIT_SECONDS ))
  while :; do
    j="$(az containerapp show --name "$app" --resource-group "$app" -o json 2>/dev/null || echo '{}')"
    latest="$(printf '%s' "$j" | jq -r '.properties.latestRevisionName // ""')"
    ready="$(printf '%s' "$j" | jq -r '.properties.latestReadyRevisionName // ""')"
    cur="$(printf '%s' "$j" | jq -r '.properties.template.containers[0].image // ""')"
    fqdn="$(printf '%s' "$j" | jq -r '.properties.configuration.ingress.fqdn // ""')"
    code=-; ok=0
    if [ -n "$latest" ] && [ "$latest" = "$ready" ] && [ "$cur" = "$image" ]; then
      if [ "$A_HEALTH" = - ]; then
        ok=1
      elif [ -n "$fqdn" ]; then
        body="$(curl -s --max-time 30 -w '\n%{http_code}' "https://$fqdn$A_HEALTH" || true)"
        code="${body##*$'\n'}"; body="${body%$'\n'*}"
        if [ "$code" = 200 ]; then
          if [ -z "$A_BODY" ] || [ "$(printf '%s' "$body" | tr -d '\r\n')" = "$A_BODY" ]; then ok=1; else code="200 (body isn't '$A_BODY')"; fi
        fi
      fi
    fi
    if [ "$ok" = 1 ]; then info "  revision $latest is ready${fqdn:+ and https://$fqdn$A_HEALTH answers}"; return 0; fi
    info "  waiting: latest=$latest ready=$ready health=$code"
    if [ "$(date +%s)" -ge "$deadline" ]; then
      warn "$app: revision $latest wasn't ready and healthy within $WAIT_SECONDS s"
      [ -z "$latest" ] || az containerapp revision show --name "$app" --resource-group "$app" --revision "$latest" \
        --query "{state:properties.runningState, health:properties.healthState, details:properties.runningStateDetails}" -o json || true
      [ -z "$latest" ] || az containerapp logs show --name "$app" --resource-group "$app" --revision "$latest" --tail 50 --type console 2>/dev/null || true
      return 1
    fi
    sleep "$SLEEP_SECONDS"
  done
}

deploy_one() {
  local app="$1" j cur_image cur_cpu cur_mem cur_min cur_max n want newest seen args what
  load_app "$app" || return 1
  j="$(az containerapp show --name "$app" --resource-group "$app" -o json)" || { warn "$app: can't read the container app"; return 1; }
  n="$(printf '%s' "$j" | jq '.properties.template.containers | length')"
  [ "$n" = 1 ] || { warn "$app: has $n containers; this script handles exactly 1"; return 1; }
  cur_image="$(printf '%s' "$j" | jq -r '.properties.template.containers[0].image')"
  cur_cpu="$(printf '%s' "$j" | jq -r '.properties.template.containers[0].resources.cpu')"
  cur_mem="$(printf '%s' "$j" | jq -r '.properties.template.containers[0].resources.memory')"
  cur_min="$(printf '%s' "$j" | jq -r '.properties.template.scale.minReplicas // 0')"
  cur_max="$(printf '%s' "$j" | jq -r '.properties.template.scale.maxReplicas // 10')"

  want="$cur_image"
  if [ -n "$TAG" ]; then
    az acr repository show --name "$P_ACR" --image "$app:$TAG" -o none 2>/dev/null \
      || { warn "$app: no image $P_SERVER/$app:$TAG"; return 1; }
    want="$P_SERVER/$app:$TAG"
  else
    newest="$(az acr repository show-tags --name "$P_ACR" --repository "$app" --orderby time_desc --top 1 -o tsv 2>/dev/null | head -1)"
    if [ -n "$newest" ] && [ "$P_SERVER/$app:$newest" != "$cur_image" ]; then
      seen="$(az containerapp revision list --name "$app" --resource-group "$app" --all -o json 2>/dev/null \
        | jq -r --arg i "$P_SERVER/$app:$newest" '[.[] | select(.properties.template.containers[0].image == $i)] | length')"
      if [ "${seen:-0}" = 0 ]; then
        want="$P_SERVER/$app:$newest"
      else
        info "  newest image $newest was deployed before and replaced (failed or rolled back); not retrying it by itself"
      fi
    fi
  fi

  args=(); what=""
  if [ "$want" != "$cur_image" ]; then args+=(--image "$want"); what="$what image ${cur_image##*:} -> ${want##*:};"; fi
  if ! num_eq "$cur_cpu" "$A_CPU" || [ "$cur_mem" != "$A_MEM" ]; then
    args+=(--cpu "$A_CPU" --memory "$A_MEM"); what="$what size $cur_cpu/$cur_mem -> $A_CPU/$A_MEM;"
  fi
  if [ "$cur_min" != "$A_MIN" ] || [ "$cur_max" != "$A_MAX" ]; then
    args+=(--min-replicas "$A_MIN" --max-replicas "$A_MAX"); what="$what replicas $cur_min-$cur_max -> $A_MIN-$A_MAX;"
  fi
  if [ ${#args[@]} -eq 0 ]; then
    info "  up to date (${cur_image##*/})"; summary "| $app | up to date | \`${cur_image##*/}\` |"; return 0
  fi
  what="${what# }"; what="${what%;}"
  if [ "$DRY_RUN" = 1 ]; then
    info "  would change: $what"; summary "| $app | would change: $what | |"; return 0
  fi
  info "  changing: $what"
  if az containerapp update --name "$app" --resource-group "$app" "${args[@]}" -o none && wait_healthy "$app" "$want"; then
    summary "| $app | deployed: $what | \`${want##*/}\` |"; return 0
  fi
  if [ "$want" != "$cur_image" ]; then
    warn "$app: putting the previous image back (${cur_image##*/})"
    if az containerapp update --name "$app" --resource-group "$app" --image "$cur_image" -o none && wait_healthy "$app" "$cur_image"; then
      summary "| $app | **FAILED**, previous image restored: $what | \`${cur_image##*/}\` |"
    else
      summary "| $app | **FAILED, and the previous image didn't come back healthy either** | |"
    fi
  else
    summary "| $app | **FAILED**: $what | |"
  fi
  return 1
}

summary "| App | Result | Image |"
summary "|---|---|---|"
failed=""
for app in $APPS; do
  info "== $app"
  deploy_one "$app" || failed="$failed $app"
done
[ "$DRY_RUN" = 1 ] && info "Dry run: nothing was changed."
if [ -n "$failed" ]; then
  printf '::error::failed:%s\n' "$failed"
  exit 1
fi
info "All done."
