#!/usr/bin/env bash
# Repo Discovery job (central-generator approach).
# Scans ADO project for FA-*/WA-* repos, rewrites argo-ci/.teamcity/apps.txt, pushes if changed.
# Env: ADO_PAT (Code: Read + Write on argo-ci), ADO_ORG, ADO_PROJECT (default Argo)
set -euo pipefail
ADO_PROJECT="${ADO_PROJECT:-Argo}"
API="https://dev.azure.com/$ADO_ORG"
ADOAUTH="Authorization: Basic $(printf ':%s' "$ADO_PAT" | base64 -w0)"

rm -rf argo-ci
git clone -q "https://teamcity:${ADO_PAT}@dev.azure.com/$ADO_ORG/$ADO_PROJECT/_git/argo-ci" argo-ci

{
  echo "# name|url  (maintained by scripts/update-apps.sh — do not edit by hand)"
  curl -sf -H "$ADOAUTH" "$API/$ADO_PROJECT/_apis/git/repositories?api-version=7.1" |
    jq -r '.value[] | select(.isDisabled != true)
           | select(.name|test("^(FA|WA)-")) | "\(.name)|\(.webUrl)"' | sort
} > argo-ci/.teamcity/apps.txt

cd argo-ci
if git diff --quiet; then
  echo "No app changes."
else
  git -c user.name="teamcity-discovery" -c user.email="teamcity@noreply" \
    commit -qam "discovery: update app list"
  git push -q
  echo "apps.txt updated:"; git show --stat HEAD | tail -n +6
fi
