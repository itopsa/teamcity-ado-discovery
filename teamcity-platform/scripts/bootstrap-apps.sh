#!/usr/bin/env bash
# Bootstrap Apps (level 1 discovery).
#
# For every app in the catalog, make sure TeamCity has:
#   <BU project>            (created under _Root only if missing - normally it is the existing legacy BU project)
#   <BU> / <App> project    with a VCS root on teamcity-platform and versioned settings:
#                             Kotlin, "use settings from VCS", context parameter app=<bu>/<app>
# Existing app projects are left untouched (idempotent).
#
# Environment (set by the generated "Bootstrap Apps" job):
#   TC_URL, TC_TOKEN          TeamCity server URL and access token (Project administrator on BU projects)
#   CATALOG_APPS              key|buProjectId|bu|appId|appName|adoProject|type=prefix,...
#   PLATFORM_REPO_URL         git URL of teamcity-platform
#   PLATFORM_REPO_BRANCH      default refs/heads/main
# Optional:
#   DRY_RUN=1                 print what would be created, change nothing
#
# Uses the TeamCity REST versioned-settings endpoints (TeamCity 2023.05+):
#   PUT  /app/rest/projects/{id}/versionedSettings/config
#   PUT  /app/rest/projects/{id}/versionedSettings/contextParameters
#   POST /app/rest/projects/{id}/versionedSettings/loadSettings
# The script checks your server exposes them before changing anything.
set -euo pipefail

: "${TC_URL:?TC_URL is required}"
: "${TC_TOKEN:?TC_TOKEN is required}"
: "${CATALOG_APPS:?CATALOG_APPS is required}"
: "${PLATFORM_REPO_URL:?PLATFORM_REPO_URL is required}"
BRANCH="${PLATFORM_REPO_BRANCH:-refs/heads/main}"

TC="${TC_URL%/}/app/rest"
log() { echo "[bootstrap] $*"; }

tc() { # tc METHOD PATH [JSON]
  local method="$1" path="$2" body="${3:-}"
  if [ "${DRY_RUN:-0}" = "1" ] && [ "$method" != "GET" ]; then
    log "DRY_RUN $method $path ${body:+$body}"; return 0
  fi
  curl -sfS -X "$method" "$TC/$path" \
    -H "Authorization: Bearer $TC_TOKEN" -H "Accept: application/json" -H "Content-Type: application/json" \
    ${body:+--data "$body"}
}
exists() { tc GET "projects/id:$1" > /dev/null 2>&1; }

# ---- preflight ---------------------------------------------------------------------------
if ! tc GET "swagger.json" 2>/dev/null | grep -q 'versionedSettings/contextParameters'; then
  echo "##teamcity[buildProblem description='TeamCity REST API has no versionedSettings/contextParameters endpoint (needs 2023.05+). See README: manual onboarding.']"
  exit 1
fi

created=0
while IFS='|' read -r key bu_id bu app_id app_name _ _; do
  [ -z "${key:-}" ] && continue

  if ! exists "$bu_id"; then
    log "Creating BU project $bu_id ($bu)"
    tc POST "projects" "$(jq -nc --arg id "$bu_id" --arg n "$bu" \
      '{id:$id, name:$n, parentProject:{locator:"id:_Root"}}')" > /dev/null
  fi

  if exists "$app_id"; then
    log "OK       $key ($app_id exists)"
    continue
  fi

  log "Creating $key -> $app_id under $bu_id"
  tc POST "projects" "$(jq -nc --arg id "$app_id" --arg n "$app_name" --arg p "id:$bu_id" \
    '{id:$id, name:$n, parentProject:{locator:$p}}')" > /dev/null

  root_id="${app_id}_PlatformSettings"
  tc POST "vcs-roots" "$(jq -nc --arg id "$root_id" --arg p "$app_id" --arg url "$PLATFORM_REPO_URL" --arg br "$BRANCH" '
    {id:$id, name:"teamcity-platform (settings)", vcsName:"jetbrains.git", project:{id:$p},
     properties:{property:[
       {name:"url", value:$url},
       {name:"branch", value:$br},
       {name:"authMethod", value:"PASSWORD"},
       {name:"username", value:"teamcity"},
       {name:"secure:password", value:"%ado.pat%"}]}}')" > /dev/null

  tc PUT "projects/id:$app_id/versionedSettings/config" "$(jq -nc --arg r "$root_id" '
    {synchronizationMode:"enabled", vcsRootId:$r, format:"kotlin",
     buildSettingsMode:"useFromVCS", allowUIEditing:false, showSettingsChanges:true,
     storeSecureValuesOutsideVcs:true, importDecision:"importFromVCS"}')" > /dev/null

  tc PUT "projects/id:$app_id/versionedSettings/contextParameters" "$(jq -nc --arg k "$key" \
    '{parameter:[{name:"app", value:$k}]}')" > /dev/null

  tc POST "projects/id:$app_id/versionedSettings/loadSettings" > /dev/null || \
    log "WARNING: loadSettings failed for $app_id - check its Versioned Settings tab"

  created=$((created + 1))
done <<< "$CATALOG_APPS"

log "Done. $created app project(s) created."
