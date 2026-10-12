package platform

import jetbrains.buildServer.configs.kotlin.*
import jetbrains.buildServer.configs.kotlin.buildSteps.script

/*
 * Pipeline templates ("golden paths"). One per repo type.
 *
 * Every template:
 *   Build  -> runs ci/test.sh if present, then ci/build.sh if present (must produce app.zip),
 *             otherwise zips the repo. Always publishes app.zip + build-info.txt.
 *   Deploy -> guards protected envs, logs in with the env's service principal, zip-deploys app.zip.
 *
 * To add a type: implement AppTemplate, register it in Templates.all. Discovery picks it up
 * automatically (KNOWN_TYPES is generated from this map).
 */

interface AppTemplate {
    /** Group project name under <App> / Build. */
    val group: String
    fun deploySteps(bt: BuildType, repo: RepoSpec)
}

object Templates {
    private val all: Map<String, AppTemplate> = mapOf(
        "function-app" to FunctionAppTemplate,
        "web-app" to WebAppTemplate,
    )

    val knownTypes: Set<String> get() = all.keys
    fun isKnown(type: String): Boolean = type in all
    fun of(type: String): AppTemplate = all.getValue(type)

    /** Pin the Azure CLI image; bump deliberately. */
    const val AZ_CLI_IMAGE = "mcr.microsoft.com/azure-cli:2.64.0"

    /** Shared build steps (same for every type today). */
    fun buildSteps(bt: BuildType) {
        bt.steps {
            script {
                name = "Test"
                scriptContent = """
                    set -euo pipefail
                    if [ -x ci/test.sh ]; then
                      ci/test.sh
                    else
                      echo "No ci/test.sh - skipping tests"
                    fi
                """.trimIndent()
            }
            script {
                name = "Package"
                scriptContent = """
                    set -euo pipefail
                    rm -f app.zip
                    if [ -x ci/build.sh ]; then
                      ci/build.sh
                    else
                      zip -qr app.zip . -x '.git/*' '.teamcity/*' 'ci/*' 'tests/*' '.venv/*' 'node_modules/.cache/*' 'local.settings.json' 'ci.yaml'
                    fi
                    if [ ! -f app.zip ]; then
                      echo "##teamcity[buildProblem description='app.zip was not produced']"
                      exit 1
                    fi
                    {
                      echo "branch=%teamcity.build.branch%"
                      echo "is_default=%teamcity.build.branch.is_default%"
                      echo "commit=%build.vcs.number%"
                      echo "build=%build.number%"
                    } > build-info.txt
                """.trimIndent()
            }
        }
    }

    /** Rejects feature-branch builds in protected environments. */
    fun deployGuard(bt: BuildType, env: EnvSpec) {
        bt.steps {
            if (env.protected) {
                script {
                    name = "Guard: default branch only"
                    scriptContent = """
                        set -euo pipefail
                        cat build-info.txt
                        if ! grep -qx 'is_default=true' build-info.txt; then
                          echo "##teamcity[buildProblem description='${env.name} accepts default-branch builds only']"
                          exit 1
                        fi
                    """.trimIndent()
                }
            }
        }
    }

    /** Single line so it can be spliced into other scripts without breaking their indentation. */
    fun azLogin(): String =
        "az login --service-principal --output none -u \"\$AZURE_CLIENT_ID\" -p \"\$AZURE_CLIENT_SECRET\" --tenant \"\$AZURE_TENANT_ID\""
}

object FunctionAppTemplate : AppTemplate {
    override val group = "Function Application"

    override fun deploySteps(bt: BuildType, repo: RepoSpec) {
        bt.steps {
            script {
                name = "Deploy to Azure Functions"
                dockerImage = Templates.AZ_CLI_IMAGE
                scriptContent = """
                    set -euo pipefail
                    ${Templates.azLogin()}
                    # Python/Node packages are built on Azure; prebuilt packages (e.g. .NET) are deployed as-is.
                    REMOTE=false
                    if python3 -m zipfile -l app.zip | grep -qE '^(requirements\.txt|package\.json) '; then REMOTE=true; fi
                    az functionapp deployment source config-zip \
                      -g "${'$'}AZURE_RESOURCE_GROUP" -n "${'$'}AZURE_APP_NAME" \
                      --src app.zip --build-remote "${'$'}REMOTE"
                """.trimIndent()
            }
        }
    }
}

object WebAppTemplate : AppTemplate {
    override val group = "Web Application"

    override fun deploySteps(bt: BuildType, repo: RepoSpec) {
        bt.steps {
            script {
                name = "Deploy to App Service"
                dockerImage = Templates.AZ_CLI_IMAGE
                scriptContent = """
                    set -euo pipefail
                    ${Templates.azLogin()}
                    az webapp deploy \
                      -g "${'$'}AZURE_RESOURCE_GROUP" -n "${'$'}AZURE_APP_NAME" \
                      --src-path app.zip --type zip
                """.trimIndent()
            }
        }
    }
}
