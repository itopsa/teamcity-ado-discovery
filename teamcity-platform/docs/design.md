# Design and rationale

Why `teamcity-platform` works the way it does. For setup and operations see the [README](../README.md); for the
developer-facing rules see [repo-contract.md](repo-contract.md).

## Goal

Jenkins-style auto-discovery (Organization Folders + Jenkinsfile) for TeamCity, with source in Azure DevOps.
A new application is onboarded with one reviewed line in `Catalog.kt`. Its repos are discovered without anyone
touching TeamCity.

## How it works

```
Catalog.kt (PR, human)                     ADO projects (repos + ci.yaml)
        │                                              │
        ▼                                              ▼
 Bootstrap Apps                              Discover Repos (every 30 min)
 creates <BU>/<App> project with             lists repos, classifies them,
 versioned settings on this repo,            writes .teamcity/repos/<bu>/<app>.txt,
 context parameter app=<bu>/<app>            commits + pushes to this repo
        │                                              │
        └──────────────────────┬───────────────────────┘
                               ▼
        TeamCity reloads the Kotlin DSL for each app project
                               │
                               ▼
   <BU>/<App>/Build/<type>/<repo>  ──app.zip──▶  Deploy/<ENV>/Deploy <repo>
```

Discovery happens at two levels:

1. **Applications**: curated by people in `Catalog.kt` and changed by PR. Bootstrap creates the TeamCity project.
2. **Repos**: scanned from the application's ADO project. No people involved.

One repository (this one) is attached to many TeamCity projects through versioned settings. The context parameter
`app` tells [`settings.kts`](../.teamcity/settings.kts) what to generate: `_platform`, one `<bu>/<app>`, or
everything (for validation). Each application compiles on its own, so a broken definition only breaks that
application.

## Patterns

| Pattern | Where it shows up |
|---|---|
| **Internal developer platform / golden path** | `Templates.kt` gives one opinionated, supported pipeline per app type. Teams get it for free by following the contract. |
| **Convention over configuration** | `FA-` / `WA-` prefixes and `ci.yaml` `type:` choose the template. There is no per-repo pipeline setup. |
| **Repo contract / pipeline as code** | Repos provide `ci.yaml` plus optional `ci/test.sh` and `ci/build.sh`. The platform owns everything else. It's a lighter Jenkinsfile. |
| **Auto-discovery (Organization Folders)** | *Discover Repos* scans the source control organization and creates jobs for repos that match the contract. |
| **Configuration as code, PR as control plane** | `Catalog.kt` and the DSL are versioned and reviewed. TeamCity is generated from them, and UI editing is off. |
| **Build once, deploy many** | One `app.zip` per build is promoted through environments. It is never rebuilt for each environment. |
| **Reconciliation loop, fail-static** | Discovery brings TeamCity in line with ADO. If ADO can't be reached, it keeps the last known state instead of deleting anything. |
| **Strangler fig** | New apps go on the platform. Legacy apps move a whole application at a time, and the legacy side is frozen for new apps. |

## Why one Function App per repo

**The repo is the unit of discovery.** Discovery writes one line per repo (`name|url|type|defaultBranch|azureName`),
and [`AppGenerator.kt`](../.teamcity/platform/AppGenerator.kt) turns each line into one build and one deploy per
environment. If one repo holds one deployable:

- A new repo needs nothing beyond `ci.yaml` to get pipelines.
- Classification is clear: one `type` per repo.
- Build once, deploy many stays simple: one `app.zip` goes to one Azure resource per environment.
- Triggers, PR builds, branch policies, rollback and blast radius are all per app. A change to one app never
  rebuilds another.

**It matches how Azure deploys Functions.** Microsoft's guidance says the function app is the unit of deployment:
every function in a function app is deployed together from one package. Functions that ship, scale and are secured
together belong in one function app; functions that need independent release or isolation belong in separate
ones. Microsoft does **not** say "one repo per function app". That part is our own decision, which follows from
treating the deployment unit and the discovery unit as the same thing.

**It matches Twelve-Factor.** Factor I describes a one-to-one relationship between a codebase and an app.

**What it costs:**
- more repos
- shared code has to be published as a versioned package
- a change that spans several apps takes several PRs

If several repos always have to change together, that's a sign they belong in one Function App: one repo with
several functions.

**Monorepo (several Function Apps in one repo)** is a legitimate pattern, but it needs tooling this platform doesn't
have yet:
- a list of apps in `ci.yaml` (`apps: [{name, path, azure_name}]`)
- one discovery row per app instead of per repo
- VCS trigger path filters so each app rebuilds only when its own folder changes
- an artifact and deploy per app

We'll add this only if a real team needs it.

## Key decisions

- **Catalog in Kotlin, not YAML.** It's compiled and type-checked with the rest of the DSL, and *Validate DSL*
  catches mistakes before merge.
- **The discovered repo list is committed to git, not fetched while the DSL is generated.** DSL generation stays
  deterministic and works offline. Every change to the list is an auditable commit. A broken ADO API can't break
  TeamCity.
- **Unknown or malformed rows are dropped,** both in discovery and in `Repos.kt`. A bad row can never stop an
  application from compiling.
- **Credentials per BU and environment.** There is one service principal per environment, set as password
  parameters on the BU project, so each application never holds its own credentials and environments stay isolated.
- **The deploy guard reads `build-info.txt`** written by the build, so protected environments reject builds from
  non-default branches even when someone starts the deploy by hand.

## Known limitations

- **Promotion order isn't enforced.** Each environment's deploy depends directly on the build, so a default-branch
  build can go straight to PROD. Today the only control is TeamCity roles on `Deploy / PROD`. Options: a
  dependency on the previous environment's deploy, or a build tag or status check.
- **Removed repos are deleted, not archived.** If a repo is deleted or disabled in ADO, or sets `enabled: false`,
  its configs disappear on the next run. Build history is then subject to TeamCity cleanup. The roadmap includes
  archiving with a grace period.
- **The packaging exclude list is fixed and `.funcignore` is ignored.** See
  [repo-contract.md](repo-contract.md#build-steps-in-detail).
- **Build steps run without a container image**, so repo scripts depend on the runtimes installed on the agent.
- **Templates aren't versioned yet.** A change to `Templates.kt` reaches every application at once. Roadmap:
  publish them as a Maven library so applications can pin a version.
- **Not yet run against a real server:** the DSL compile and the REST endpoints bootstrap uses. See the README's
  "Things to verify on your server".

## References

- Microsoft: [Azure Functions best practices](https://learn.microsoft.com/en-us/azure/azure-functions/functions-best-practices), the "Organize your functions" section
- Microsoft: [Deployment technologies in Azure Functions](https://learn.microsoft.com/en-us/azure/azure-functions/functions-deployment-technologies) (zip deploy, run from package)
- Microsoft: [Azure Functions deployment slots](https://learn.microsoft.com/en-us/azure/azure-functions/functions-deployment-slots)
- Microsoft: [Well-Architected Framework: Azure Functions](https://learn.microsoft.com/en-us/azure/well-architected/service-guides/azure-functions)
- [The Twelve-Factor App: I. Codebase](https://12factor.net/codebase)
- Martin Fowler: [Strangler Fig Application](https://martinfowler.com/bliki/StranglerFigApplication.html)
