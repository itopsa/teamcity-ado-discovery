package platform

import java.io.File

/** One discovered repository. Written by scripts/discover-repos.sh — never edited by hand. */
data class RepoSpec(
    val name: String,
    val url: String,
    val type: String,
    val branch: String,
    /** Azure resource base name; deployed as <azureName>-<env>. */
    val azureName: String,
) {
    val id: String get() = sanitize(name)
}

object Repos {
    /**
     * Reads .teamcity/repos/<bu>/<app>.txt  (name|url|type|defaultBranch|azureName).
     * A missing file means "no repos discovered yet", not an error.
     * Rows with an unknown template type are skipped so a bad row can never break the app's DSL.
     */
    fun load(baseDir: File, app: AppSpec): List<RepoSpec> {
        val file = File(baseDir, "repos/${app.key}.txt")
        if (!file.exists()) return emptyList()
        return file.readLines()
            .map { it.trim() }
            .filter { it.isNotEmpty() && !it.startsWith("#") }
            .mapNotNull { line ->
                val p = line.split("|").map { it.trim() }
                if (p.size < 5 || p.any { it.isEmpty() }) null
                else RepoSpec(name = p[0], url = p[1], type = p[2], branch = p[3], azureName = p[4])
            }
            .filter { Templates.isKnown(it.type) }
            .distinctBy { it.name }
            .sortedBy { it.name }
    }
}
