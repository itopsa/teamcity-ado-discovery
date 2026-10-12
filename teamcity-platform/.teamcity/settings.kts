import jetbrains.buildServer.configs.kotlin.*
import platform.*

/*
 * teamcity-platform entry point.
 *
 * The SAME repo is attached (versioned settings, Kotlin) to several TeamCity projects.
 * Each attachment sets the context parameter "app", which decides what this script generates:
 *
 *   app=_platform       -> the _Platform project (Validate DSL, Bootstrap Apps, Discover Repos)
 *   app=<bu>/<app>      -> one application from Catalog.kt, e.g. credit/pilot
 *   (not set)           -> everything side by side: used by `mvn teamcity-configs:generate`
 *                          locally and by the Validate DSL job
 *
 * Because each app compiles separately, a broken app definition only breaks that app.
 */

version = "2024.12"

val appKey = DslContext.getParameter("app", "__all__")

project {
    when (appKey) {
        "_platform" -> PlatformProject.apply(this, idp = "")

        "__all__" -> {
            subProject(Project {
                id("Platform")
                name = "_Platform"
                PlatformProject.apply(this, idp = "Platform_")
            })
            Catalog.apps.forEach { app ->
                subProject(Project {
                    id(app.id)
                    name = "${app.bu} / ${app.name}"
                    AppGenerator.apply(this, app, DslContext.baseDir, idp = "${app.id}_")
                })
            }
        }

        else -> AppGenerator.apply(this, Catalog.app(appKey), DslContext.baseDir, idp = "")
    }
}
