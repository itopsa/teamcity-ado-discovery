# Repo contract: how to structure an app repo

For developers who own a Function App or Web App repo in Azure DevOps. If your repo follows this contract,
TeamCity creates its build and deploy pipelines automatically. There is nothing to request and nothing to click.

Worked example: [`examples/hello-func`](../../examples/hello-func).

## The rules

1. **One repo = one deployable.** A repo holds exactly one Function App (or one Web App). Add more functions
   *inside* that Function App; put a separate Function App in its own repo. See [design.md](design.md#why-one-function-app-per-repo).
2. **The app lives at the repo root.** For Function Apps, `host.json` is at the top level, not in a subfolder.
   Without `ci/build.sh`, the platform zips the repo root and deploys that zip as-is.
3. **Declare yourself in `ci.yaml`** at the repo root. The `FA-` / `WA-` name prefix also works, but `ci.yaml` is
   explicit and wins over the prefix.
4. **No secrets in the repo.** `local.settings.json` is gitignored. Environment settings live on the Azure resource
   (or Key Vault references), not in code.
5. **Code shared between apps goes in a versioned package** (Azure Artifacts feed), not in copied folders.

## Layout

```
FA-orders/                  # one repo = one Function App
├── ci.yaml                 # type + azure_name (see below)
├── ci/
│   ├── test.sh             # optional: runs before packaging; non-zero exit fails the build
│   └── build.sh            # optional: must produce app.zip (required for compiled stacks)
├── host.json               # Function App root
├── function_app.py         # Python v2 model: functions / blueprints registered here
├── orders/                 # feature modules or blueprints
├── shared/                 # code shared by THIS app's functions only
├── requirements.txt        # Python dependencies (triggers a remote build on deploy)
├── tests/                  # unit tests (never packaged)
├── local.settings.json     # gitignored
└── .gitignore
```

## `ci.yaml`

```yaml
type: function-app        # function-app | web-app
azure_name: func-orders   # Azure resource is <azure_name>-<env>: func-orders-dev, func-orders-prod, ...
# enabled: false          # uncomment to take this repo off the platform
```

| Key | Required | Default | Notes |
|---|---|---|---|
| `type` | No* | name prefix (`FA-` → `function-app`, `WA-` → `web-app`) | *A repo with neither a `type` nor a matching prefix is ignored. An unknown type is skipped with a warning in the *Discover Repos* build log. |
| `azure_name` | No | repo name | Lowercased; any run of characters other than `a-z 0-9 -` becomes `-`. |
| `enabled` | No | `true` | `false` removes the repo's build and deploy configs on the next discovery run. |

The parser is deliberately simple: top-level `key: value` lines only, with quotes and trailing `# comments`
stripped. No nesting, anchors or multi-line values.

## How your repo is discovered

- *Discover Repos* runs **every 30 minutes**. A new repo, or a `ci.yaml` change, shows up in TeamCity within about
  30 minutes. The platform team can run the job by hand if you need it sooner.
- `ci.yaml` is read from the repo's **default branch only**. Changing it on a feature branch has no effect until the
  change is merged.
- Repos that are **disabled** in ADO, or **empty** (no default branch yet), are skipped.
- The repo must be in the ADO project registered for your application in `Catalog.kt`. Repos in other projects are
  not scanned.
- If ADO can't be reached, discovery keeps the previous list. An outage never removes your pipelines.

## What you get in TeamCity

```
<BU> / <App>
├── Build / Function Application / <repo>     every branch + PRs into the default branch
└── Deploy / <ENV> / Deploy <repo>            one per environment, plus "Deploy all"
```

- **Build** runs on every branch and on PRs that target the default branch. It reports status back to ADO, so it
  can be a required check in your branch policy.
- **Deploy** reuses the `app.zip` from a build. It never rebuilds.
  - DEV deploys automatically after every successful default-branch build.
  - Protected environments (INT, QA and PROD by default) reject builds from any branch other than the default branch.
  - Target: Function App `<azure_name>-<env>` in resource group `rg-<app>-<env>` (where `<app>` is the catalog
    application name, lowercased).

> **Promotion order is not enforced yet.** Any successful default-branch build can be deployed to any environment,
> including PROD, without passing DEV first. Control who can run PROD deploys with TeamCity roles.

## Build steps in detail

Both steps run on a Linux build agent, from the repo root, in a clean checkout.

1. **Test**: runs `ci/test.sh` if it exists **and is executable**. Otherwise the step is skipped.
2. **Package**: runs `ci/build.sh` if it exists and is executable. It must leave `app.zip` in the repo root.
   Without `ci/build.sh`, the platform zips the repo root, excluding only:

   ```
   .git/  .teamcity/  ci/  tests/  .venv/  node_modules/.cache/  local.settings.json  ci.yaml
   ```

   Everything else is packaged, **including `README.md`, `docs/`, `infra/`, `.github/` and `.vscode/`**.
   `.funcignore` is **not** honoured. If that matters, write a `ci/build.sh` that zips only what you need.
3. The build also writes `build-info.txt` (branch, whether it is the default branch, commit, build number). The
   deploy guard reads it.

**Executable bit:** the scripts must be committed as executable. From Windows, run
`git update-index --chmod=+x ci/test.sh ci/build.sh`.

**Tools:** `ci/test.sh` and `ci/build.sh` run directly on the agent, not in a container, so they can only use the
runtimes installed there. Agree on the Python, Node and .NET versions with the platform team, or run your
commands inside `docker run` from the script.

## Per stack

### Python (v2 programming model)

No `ci/build.sh` is needed. The deploy step sees `requirements.txt` in the zip and asks Azure to build remotely,
which installs the dependencies on the Linux runtime.

```bash
#!/usr/bin/env bash
# ci/test.sh
set -euo pipefail
python3 -m venv .venv && . .venv/bin/activate
pip install -q -r requirements.txt pytest
pytest -q tests
```

### Node.js

Plain JavaScript works without `ci/build.sh`. Azure runs a remote build because `package.json` is in the zip.

TypeScript needs a build:

```bash
#!/usr/bin/env bash
# ci/build.sh
set -euo pipefail
npm ci
npm run build
npm prune --omit=dev
zip -qr app.zip host.json package.json dist node_modules
```

> The deploy step requests a remote build whenever `package.json` is in the zip, so Azure runs `npm install`
> again on top of your packaged `node_modules`. That works, but it is slower.

### .NET (isolated worker)

`ci/build.sh` is always required, because the platform deploys the published output, not the source.

```bash
#!/usr/bin/env bash
# ci/build.sh
set -euo pipefail
dotnet publish -c Release -o out
(cd out && zip -qr ../app.zip .)
```

No `requirements.txt` or `package.json` ends up in the zip, so the package is deployed as-is with no remote build.

## Checklist for a new repo

- [ ] Created in the application's ADO project
- [ ] `ci.yaml` with `type` and `azure_name` (or an `FA-` / `WA-` name)
- [ ] `host.json` at the repo root
- [ ] `local.settings.json` in `.gitignore`
- [ ] `ci/test.sh` (recommended), committed as executable
- [ ] `ci/build.sh` if the stack is compiled (.NET, TypeScript)
- [ ] Azure resources `<azure_name>-<env>` exist in `rg-<app>-<env>` for each environment (the platform deploys
      to them; it does not create them)
- [ ] ADO branch policy on the default branch requires the TeamCity build status
