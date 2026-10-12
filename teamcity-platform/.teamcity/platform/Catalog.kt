package platform

/*
 * THE CATALOG — the only file a human edits to onboard an application.
 *
 * Adding an AppSpec here and merging to main:
 *   1. triggers "Bootstrap Apps", which creates <BU> / <App> in TeamCity with versioned settings
 *      pointing at this repo (context parameter app=<bu>/<app>);
 *   2. the next "Discover Repos" run fills .teamcity/repos/<bu>/<app>.txt from the ADO project;
 *   3. TeamCity regenerates the app's Build / Deploy tree from that list.
 *
 * Legacy apps (Argo, Compass, CRD, EDI, ...) are NOT listed here until they are migrated.
 */

data class EnvSpec(
    val name: String,
    /** Deploy automatically after a successful default-branch build. */
    val autoDeploy: Boolean = false,
    /** Only default-branch builds may be deployed (feature-branch builds are rejected). */
    val protected: Boolean = true,
)

data class AppSpec(
    /** Business unit display name, e.g. "CREDIT". */
    val bu: String,
    /** Application display name, e.g. "Argo". */
    val name: String,
    /** Azure DevOps project that holds this application's repos. */
    val adoProject: String,
    /** ID of the BU project in TeamCity. Set this to the EXISTING legacy BU project ID so new apps sit beside legacy ones. */
    val buProjectId: String = sanitize(bu),
    val envs: List<EnvSpec> = Catalog.defaultEnvs,
    /** Fallback classification by repo-name prefix, used only when a repo has no ci.yaml. type -> prefix */
    val typePrefixes: Map<String, String> = Catalog.defaultTypePrefixes,
    /** Azure resource group per environment. {app} and {env} are replaced (lowercase). */
    val resourceGroup: String = "rg-{app}-{env}",
) {
    val key: String get() = "${bu.lowercase()}/${name.lowercase()}"
    val id: String get() = "${buProjectId}_${sanitize(name)}"
    fun resourceGroupFor(env: EnvSpec): String =
        resourceGroup.replace("{app}", name.lowercase()).replace("{env}", env.name.lowercase())
}

fun sanitize(s: String): String = s.replace(Regex("[^A-Za-z0-9_]"), "_")

object Catalog {
    /** Azure DevOps organization. */
    const val adoOrg = "myorg"

    /** This repository (where Catalog.kt lives). */
    const val platformRepoUrl = "https://dev.azure.com/myorg/Platform/_git/teamcity-platform"
    const val platformRepoBranch = "refs/heads/main"

    val defaultEnvs = listOf(
        EnvSpec("DEV", autoDeploy = true, protected = false),
        EnvSpec("INT"),
        EnvSpec("QA"),
        EnvSpec("PROD"),
    )

    val defaultTypePrefixes = mapOf(
        "function-app" to "FA-",
        "web-app" to "WA-",
    )

    val apps: List<AppSpec> = listOf(
        // Pilot application used to prove the platform end to end.
        AppSpec(
            bu = "CREDIT",
            name = "Pilot",
            adoProject = "PlatformPilot",
            envs = listOf(
                EnvSpec("DEV", autoDeploy = true, protected = false),
                EnvSpec("PROD"),
            ),
        ),

        // Examples:
        // AppSpec(bu = "CREDIT", name = "Pricing", adoProject = "Pricing"),
        // AppSpec(bu = "CORPORATE", name = "Payroll", adoProject = "Payroll", buProjectId = "CORPORATE"),
    )

    fun app(key: String): AppSpec =
        apps.firstOrNull { it.key == key }
            ?: error("App '$key' is not in Catalog.kt. Known apps: ${apps.joinToString { it.key }}")

    /**
     * Catalog serialised for the bootstrap and discovery scripts, one app per line:
     * key|buProjectId|bu|appId|appName|adoProject|type=prefix,type=prefix
     */
    fun toScriptFormat(): String = apps.joinToString("\n") { a ->
        listOf(
            a.key, a.buProjectId, a.bu, a.id, a.name, a.adoProject,
            a.typePrefixes.entries.joinToString(",") { "${it.key}=${it.value}" },
        ).joinToString("|")
    }
}
