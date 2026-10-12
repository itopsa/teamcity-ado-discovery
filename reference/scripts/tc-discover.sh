#!/usr/bin/env bash
# ALTERNATIVE approach: one TeamCity project per ADO repo that contains .teamcity/settings.kts,
# created via TeamCity REST under the "Discovered" parent project.
# Env: ADO_PAT, ADO_ORG, TC_TOKEN, TC_URL (e.g. https://teamcity.example.com)
set -euo pipefail
TC="${TC_URL}/app/rest"
TCAUTH="Authorization: Bearer ${TC_TOKEN}"
PARENT="Discovered"
ADOAUTH="Authorization: Basic $(printf ':%s' "$ADO_PAT" | base64 -w0)"
API="https://dev.azure.com/$ADO_ORG"

for proj in $(curl -sf -H "$ADOAUTH" "$API/_apis/projects?api-version=7.1" | jq -r '.value[].name'); do
  curl -sf -H "$ADOAUTH" "$API/$proj/_apis/git/repositories?api-version=7.1" |
  jq -r '.value[] | select(.isDisabled != true) | "\(.id) \(.name) \(.webUrl) \(.defaultBranch // "refs/heads/main")"' |
  while read -r rid name url defbranch; do
    curl -sf -o /dev/null -H "$ADOAUTH" \
      "$API/$proj/_apis/git/repositories/$rid/items?path=/.teamcity/settings.kts&api-version=7.1" || continue

    pid="${PARENT}_$(echo "${proj}_${name}" | tr -c 'A-Za-z0-9\n' '_')"
    curl -sf -H "$TCAUTH" "$TC/projects/id:$pid" >/dev/null && continue
    echo "Registering $proj/$name -> $pid"

    curl -sf -H "$TCAUTH" -H "Content-Type: application/json" -X POST "$TC/projects" \
      -d "{\"id\":\"$pid\",\"name\":\"$proj / $name\",\"parentProject\":{\"locator\":\"id:$PARENT\"}}"

    curl -sf -H "$TCAUTH" -H "Content-Type: application/json" -X POST "$TC/vcs-roots" -d @- <<EOF
{"id":"${pid}_Root","name":"$name","vcsName":"jetbrains.git","project":{"id":"$pid"},
 "properties":{"property":[
   {"name":"url","value":"$url"},
   {"name":"branch","value":"$defbranch"},
   {"name":"teamcity:branchSpec","value":"+:refs/heads/*"},
   {"name":"authMethod","value":"PASSWORD"},
   {"name":"username","value":"teamcity"},
   {"name":"secure:password","value":"%ado.pat%"}]}}
EOF

    curl -sf -H "$TCAUTH" -H "Content-Type: application/json" -X POST \
      "$TC/projects/id:$pid/projectFeatures" -d @- <<EOF
{"type":"versionedSettings","properties":{"property":[
  {"name":"enabled","value":"true"},
  {"name":"rootId","value":"${pid}_Root"},
  {"name":"format","value":"kotlin"},
  {"name":"buildSettings","value":"PREFER_VCS"},
  {"name":"useRelativeIds","value":"true"}]}}
EOF

    curl -sf -H "$TCAUTH" -X POST "$TC/projects/id:$pid/versionedSettings/loadSettings" || true
  done
done
