// jenkins/shared-libs/vars/notifications.groovy

/**
 * Envía mensaje a Slack.
 */
def slack(Map args) {
    def status  = args.status  ?: 'INFO'
    def message = args.message ?: ''
    def channel = args.channel ?: '#ci-cd-alerts'

    def colorMap = [
        'SUCCESS' : '#36a64f',
        'FAILURE' : '#ff0000',
        'WAITING' : '#f0a500',
        'INFO'    : '#439fe0'
    ]

    def emoji = [
        'SUCCESS' : '✅',
        'FAILURE' : '❌',
        'WAITING' : '⏳',
        'INFO'    : 'ℹ️'
    ]

    slackSend(
        channel: channel,
        color: colorMap[status] ?: '#439fe0',
        message: "${emoji[status] ?: 'ℹ️'} *Jenkins* | ${message}\n_Build: <${BUILD_URL}|#${BUILD_NUMBER}>_"
    )
}

/**
 * Publica un comentario en el PR de GitHub.
 */
def prComment(Map args) {
    def token   = args.token
    def message = args.message ?: ''
    def prNumber = env.CHANGE_ID

    if (!prNumber) {
        echo "⚠️ No estamos en un PR — omitiendo comentario"
        return
    }

    def repoSlug = env.GIT_URL
        .replaceAll('git@github\\.com:', '')
        .replaceAll('\\.git$', '')

    sh """
        curl -s -X POST \
            -H "Authorization: token ${token}" \
            -H "Content-Type: application/json" \
            -d '{"body": ${groovy.json.JsonOutput.toJson(message)}}' \
            "https://api.github.com/repos/${repoSlug}/issues/${prNumber}/comments"
    """
}

/**
 * Formatea el output de terraform plan para mostrarlo en el PR.
 */
def formatPlan(Map args) {
    def env  = args.env
    def plan = args.plan ?: ''
    def maxLen = 50000

    // Extraer solo el resumen (Plan: X to add, Y to change, Z to destroy)
    def summary = (plan =~ /Plan: .+/).find() ?: 'Sin cambios detectados'

    def body = plan.length() > maxLen
        ? plan.substring(0, maxLen) + "\n...(truncado — ver consola Jenkins para el plan completo)"
        : plan

    return """
## 📋 Terraform Plan · `${env.toUpperCase()}`

**${summary}**

<details>
<summary>Ver plan completo</summary>

\`\`\`hcl
${body}
\`\`\`

</details>

_Generado por Jenkins build [#${BUILD_NUMBER}](${BUILD_URL})_
    """.stripIndent()
}
