# TeamCity auto-discovery for Azure DevOps

Goal: Jenkins-style auto-discovery and job creation (Organization Folders + Jenkinsfile) for TeamCity,
with source in **Azure DevOps**. Owner works in DevOps/platform engineering.

## Decision: strangler fig

- Existing hand-built TeamCity projects stay as **legacy**: CREDIT/Argo, CREDIT/Compass, CREDIT/CRD,
  CORPORATE/EDI, and others. They use an env-first layout (`<App>/<ENV>/{Function,Web} Application/<repo>-<ENV>/`
  with 5 configs each: Package_BuildParams, Set_BuildParams, Deploy_With_TCParams, _Build, _Deploy) and rebuild per env.
- **Net-new applications** go on the new system in `teamcity-platform/` (build once, deploy many).
- Existing apps move as a **whole application**, never repo by repo. New repos inside a legacy app are added the legacy way.
- Legacy is frozen for new apps (no create-subproject rights at BU level), labelled, and has a migration list with owners.

## Layout of this folder

- `teamcity-platform/` — **the new system** (see its README.md for the runbook)
  - `.teamcity/platform/Catalog.kt` — BU → app → ADO project, envs, prefix rules (human-edited via PR)
  - `.teamcity/platform/Templates.kt` — golden-path templates: function-app, web-app
  - `.teamcity/platform/AppGenerator.kt` — per-app tree: Build/<type>/<repo>, Deploy/<ENV>/Deploy <repo> + Deploy all
  - `.teamcity/platform/PlatformProject.kt` — _Platform jobs: Validate DSL, Bootstrap Apps, Discover Repos
  - `.teamcity/settings.kts` — context param `app`: `_platform` | `<bu>/<app>` | unset = generate all (validation)
  - `.teamcity/repos/<bu>/<app>.txt` — written by discovery: name|url|type|defaultBranch|azureName
  - `scripts/discover-repos.sh`, `scripts/bootstrap-apps.sh`
  - `tests/run-tests.sh` + `tests/mock_server.py` — 17 passing tests vs mock ADO/TeamCity + local git
  - `docs/repo-contract.md` (developer guide), `docs/design.md` (rationale, patterns, known limitations)
- `examples/hello-func/` — Python Azure Function using the repo contract (`ci.yaml`, `ci/test.sh`)
- `reference/` — earlier work: env-first Argo mirror generator and per-repo REST discovery (not used going forward)

## Key design points

- One repo, attached to many TeamCity projects via versioned settings + context parameter → per-app blast radius.
- Repo classification: `ci.yaml` `type:` first, then catalog name prefixes (FA- → function-app, WA- → web-app).
- Discovery keeps the existing list if the ADO API fails (never wipes an app on an outage).
- Deploys reuse the build's `app.zip`; protected envs reject non-default-branch builds via `build-info.txt`.
- Secrets: `ado.pat` at Root, `tc.token` on _Platform, `azure.tenant.id` / `azure.<env>.client.id|secret` on BU projects.

## Status / not yet verified

- Kotlin DSL has NOT been compiled yet (no Maven/JetBrains repo access where it was written).
  First step: `cd teamcity-platform/.teamcity && mvn -B teamcity-configs:generate`, then fix any API mismatches
  (likely spots: azureDevOps pullRequests/commitStatusPublisher auth blocks, schedule trigger fields,
  `DslContext.getParameter(name, default)`).
- Bootstrap's REST versioned-settings endpoints assume TeamCity 2023.05+; verify against the server's swagger.json.
- Placeholders to set: `adoOrg`, `platformRepoUrl` (Catalog.kt), TeamCity URL (pom.xml), `version` (settings.kts),
  pilot app's ADO project name.

## Open questions

- Actual ADO repo naming across BUs (prefix rules vs ci.yaml).
- Stacks of web apps (.NET? Node?) — may need `ci/build.sh` or new templates.
- Real environment list and per-env resource-group naming (`rg-{app}-{env}` assumed).
- What legacy Package_BuildParams / Set_BuildParams / Deploy_With_TCParams do (needed when migrating legacy apps).
- Next: publish templates as a versioned Maven library so apps can pin versions.
