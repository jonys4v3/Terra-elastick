// jenkins/shared-libs/vars/github.groovy

/**
 * Crea un Pull Request en GitHub vía API REST.
 * Devuelve la URL del PR creado.
 */
def createPullRequest(Map args) {
    def token     = args.token
    def branch    = args.branch
    def base      = args.base      ?: 'main'
    def title     = args.title
    def body      = args.body      ?: ''
    def reviewers = args.reviewers ?: []
    def labels    = args.labels    ?: []

    def repoSlug = env.GIT_URL
        .replaceAll('git@github\\.com:', '')
        .replaceAll('\\.git$', '')

    def payload = groovy.json.JsonOutput.toJson([
        title: title,
        body: body,
        head: branch,
        base: base,
        draft: false
    ])

    def response = sh(
        script: """
            curl -s -X POST \
                -H "Authorization: token ${token}" \
                -H "Content-Type: application/json" \
                -d '${payload}' \
                "https://api.github.com/repos/${repoSlug}/pulls"
        """,
        returnStdout: true
    ).trim()

    def prData = readJSON text: response
    def prNumber = prData.number
    def prUrl    = prData.html_url

    if (!prNumber) {
        error("❌ No se pudo crear el PR. Respuesta: ${response}")
    }

    // Añadir reviewers
    if (reviewers) {
        def reviewPayload = groovy.json.JsonOutput.toJson([team_reviewers: reviewers])
        sh """
            curl -s -X POST \
                -H "Authorization: token ${token}" \
                -H "Content-Type: application/json" \
                -d '${reviewPayload}' \
                "https://api.github.com/repos/${repoSlug}/pulls/${prNumber}/requested_reviewers"
        """
    }

    // Añadir labels
    if (labels) {
        def labelPayload = groovy.json.JsonOutput.toJson([labels: labels])
        sh """
            curl -s -X POST \
                -H "Authorization: token ${token}" \
                -H "Content-Type: application/json" \
                -d '${labelPayload}' \
                "https://api.github.com/repos/${repoSlug}/issues/${prNumber}/labels"
        """
    }

    echo "✅ PR #${prNumber} creado: ${prUrl}"
    return prUrl
}

/**
 * Obtiene el resumen de cambios del último commit.
 */
def getChangesSummary() {
    def changes = sh(
        script: "git log -1 --pretty=format:'%h %s' HEAD",
        returnStdout: true
    ).trim()
    return changes ?: 'Sin cambios detectados'
}
