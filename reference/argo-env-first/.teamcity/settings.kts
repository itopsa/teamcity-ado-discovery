import jetbrains.buildServer.configs.kotlin.*
import jetbrains.buildServer.configs.kotlin.buildSteps.script
import jetbrains.buildServer.configs.kotlin.vcs.GitVcsRoot
import java.io.File

/*
 * Generates CREDIT / Argo / {ENV} / {Function|Web} Application / <app>-<ENV> / 5 configs
 * from apps.txt. Enable versioned settings (Kotlin) on the CREDIT / Argo project.
 * IDs must match the existing ones to preserve build history — adjust id(...) below.
 */

version = "2024.12"

val envs = listOf("DEV", "INT")              // add QA, UAT, PROD as needed

data class App(val name: String, val url: String) {
    val isFunction get() = name.startsWith("FA-")
    val idPart get() = name.replace(Regex("[^A-Za-z0-9]"), "_")
}

val apps = File(DslContext.baseDir, "apps.txt").readLines()
    .filter { it.isNotBlank() && !it.startsWith("#") }
    .map { it.split("|").let { (n, u) -> App(n.trim(), u.trim()) } }

project {
    envs.forEach { env -> subProject(envProject(env)) }
}

fun envProject(env: String) = Project {
    id("Argo_$env"); name = env

    val fa = Project { id("Argo_${env}_FunctionApplication"); name = "Function Application" }
    val wa = Project { id("Argo_${env}_WebApplication");      name = "Web Application" }
    val deploys = mutableListOf<BuildType>()

    apps.forEach { app ->
        val (p, deploy) = appProject(app, env)
        (if (app.isFunction) fa else wa).subProject(p)
        deploys += deploy
    }
    subProject(fa); subProject(wa)

    buildType(BuildType {
        id("Argo_${env}_BuildDeployAll")
        name = "Build-Deploy Individual and All Function and Web APPs"
        type = BuildTypeSettings.Type.COMPOSITE
        dependencies { deploys.forEach { snapshot(it) {} } }
    })
}

fun appProject(app: App, env: String): Pair<Project, BuildType> {
    val full = "${app.name}-$env"                    // FA-ADMIN-CF-ARGO-DEV
    val pid  = "Argo_${env}_${app.idPart}"

    val root = GitVcsRoot {
        id("${pid}_Root"); name = app.name
        url = app.url
        branch = "refs/heads/main"
        branchSpec = "+:refs/heads/*"
        authMethod = password { userName = "teamcity"; password = "%ado.pat%" }
    }

    fun step(n: String, cmd: String) = BuildType {
        id("${pid}_${n.replace(Regex("[^A-Za-z0-9]"), "_")}"); name = n
        vcs { root(root) }
        params { param("env.TARGET_ENV", env) }
        steps { script { scriptContent = cmd } }
    }

    val pkg    = step("Package_BuildParams",  "echo TODO: existing package step")
    val set    = step("Set_BuildParams",      "echo TODO: existing set-params step")
    val dwp    = step("Deploy_With_TCParams", "echo TODO: existing deploy-with-params step")
    val build  = step("${full}_Build",        "echo TODO: build").apply {
        artifactRules = "app.zip"
    }
    val deploy = step("${full}_Deploy",       "echo TODO: deploy").apply {
        dependencies { snapshot(build) {}; artifacts(build) { artifactRules = "app.zip" } }
    }

    val p = Project {
        id(pid); name = full
        vcsRoot(root)
        listOf(pkg, set, dwp, build, deploy).forEach { buildType(it) }
    }
    return p to deploy
}
