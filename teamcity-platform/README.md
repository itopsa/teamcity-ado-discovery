# teamcity-platform

Auto-discovery and generated pipelines for TeamCity, with source code in Azure DevOps.
This is the **new system** for net-new applications. Existing hand-built projects (Argo, Compass, CRD, EDI, ...)
stay as legacy and are migrated one application at a time (strangler fig).

```
Catalog.kt (reviewed PR)          ADO repos (FA-*, WA-*, or ci.yaml)
        │                                     │
  Bootstrap Apps ──creates──▶ <BU> / <App>    Discover Repos ──writes──▶ .teamcity/repos/<bu>/<app>.txt
                              (versioned settings,                               │
                               context param app=<bu>/<app>)                     ▼
                                        └──────────────────────────▶ TeamCity regenerates <App>:
                                                                      Build / <type> / <repo>
                                                                      Deploy / <ENV> / Deploy <repo>
```

## Repository layout

| Path | What | Edited by |
|---|---|---|
| `.teamcity/platform/Catalog.kt` | Business units, apps, ADO projects, environments | **Humans, via PR** |
| `.teamcity/platform/Templates.kt` | Golden-path pipelines per repo type | Platform team, via PR |
| `.teamcity/platform/AppGenerator.kt` | Build/Deploy tree for one app | Platform team, via PR |
| `.teamcity/platform/PlatformProject.kt` | Validate DSL / Bootstrap Apps / Discover Repos jobs | Platform team, via PR |
| `.teamcity/settings.kts` | Entry point; picks what to generate from the `app` context parameter | Rarely |
| `.teamcity/repos/**` | Discovered repos per app | **Discover Repos bot only** |
| `scripts/` | Bootstrap and discovery scripts run by the jobs | Platform team |
| `tests/run-tests.sh` | Tests both scripts against a mock ADO/TeamCity and a local git repo | — |

## Generated structure (per app)

```
CREDIT                          existing BU project (legacy apps live here too)
└── Pilot                       generated - do not edit in the UI
    ├── Build
    │   ├── Function Application
    │   │   └── FA-HELLO        every branch + PR; publishes app.zip + build-info.txt
    │   └── Web Application
    │       └── WA-PORTAL
    └── Deploy
        ├── DEV                 auto-deploys successful default-branch builds
        │   ├── Deploy all
        │   └── Deploy FA-HELLO
        └── PROD                default-branch builds only
```

Each deploy pulls the **same `app.zip`** the build produced (build once, deploy many). Deploy configs are
TeamCity *deployment* configs, so the Deployments view shows what is running in each environment.

> **Promotion order is not enforced yet.** Any successful default-branch build can be deployed to any environment,
> including PROD, without passing DEV first. Restrict who can run PROD deploys with TeamCity roles (see *Day-to-day*).

## Docs

- [docs/overview.md](docs/overview.md): one-page overview with a flow diagram. Start here.
- [docs/repo-contract.md](docs/repo-contract.md): for app developers. How to structure a repo, per-stack examples, what gets packaged.
- [docs/design.md](docs/design.md): rationale, patterns, why one Function App per repo, known limitations, references.

## Repo contract (`ci.yaml`, optional)

```yaml
type: function-app        # function-app | web-app   (else: name prefix FA- / WA- from the catalog)
azure_name: func-hello    # Azure resource is <azure_name>-<env>, e.g. func-hello-dev (default: repo name, lowercased)
enabled: false            # opt out of the platform
```

Optional hooks, run on the build agent from the repo root:

- `ci/test.sh` runs before packaging. Exit non-zero to fail the build.
- `ci/build.sh` must produce `app.zip`. Without it, the repo is zipped as-is, which is right for Python/Node Functions.

Full details, including what gets packaged and examples for each stack, are in [docs/repo-contract.md](docs/repo-contract.md).

## One-time setup

1. **Create the repo** `teamcity-platform` in ADO and push this folder. Set its URL in `Catalog.kt`
   (`platformRepoUrl`), the ADO org (`adoOrg`), the TeamCity URL in `.teamcity/pom.xml`, and `version` in
   `settings.kts` to your server version.
2. **Service identities**
   - ADO PAT on a service account with these scopes: Code (Read & Write), Code (Status), Project and Team (Read), Pull Request Threads (Read).
   - TeamCity service user `svc-platform` with *Project administrator* on the BU projects. Generate an access token for it.
3. **Shared parameter at `<Root>`**: `ado.pat` (password). `_Platform` and every generated app inherit it.
4. **Create `_Platform` by hand, once**, under `<Root>`, and restrict it to the platform team.
   - Password parameter: `tc.token`.
   - VCS root → `teamcity-platform`, authenticated with `%ado.pat%`.
   - Versioned Settings: Kotlin, *use settings from VCS*, **context parameter `app` = `_platform`**.
   - Load the settings. The three jobs appear.
5. **Azure credentials on each BU project**, as password parameters: `azure.tenant.id`,
   `azure.<env>.client.id`, `azure.<env>.client.secret` for each environment (`dev`, `int`, `qa`, `prod`).
   Use one service principal per environment, each scoped to that environment's resource groups.
6. **Branch policy in ADO on `teamcity-platform/main`.** Require a PR plus the *Validate DSL* status. Exempt the
   discovery service account so its commits to `.teamcity/repos/**` can push directly.
7. **Run `Validate DSL`, then `Bootstrap Apps`.** `CREDIT / Pilot` appears. Run `Discover Repos`, and its
   Build/Deploy tree fills in.

## Day-to-day

| I want to... | Do this |
|---|---|
| Onboard a new application | PR adding an `AppSpec` to `Catalog.kt`. After merge: Bootstrap → Discover → done. |
| Add a repo to an app | Create it in the app's ADO project with an `FA-`/`WA-` name or a `ci.yaml`. It appears within 30 min. |
| Remove a repo | Disable/delete it in ADO, or set `enabled: false`. Its configs disappear on the next discovery run. |
| Change how every Function App deploys | PR to `Templates.kt`. *Validate DSL* compiles every app before merge. |
| Add a new repo type | Implement `AppTemplate`, register it in `Templates.all`. Discovery picks up the new type automatically. |
| Restrict PROD | Assign TeamCity roles on `<App> / Deploy / PROD` to your release group only. |

## Legacy guard rails

- Remove *create subproject* rights at BU level for everyone but the platform team, so no new hand-built apps get added.
- Add "Legacy, manually managed. Migration: <owner>/<quarter>" to each legacy app project's description.
- Keep a list of legacy apps with owners and a target window. Migrate one app at a time, then archive (not delete) its old projects.

## Testing

```bash
bash tests/run-tests.sh                       # scripts vs. mock ADO + TeamCity (bash, curl, jq, git, python3)
cd .teamcity && mvn -B teamcity-configs:generate   # compiles the DSL for ALL apps (what Validate DSL runs)
```

## Things to verify on your server

These were written against TeamCity 2024.x docs but not yet run against a live server:

- **Bootstrap REST endpoints**: `versionedSettings/config` and `versionedSettings/contextParameters` (2023.05+). The script checks
  `swagger.json` first and stops with a clear message if they're missing. If your field names differ, configure
  one project by hand, `GET /app/rest/projects/id:<X>/versionedSettings/config`, and copy the shape.
- **DSL compile**: the first `mvn teamcity-configs:generate` will flag any API differences in your server's DSL
  version, typically in the Azure DevOps `pullRequests` / `commitStatusPublisher` blocks.
- **Agents**: Linux with `bash curl jq git zip`, plus Docker for the `azure-cli` and `maven` step images.
  *Validate DSL* also needs agent access to `download.jetbrains.com` and Maven Central (or an internal mirror such as an ADO Artifacts upstream feed).

## Roadmap

1. Publish `platform/*.kt` as a versioned Maven library in ADO Artifacts, so apps can pin a template version and changes roll out gradually.
2. Archive (rather than drop) configs for repos that disappear, with a grace period.
3. More repo types (Logic Apps, containers) as legacy apps migrate.
