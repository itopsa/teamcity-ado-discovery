#!/usr/bin/env bash
# Runs discover-repos.sh and bootstrap-apps.sh against a local mock of ADO + TeamCity
# and a local bare git repo. Needs: bash, curl, jq, git, python3.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
T="$(mktemp -d)"
PORT="${PORT:-18765}"
export NO_PROXY="127.0.0.1,localhost" no_proxy="127.0.0.1,localhost"
pass=0; fail=0
check() { if eval "$2"; then echo "  PASS $1"; pass=$((pass+1)); else echo "  FAIL $1"; fail=$((fail+1)); fi; }

python3 "$HERE/mock_server.py" "$PORT" "$T/calls.log" &
MOCK=$!
trap 'kill $MOCK 2>/dev/null; rm -rf "$T"' EXIT
for _ in $(seq 50); do curl -s "http://127.0.0.1:$PORT/app/rest/swagger.json" >/dev/null && break; sleep 0.1; done

# platform repo as a local bare repo
git init -q --bare -b main "$T/platform.git"
git clone -q "$T/platform.git" "$T/seed" 2>/dev/null
mkdir -p "$T/seed/.teamcity/repos" && echo seed > "$T/seed/.teamcity/repos/README.md"
git -C "$T/seed" add . && git -C "$T/seed" -c user.name=t -c user.email=t@t commit -qm seed && git -C "$T/seed" push -q origin main

export ADO_ORG=myorg ADO_PAT=dummy KNOWN_TYPES="function-app web-app"
export ADO_API_BASE="http://127.0.0.1:$PORT/myorg"
export PLATFORM_REPO_URL="$T/platform.git" PLATFORM_REPO_BRANCH=refs/heads/main
export CATALOG_APPS=$'credit/pilot|CREDIT|CREDIT|CREDIT_Pilot|Pilot|PlatformPilot|function-app=FA-,web-app=WA-\ncorporate/ghost|CORPORATE|CORPORATE|CORPORATE_Ghost|Ghost|NoSuchProject|function-app=FA-'

echo "== discover-repos.sh (first run)"
bash "$ROOT/scripts/discover-repos.sh" > "$T/d1.log" 2>&1 || { cat "$T/d1.log"; exit 1; }
git clone -q "$T/platform.git" "$T/check1"
F="$T/check1/.teamcity/repos/credit/pilot.txt"
check "pilot repo list was pushed"            "[ -f '$F' ]"
check "3 repos discovered"                    "[ \$(grep -vc '^#' '$F') -eq 3 ]"
check "FA- prefix -> function-app"            "grep -qx 'FA-HELLO|https://dev.azure.com/myorg/PlatformPilot/_git/FA-HELLO|function-app|refs/heads/main|fa-hello' '$F'"
check "WA- prefix -> web-app, master branch"  "grep -qx 'WA-PORTAL|https://dev.azure.com/myorg/PlatformPilot/_git/WA-PORTAL|web-app|refs/heads/master|wa-portal' '$F'"
check "ci.yaml type + azure_name win"          "grep -qx 'pricing-engine|https://dev.azure.com/myorg/PlatformPilot/_git/pricing-engine|function-app|refs/heads/main|func-pricing' '$F'"
check "disabled / opted-out / unmatched skipped" "! grep -qE '^(FA-OLD|FA-OPTOUT|docs|empty-repo)\\|' '$F'"
check "unknown type warned and skipped"       "grep -qF \"unknown type |'logic-app|'\" '$T/d1.log' && ! grep -q '^weird|' '$F'"
check "missing ADO project warned, no file"   "grep -q 'NoSuchProject' '$T/d1.log' && [ ! -f '$T/check1/.teamcity/repos/corporate/ghost.txt' ]"

echo "== discover-repos.sh (second run, nothing changed)"
bash "$ROOT/scripts/discover-repos.sh" > "$T/d2.log" 2>&1 || { cat "$T/d2.log"; exit 1; }
check "idempotent: no new commit"             "grep -q 'No changes.' '$T/d2.log' && [ \$(git -C '$T/platform.git' rev-list --count main) -eq 2 ]"

echo "== bootstrap-apps.sh"
export TC_URL="http://127.0.0.1:$PORT" TC_TOKEN=dummy
: > "$T/calls.log"
bash "$ROOT/scripts/bootstrap-apps.sh" > "$T/b1.log" 2>&1 || { cat "$T/b1.log"; exit 1; }
check "existing BU CREDIT not recreated"      "! grep -q '\"id\":\"CREDIT\",' '$T/calls.log'"
check "missing BU CORPORATE created"          "grep -q 'POST /app/rest/projects {\"id\":\"CORPORATE\"' '$T/calls.log'"
check "app project created under BU"          "grep -q '\"id\":\"CREDIT_Pilot\",\"name\":\"Pilot\",\"parentProject\":{\"locator\":\"id:CREDIT\"}' '$T/calls.log'"
check "settings VCS root created"             "grep -q 'POST /app/rest/vcs-roots .*CREDIT_Pilot_PlatformSettings' '$T/calls.log'"
check "versioned settings: kotlin from VCS"   "grep -q 'PUT /app/rest/projects/id:CREDIT_Pilot/versionedSettings/config .*\"format\":\"kotlin\".*\"buildSettingsMode\":\"useFromVCS\"' '$T/calls.log'"
check "context param app=credit/pilot"        "grep -q 'contextParameters {\"parameter\":\\[{\"name\":\"app\",\"value\":\"credit/pilot\"}\\]}' '$T/calls.log'"
check "settings loaded"                       "grep -q 'POST /app/rest/projects/id:CREDIT_Pilot/versionedSettings/loadSettings' '$T/calls.log'"

: > "$T/calls.log"
bash "$ROOT/scripts/bootstrap-apps.sh" > "$T/b2.log" 2>&1
check "idempotent: second run writes nothing" "! grep -qE '^(POST|PUT) ' '$T/calls.log'"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
