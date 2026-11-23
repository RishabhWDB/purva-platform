#!/usr/bin/env bash
# Azure side of purva-platform. Run in Azure Cloud Shell (Bash) as the subscription
# Owner, from a clone of this repo. Safe to rerun; DRY_RUN=1 changes nothing.
#
#   bash scripts/azure-setup.sh status   who can do what today (changes nothing)
#   bash scripts/azure-setup.sh setup    create the deployer identity this repo signs in
#                                        as, and give it deploy rights on every app
#   bash scripts/azure-setup.sh lock     take deploy rights away from every team's
#                                        <app>-github identity: they keep only "upload
#                                        images to their own registry repository" (and,
#                                        for apps with a Static Web App, reading its
#                                        upload token)
#   bash scripts/azure-setup.sh unlock   give the teams their old rights back
#
# Never changes or deletes an app, the shared environment or the registry; only
# role assignments, plus the purva-platform group and its one identity.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
. scripts/lib.sh

ACTION="${1:-status}"
DRY_RUN="${DRY_RUN:-0}"
SWA_ROLE="Static Web App upload token reader (purva)"
case "$ACTION" in status|setup|lock|unlock) ;; *) die "usage: bash scripts/azure-setup.sh status|setup|lock|unlock" ;; esac

run() {
  if [ "$DRY_RUN" = 1 ]; then info "  would run: az $*"; return 0; fi
  az "$@"
}

load_platform
command -v jq >/dev/null || die "jq not found"
sub="$(az account show --query id -o tsv 2>/dev/null)" || die "not signed in (az login)"
[ "$sub" = "$P_SUB" ] || die "signed in to subscription $sub, expected $P_SUB (az account set --subscription $P_SUB)"
SUBID="/subscriptions/$P_SUB"

ENV_ID="$(az resource show --resource-group "$P_ENV_GROUP" --name "$P_ENV" --resource-type Microsoft.App/managedEnvironments --query id -o tsv)" \
  || die "can't find environment $P_ENV in $P_ENV_GROUP"
ACR_ID="$(az acr show --name "$P_ACR" --resource-group "$P_ACR_GROUP" --query id -o tsv)" || die "can't find registry $P_ACR"

APPS="$(app_list)"
[ -n "$APPS" ] || die "no apps/*.conf"
for a in $APPS; do load_app "$a" || die "fix apps/$a.conf first"; done

# assignments PRINCIPAL -> JSON lines {role, scope, id}
assignments() {
  az role assignment list --assignee-object-id "$1" --all -o json 2>/dev/null \
    | jq -c '.[] | {role: .roleDefinitionName, scope: .scope, id: .id}'
}

# has_role PRINCIPAL ROLE SCOPE
has_role() {
  assignments "$1" | jq -e --arg r "$(lc "$2")" --arg s "$(lc "$3")" \
    'select((.role | ascii_downcase) == $r and (.scope | ascii_downcase) == $s)' >/dev/null
}

# grant PRINCIPAL ROLE SCOPE LABEL (retries while a new identity or role appears)
grant() {
  local p="$1" role="$2" scope="$3" label="$4" i err
  if has_role "$p" "$role" "$scope"; then info "  $label: already there"; return 0; fi
  if [ "$DRY_RUN" = 1 ]; then info "  $label: would grant"; return 0; fi
  err="$(mktemp "${TMPDIR:-/tmp}/grant.XXXXXX")"
  for i in 1 2 3 4 5 6; do
    if az role assignment create --assignee-object-id "$p" --assignee-principal-type ServicePrincipal \
        --role "$role" --scope "$scope" -o none 2>"$err"; then
      info "  $label: granted"; rm -f "$err"; return 0
    fi
    grep -q RoleAssignmentExists "$err" && { info "  $label: already there"; rm -f "$err"; return 0; }
    warn "$label: not yet (attempt $i): $(head -c 300 "$err")"
    sleep "${GRANT_RETRY_SECONDS:-20}"
  done
  rm -f "$err"; die "$label: could not grant $role. Wait a minute and rerun."
}

# principal_of GROUP IDENTITY -> principal id (empty if missing)
principal_of() { az identity show --resource-group "$1" --name "$2" --query principalId -o tsv 2>/dev/null || true; }

group_id() { printf '%s/resourceGroups/%s' "$SUBID" "$1"; }

swa_id() { az staticwebapp show --name "$1" --resource-group "$2" --query id -o tsv 2>/dev/null; }

ensure_swa_role() {
  local f
  if [ -n "$(az role definition list --name "$SWA_ROLE" --custom-role-only true --query '[].id' -o tsv 2>/dev/null)" ]; then
    info "  role '$SWA_ROLE': exists"; return 0
  fi
  f="$(mktemp "${TMPDIR:-/tmp}/swarole.XXXXXX")"
  jq -n --arg n "$SWA_ROLE" --arg s "$SUBID" '{Name: $n, IsCustom: true,
    Description: "Read a Static Web App and its upload (deployment) token. Nothing else.",
    Actions: ["Microsoft.Web/staticSites/read", "Microsoft.Web/staticSites/listSecrets/action"],
    NotActions: [], DataActions: [], NotDataActions: [], AssignableScopes: [$s]}' > "$f"
  run role definition create --role-definition "@$f" -o none || { rm -f "$f"; die "could not create role '$SWA_ROLE'"; }
  rm -f "$f"; info "  role '$SWA_ROLE': created"
}

show_roles() {  # PRINCIPAL LABEL
  local line
  info "$2:"
  assignments "$1" | while IFS= read -r line; do
    info "  $(printf '%s' "$line" | jq -r '.role') on $(printf '%s' "$line" | jq -r '.scope' | sed "s#^$SUBID##")"
  done
}

# ---------------------------------------------------------------------------
if [ "$ACTION" = status ]; then
  p="$(principal_of "$P_GROUP" "$P_IDENTITY")"
  if [ -n "$p" ]; then show_roles "$p" "$P_IDENTITY (this repo's deployer)"; else info "$P_IDENTITY: not created yet (run setup)"; fi
  for a in $APPS; do
    load_app "$a"
    p="$(principal_of "$A_GROUP" "$A_IDENTITY")"
    if [ -n "$p" ]; then show_roles "$p" "$A_IDENTITY (team $A_SOURCE)"; else info "$A_IDENTITY: not found"; fi
  done
  exit 0
fi

# ---------------------------------------------------------------------------
if [ "$ACTION" = setup ]; then
  info "== Group $P_GROUP and identity $P_IDENTITY"
  if az group show --name "$P_GROUP" -o none 2>/dev/null; then info "  group: exists"
  else run group create --name "$P_GROUP" --location "$P_LOCATION" -o none || die "could not create group $P_GROUP"; [ "$DRY_RUN" = 1 ] && info "  group: would be created" || info "  group: created"; fi
  if az identity show --resource-group "$P_GROUP" --name "$P_IDENTITY" -o none 2>/dev/null; then info "  identity: exists"
  else run identity create --resource-group "$P_GROUP" --name "$P_IDENTITY" --location "$P_LOCATION" -o none || die "could not create identity"; [ "$DRY_RUN" = 1 ] && info "  identity: would be created" || info "  identity: created"; fi
  P_PRINCIPAL="$(principal_of "$P_GROUP" "$P_IDENTITY")"
  CLIENT="$(az identity show --resource-group "$P_GROUP" --name "$P_IDENTITY" --query clientId -o tsv 2>/dev/null || true)"
  if [ -z "$P_PRINCIPAL" ]; then
    [ "$DRY_RUN" = 1 ] || die "identity $P_IDENTITY has no principal id"
    info "Dry run: the identity doesn't exist yet, so its sign-in and roles can't be checked."; exit 0
  fi

  info "== Sign-in from GitHub (main branch of $P_REPO only)"
  fed="$(az identity federated-credential list --resource-group "$P_GROUP" --identity-name "$P_IDENTITY" -o json 2>/dev/null || echo '[]')"
  pairs="github-main|repo:$P_REPO:ref:refs/heads/main"
  if [ -n "$P_OWNER_ID" ] && [ -n "$P_REPO_ID" ]; then
    pairs="$pairs github-main-id|repo:${P_REPO%%/*}@$P_OWNER_ID/${P_REPO#*/}@$P_REPO_ID:ref:refs/heads/main"
  else
    warn "GITHUB_OWNER_ID / GITHUB_REPO_ID empty in platform.conf: only the name form of the subject is added"
  fi
  for pair in $pairs; do
    name="${pair%%|*}"; subject="${pair#*|}"
    have="$(printf '%s' "$fed" | jq -r --arg n "$name" '.[] | select(.name == $n) | .subject')"
    if [ "$have" = "$subject" ]; then info "  $name: exists"; continue; fi
    [ -z "$have" ] || die "credential $name exists with subject '$have' (expected '$subject'). Delete it in the portal and rerun."
    run identity federated-credential create --resource-group "$P_GROUP" --identity-name "$P_IDENTITY" --name "$name" \
      --issuer https://token.actions.githubusercontent.com --subject "$subject" --audiences api://AzureADTokenExchange -o none \
      || die "could not add credential $name"
    info "  $name: added ($subject)"
  done

  info "== Roles for $P_IDENTITY"
  for a in $APPS; do
    az group show --name "$a" -o none 2>/dev/null || die "group $a doesn't exist"
    grant "$P_PRINCIPAL" Contributor "$(group_id "$a")" "Contributor on group $a"
  done
  grant "$P_PRINCIPAL" "$P_ENV_ROLE" "$ENV_ID" "environment join on $P_ENV"
  grant "$P_PRINCIPAL" Reader "$ACR_ID" "Reader on registry $P_ACR (find it)"
  grant "$P_PRINCIPAL" "Container Registry Repository Reader" "$ACR_ID" "read every repository in $P_ACR (find new images)"

  info ""
  info "Done. Deployer client ID: $CLIENT"
  info "Put it in platform.conf as DEPLOYER_CLIENT_ID=$CLIENT and push to main."
  exit 0
fi

# ---------------------------------------------------------------------------
if [ "$ACTION" = lock ]; then
  p="$(principal_of "$P_GROUP" "$P_IDENTITY")"
  [ -n "$p" ] || die "run setup first: $P_IDENTITY doesn't exist, so nothing could deploy after locking"
  for a in $APPS; do
    has_role "$p" Contributor "$(group_id "$a")" || die "the deployer has no Contributor on group $a yet; run setup first"
  done
  if [ -z "$P_CLIENT" ]; then
    [ "${FORCE:-0}" = 1 ] || die "DEPLOYER_CLIENT_ID is empty in platform.conf, so this repo can't deploy yet. Push it and check a deploy works first (FORCE=1 to lock anyway)."
  fi
  need_swa=0
  for a in $APPS; do
    load_app "$a"
    [ -n "$A_SWA" ] || continue
    need_swa=1
    swa_id "$A_SWA" "$A_GROUP" >/dev/null || die "can't find Static Web App $A_SWA in group $A_GROUP (apps/$a.conf); nothing was changed"
  done
  [ "$need_swa" = 0 ] || ensure_swa_role

  for a in $APPS; do
    load_app "$a"
    info "== $A_IDENTITY ($A_SOURCE)"
    t="$(principal_of "$A_GROUP" "$A_IDENTITY")"
    [ -n "$t" ] || { warn "$A_IDENTITY not found in group $A_GROUP; skipped"; continue; }
    if [ -n "$A_SWA" ]; then
      sid="$(swa_id "$A_SWA" "$A_GROUP")" || die "can't find Static Web App $A_SWA in group $A_GROUP"
      grant "$t" "$SWA_ROLE" "$sid" "upload token of $A_SWA (website deploys keep working)"
    fi
    gid="$(lc "$(group_id "$A_GROUP")")"; eid="$(lc "$ENV_ID")"
    assignments "$t" > "${TMPDIR:-/tmp}/assign.$$"
    while IFS= read -r line; do
      role="$(printf '%s' "$line" | jq -r '.role')"; scope="$(lc "$(printf '%s' "$line" | jq -r '.scope')")"
      id="$(printf '%s' "$line" | jq -r '.id')"
      short="$(printf '%s' "$scope" | sed "s#^$(lc "$SUBID")##")"
      if { [ "$role" = Contributor ] && [ "$scope" = "$gid" ]; } || { [ "$(lc "$role")" = "$(lc "$P_ENV_ROLE")" ] && [ "$scope" = "$eid" ]; }; then
        run role assignment delete --ids "$id" -o none || die "could not remove $role on $short"
        info "  removed: $role on $short"
      else
        info "  kept: $role on $short"
      fi
    done < "${TMPDIR:-/tmp}/assign.$$"
    rm -f "${TMPDIR:-/tmp}/assign.$$"
  done
  info ""
  [ "$DRY_RUN" = 1 ] && info "Dry run: nothing was changed." || info "Done. Teams can now only upload images; this repo deploys them."
  exit 0
fi

# ---------------------------------------------------------------------------
if [ "$ACTION" = unlock ]; then
  for a in $APPS; do
    load_app "$a"
    info "== $A_IDENTITY"
    t="$(principal_of "$A_GROUP" "$A_IDENTITY")"
    [ -n "$t" ] || { warn "$A_IDENTITY not found; skipped"; continue; }
    grant "$t" Contributor "$(group_id "$A_GROUP")" "Contributor on group $A_GROUP"
    grant "$t" "$P_ENV_ROLE" "$ENV_ID" "environment join on $P_ENV"
  done
  [ "$DRY_RUN" = 1 ] && info "Dry run: nothing was changed." || info "Done. Teams can deploy (and change their apps) again."
  exit 0
fi
