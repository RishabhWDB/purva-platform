# shellcheck shell=bash disable=SC2034
# Shared helpers for deploy.sh and azure-setup.sh (sourced, not run).

info() { printf '%s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# conf_get FILE KEY: value of KEY=value (last one wins; comments and blank lines ignored)
conf_get() {
  awk -v k="$2" '{ sub(/\r$/, "") } /^[ \t]*#/ { next } index($0, "=") == 0 { next }
    { key = substr($0, 1, index($0, "=") - 1); gsub(/^[ \t]+|[ \t]+$/, "", key)
      if (key == k) { v = substr($0, index($0, "=") + 1); gsub(/^[ \t]+|[ \t]+$/, "", v); val = v } }
    END { print val }' "$1"
}

# conf_set FILE KEY VALUE: replace the KEY= line (it must exist)
conf_set() {
  local tmp; tmp="$(mktemp "${TMPDIR:-/tmp}/conf.XXXXXX")"
  awk -v k="$2" -v v="$3" '{ line = $0; sub(/\r$/, "", line) }
    index(line, "=") > 0 && line !~ /^[ \t]*#/ { key = substr(line, 1, index(line, "=") - 1); gsub(/^[ \t]+|[ \t]+$/, "", key)
      if (key == k) { print k "=" v; next } }
    { print }' "$1" > "$tmp" && cat "$tmp" > "$1"
  rm -f "$tmp"
}

lc() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
num_eq() { awk -v a="$1" -v b="$2" 'BEGIN { exit !((a + 0) == (b + 0)) }'; }
is_guid() { printf '%s' "$1" | grep -Eq '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'; }
valid_app_name() { printf '%s' "$1" | grep -Eq '^[a-z][a-z0-9-]{0,31}$'; }

# Platform settings -> P_* variables (dies on a bad value)
load_platform() {
  local f=platform.conf
  [ -f "$f" ] || die "$f not found (run from the repo root)"
  P_SUB="$(conf_get $f SUBSCRIPTION_ID)"; P_TENANT="$(conf_get $f TENANT_ID)"
  P_LOCATION="$(conf_get $f LOCATION)"; P_REPO="$(conf_get $f GITHUB_REPO)"
  P_OWNER_ID="$(conf_get $f GITHUB_OWNER_ID)"; P_REPO_ID="$(conf_get $f GITHUB_REPO_ID)"
  P_GROUP="$(conf_get $f PLATFORM_GROUP)"; P_IDENTITY="$(conf_get $f DEPLOYER_IDENTITY)"
  P_CLIENT="$(conf_get $f DEPLOYER_CLIENT_ID)"
  P_ACR="$(conf_get $f ACR_NAME)"; P_ACR_GROUP="$(conf_get $f ACR_GROUP)"
  P_ENV="$(conf_get $f ENV_NAME)"; P_ENV_GROUP="$(conf_get $f ENV_GROUP)"
  P_ENV_ROLE="$(conf_get $f ENV_ROLE_NAME)"
  is_guid "$P_SUB" || die "bad SUBSCRIPTION_ID in $f"
  is_guid "$P_TENANT" || die "bad TENANT_ID in $f"
  [ -z "$P_CLIENT" ] || is_guid "$P_CLIENT" || die "bad DEPLOYER_CLIENT_ID in $f"
  printf '%s' "$P_ACR" | grep -Eq '^[a-z0-9]{5,50}$' || die "bad ACR_NAME in $f"
  printf '%s' "$P_REPO" | grep -Eq '^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$' || die "bad GITHUB_REPO in $f"
  for v in "$P_GROUP" "$P_IDENTITY" "$P_ACR_GROUP" "$P_ENV" "$P_ENV_GROUP"; do
    printf '%s' "$v" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$' || die "bad name '$v' in $f"
  done
  [ -n "$P_ENV_ROLE" ] || die "ENV_ROLE_NAME is empty in $f"
  P_SERVER="$P_ACR.azurecr.io"
}

# app_list: names of apps/*.conf, sorted
app_list() { ls apps/*.conf 2>/dev/null | sed 's#^apps/##; s#\.conf$##' | sort; }

# load_app NAME -> A_* variables. Returns 1 (with a message) on a bad value.
load_app() {
  local a="$1" f
  valid_app_name "$a" || { warn "bad app name '$a'"; return 1; }
  f="apps/$a.conf"
  [ -f "$f" ] || { warn "no $f"; return 1; }
  A_APP="$a"; A_GROUP="$a"; A_IDENTITY="$a-github"
  A_SOURCE="$(conf_get "$f" SOURCE_REPO)"
  A_CPU="$(conf_get "$f" CPU)"; A_MEM="$(conf_get "$f" MEMORY)"
  A_MIN="$(conf_get "$f" MIN_REPLICAS)"; A_MAX="$(conf_get "$f" MAX_REPLICAS)"
  A_HEALTH="$(conf_get "$f" HEALTH_PATH)"; A_BODY="$(conf_get "$f" HEALTH_BODY)"
  A_SWA="$(conf_get "$f" STATIC_WEB_APP)"
  printf '%s' "$A_CPU" | grep -Eq '^(0\.25|0\.5|0\.75|1|1\.25|1\.5|1\.75|2)$' \
    || { warn "$f: CPU must be 0.25 to 2 in steps of 0.25 (got '$A_CPU')"; return 1; }
  printf '%s' "$A_MEM" | grep -Eq '^[0-9.]+Gi$' && num_eq "${A_MEM%Gi}" "$(awk -v c="$A_CPU" 'BEGIN { print c * 2 }')" \
    || { warn "$f: MEMORY must be 2 x CPU in Gi (got '$A_MEM' for CPU $A_CPU)"; return 1; }
  printf '%s' "$A_MIN" | grep -Eq '^[0-9]$' && printf '%s' "$A_MAX" | grep -Eq '^[1-9][0-9]?$' \
    && [ "$A_MIN" -le "$A_MAX" ] || { warn "$f: need 0 <= MIN_REPLICAS <= MAX_REPLICAS, MAX >= 1"; return 1; }
  case "$A_HEALTH" in -) ;; /*) printf '%s' "$A_HEALTH" | grep -Eq '^/[A-Za-z0-9/_.~-]*$' \
    || { warn "$f: bad HEALTH_PATH"; return 1; } ;; *) warn "$f: HEALTH_PATH must start with / (or be -)"; return 1 ;; esac
  [ -z "$A_SWA" ] || printf '%s' "$A_SWA" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9-]{0,58}$' \
    || { warn "$f: bad STATIC_WEB_APP"; return 1; }
  return 0
}
