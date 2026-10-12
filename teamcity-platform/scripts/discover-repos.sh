#!/usr/bin/env bash
# Discover Repos (level 2 discovery).
#
# For every app in the catalog: list the repos in its Azure DevOps project, classify each one,
# write .teamcity/repos/<bu>/<app>.txt in the platform repo, and push if anything changed.
#
# Classification, in order:
#   1. ci.yaml on the repo's default branch:  type: <template>   azure_name: <name>   enabled: false
#   2. repo-name prefix rules from the catalog (e.g. FA- -> function-app)
#   Repos that match neither, or declare an unknown type, are skipped (with a warning).
#
# Environment (set by the generated "Discover Repos" job):
#   ADO_ORG, ADO_PAT          Azure DevOps org and PAT (Code Read on app projects, Code Write on platform repo)
#   CATALOG_APPS              key|buProjectId|bu|appId|appName|adoProject|type=prefix,...   (one app per line)
#   KNOWN_TYPES               space-separated template types, e.g. "function-app web-app"
#   PLATFORM_REPO_URL         git URL of teamcity-platform
#   PLATFORM_REPO_BRANCH      default refs/heads/main
# Optional:
#   DRY_RUN=1                 write files but do not push
#   ADO_API_BASE              override the ADO API base URL (tests)
set -euo pipefail

: "${ADO_ORG:?ADO_ORG is required}"
: "${ADO_PAT:?ADO_PAT is required}"
: "${CATALOG_APPS:?CATALOG_APPS is required}"
: "${KNOWN_TYPES:?KNOWN_TYPES is required}"
: "${PLATFORM_REPO_URL:?PLATFORM_REPO_URL is required}"

API="${ADO_API_BASE:-https://dev.azure.com/$ADO_ORG}"
BRANCH="${PLATFORM_REPO_BRANCH:-refs/heads/main}"
BRANCH="${BRANCH#refs/heads/}"
B64_AUTH="$(printf ':%s' "$ADO_PAT" | base64 | tr -d '\n')"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

log()  { echo "[discover] $*"; }
warn() { echo "##teamcity[message text='$(tc_escape "$*")' status='WARNING']"; }
tc_escape() { printf '%s' "$1" | sed -e "s/|/||/g" -e "s/'/|'/g" -e 's/\[/|[/g' -e 's/\]/|]/g'; }
urlenc() { jq -rn --arg v "$1" '$v|@uri'; }
ado() { curl -sfS --retry 3 --retry-delay 2 -H "Authorization: Basic $B64_AUTH" "$API/$1"; }
git_auth() { git -c http.extraheader="AUTHORIZATION: Basic $B64_AUTH" "$@"; }

# Reads a top-level scalar "key: value" from a simple YAML file (quotes and trailing comments stripped).
yaml_get() {
  sed -n -E "s/^$1:[[:space:]]*//p" "$2" | head -n1 \
    | sed -E -e 's/[[:space:]]+#.*$//' -e 's/^["'"'"']//' -e 's/["'"'"']$//' -e 's/[[:space:]]+$//'
}
is_known() { local t; for t in $KNOWN_TYPES; do [ "$t" = "$1" ] && return 0; done; return 1; }

# ---- clone the platform repo -------------------------------------------------------------
REPO_DIR="$WORK/platform"
git_auth clone -q --depth 1 --branch "$BRANCH" "$PLATFORM_REPO_URL" "$REPO_DIR"

changed_apps=()

# ---- per catalog app ---------------------------------------------------------------------
while IFS='|' read -r key _ _ app_id _ ado_project rules; do
  [ -z "${key:-}" ] && continue
  log "== $key (ADO project: $ado_project)"
  out="$REPO_DIR/.teamcity/repos/$key.txt"
  tmp="$WORK/${app_id}.txt"
  : > "$tmp"
  proj_enc="$(urlenc "$ado_project")"

  if ! repos_json="$(ado "$proj_enc/_apis/git/repositories?api-version=7.1")"; then
    warn "$key: could not list repos in ADO project '$ado_project' - keeping the existing list"
    continue
  fi

  while IFS=$'\t' read -r rid rname rurl rbranch; do
    type=""; azname=""; enabled="true"
    vbranch="$(urlenc "${rbranch#refs/heads/}")"
    ci_file="$WORK/ci.yaml"
    if ado "$proj_enc/_apis/git/repositories/$rid/items?path=%2Fci.yaml&includeContent=true&versionDescriptor.version=$vbranch&versionDescriptor.versionType=branch&api-version=7.1" \
         2>/dev/null | jq -r '.content // empty' > "$ci_file" && [ -s "$ci_file" ]; then
      type="$(yaml_get type "$ci_file")"
      azname="$(yaml_get azure_name "$ci_file")"
      enabled="$(yaml_get enabled "$ci_file")"; enabled="${enabled:-true}"
      source="ci.yaml"
    else
      source="prefix"
    fi

    if [ "$enabled" = "false" ]; then
      log "   skip $rname (ci.yaml enabled: false)"; continue
    fi

    if [ -z "$type" ]; then
      IFS=',' read -ra pairs <<< "$rules"
      for pair in "${pairs[@]}"; do
        prefix="${pair#*=}"
        if [ -n "$prefix" ] && [[ "$rname" == "$prefix"* ]]; then type="${pair%%=*}"; break; fi
      done
    fi

    if [ -z "$type" ]; then
      log "   skip $rname (no ci.yaml type and no prefix match)"; continue
    fi
    if ! is_known "$type"; then
      warn "$key: repo $rname declares unknown type '$type' - skipped (known: $KNOWN_TYPES)"; continue
    fi

    [ -z "$azname" ] && azname="$rname"
    azname="$(printf '%s' "$azname" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9-]+/-/g; s/^-+|-+$//g')"

    log "   add  $rname -> $type ($source), azure name $azname"
    printf '%s|%s|%s|%s|%s\n' "$rname" "$rurl" "$type" "$rbranch" "$azname" >> "$tmp"
  done < <(jq -r '.value[]
                  | select(.isDisabled != true)
                  | select(.defaultBranch != null)
                  | [.id, .name, .webUrl, .defaultBranch] | @tsv' <<< "$repos_json")

  mkdir -p "$(dirname "$out")"
  {
    echo "# Generated by scripts/discover-repos.sh - do not edit. name|url|type|defaultBranch|azureName"
    sort -f "$tmp"
  } > "$tmp.final"

  if ! cmp -s "$tmp.final" "$out"; then
    mv "$tmp.final" "$out"
    changed_apps+=("$key")
    log "   updated $(basename "$out") ($(grep -vc '^#' "$out") repos)"
  else
    log "   no change ($(grep -vc '^#' "$out") repos)"
  fi
done <<< "$CATALOG_APPS"

# ---- commit & push -----------------------------------------------------------------------
if [ ${#changed_apps[@]} -eq 0 ]; then
  log "No changes."
  exit 0
fi

cd "$REPO_DIR"
git add .teamcity/repos
git -c user.name="teamcity-discovery" -c user.email="teamcity-discovery@noreply" \
  commit -q -m "discovery: update repos for ${changed_apps[*]}"
git --no-pager show --stat --oneline HEAD

if [ "${DRY_RUN:-0}" = "1" ]; then
  log "DRY_RUN=1 - not pushing"
  exit 0
fi

for attempt in 1 2 3; do
  if git_auth push -q origin "HEAD:$BRANCH"; then
    log "Pushed."
    exit 0
  fi
  log "Push rejected (attempt $attempt) - rebasing on latest $BRANCH"
  git_auth fetch -q --depth 50 origin "$BRANCH"
  git -c user.name="teamcity-discovery" -c user.email="teamcity-discovery@noreply" rebase -q FETCH_HEAD
done
echo "##teamcity[buildProblem description='Could not push repo list after 3 attempts']"
exit 1
