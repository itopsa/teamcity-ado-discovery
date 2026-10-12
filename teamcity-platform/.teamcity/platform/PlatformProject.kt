package platform

import jetbrains.buildServer.configs.kotlin.*
import jetbrains.buildServer.configs.kotlin.buildFeatures.commitStatusPublisher
import jetbrains.buildServer.configs.kotlin.buildFeatures.pullRequests
import jetbrains.buildServer.configs.kotlin.buildSteps.script
import jetbrains.buildServer.configs.kotlin.triggers.schedule
import jetbrains.buildServer.configs.kotlin.triggers.vcs

/*
 * The _Platform project (context parameter app=_platform). Three jobs:
 *
 *   Validate DSL    every branch + PR of this repo: compiles the DSL for ALL apps. Make it a required
 *                   check (ADO branch policy) so a broken template never reaches main.
 *   Bootstrap Apps  on Catalog.kt changes in main: creates missing <BU> / <App> projects in TeamCity.
 *   Discover Repos  every 30 min: refreshes .teamcity/repos/** from Azure DevOps and pushes.
 *
 * Secrets expected on the _Platform project (password parameters, set once in the UI):
 *   ado.pat    ADO PAT: Code (Read & Write), Code (Status), Project and Team (Read), Pull Request Threads (Read)
 *   tc.token   TeamCity access token of a service user with Project administrator on the BU projects
 */
object PlatformProject {

    fun apply(root: Project, idp: String) {
        root.description = "teamcity-platform: catalog bootstrap, repo discovery, DSL validation. Restricted to the platform team."

        val catalogEnv: ParametrizedWithType.() -> Unit = {
            param("env.CATALOG_APPS", Catalog.toScriptFormat())
            param("env.KNOWN_TYPES", Templates.knownTypes.joinToString(" "))
            param("env.ADO_ORG", Catalog.adoOrg)
            param("env.PLATFORM_REPO_URL", Catalog.platformRepoUrl)
            param("env.PLATFORM_REPO_BRANCH", Catalog.platformRepoBranch)
            param("env.ADO_PAT", "%ado.pat%")
        }

        root.buildType(BuildType {
            id("${idp}ValidateDsl")
            name = "Validate DSL"
            description = "Compiles the Kotlin DSL for every app in the catalog"

            vcs { root(DslContext.settingsRoot) }

            steps {
                script {
                    name = "Generate all apps"
                    workingDir = ".teamcity"
                    dockerImage = "maven:3.9-eclipse-temurin-17"
                    scriptContent = "mvn -B -q teamcity-configs:generate && echo 'DSL OK for all apps'"
                }
            }

            triggers { vcs { branchFilter = "+:*" } }

            features {
                pullRequests {
                    vcsRootExtId = "${DslContext.settingsRoot.id}"
                    provider = azureDevOps {
                        authType = token { token = "%ado.pat%" }
                        filterTargetBranch = "+:<default>"
                    }
                }
                commitStatusPublisher {
                    vcsRootExtId = "${DslContext.settingsRoot.id}"
                    publisher = vsts {
                        authType = personalToken { token = "%ado.pat%" }
                    }
                }
            }
        })

        root.buildType(BuildType {
            id("${idp}BootstrapApps")
            name = "Bootstrap Apps"
            description = "Creates missing BU / App projects with versioned settings (app=<bu>/<app>)"
            maxRunningBuilds = 1

            vcs { root(DslContext.settingsRoot) }
            params {
                catalogEnv()
                param("env.TC_URL", "%teamcity.serverUrl%")
                param("env.TC_TOKEN", "%tc.token%")
            }
            steps {
                script {
                    name = "Bootstrap"
                    scriptContent = "bash scripts/bootstrap-apps.sh"
                }
            }
            triggers {
                vcs {
                    branchFilter = "+:<default>"
                    triggerRules = "+:.teamcity/platform/Catalog.kt"
                }
            }
            requirements { equals("teamcity.agent.jvm.os.name", "Linux") }
        })

        root.buildType(BuildType {
            id("${idp}DiscoverRepos")
            name = "Discover Repos"
            description = "Scans each catalog app's ADO project and updates .teamcity/repos/**"
            maxRunningBuilds = 1

            vcs { root(DslContext.settingsRoot) }
            params { catalogEnv() }
            steps {
                script {
                    name = "Discover"
                    scriptContent = "bash scripts/discover-repos.sh"
                }
            }
            triggers {
                schedule {
                    schedulingPolicy = cron {
                        minutes = "0/30"
                    }
                    branchFilter = "+:<default>"
                    triggerBuild = always()
                    withPendingChangesOnly = false
                }
            }
            requirements { equals("teamcity.agent.jvm.os.name", "Linux") }
        })
    }
}
