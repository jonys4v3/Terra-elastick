// jenkins/shared-libs/vars/pagerduty.groovy

/**
 * Abre un incidente en PagerDuty cuando algo crítico falla en prod.
 */
def triggerAlert(Map args) {
    def summary   = args.summary   ?: 'Jenkins pipeline failure'
    def severity  = args.severity  ?: 'error'   // critical | error | warning | info
    def buildUrl  = args.buildUrl  ?: env.BUILD_URL

    def payload = groovy.json.JsonOutput.toJson([
        routing_key  : env.PAGERDUTY_ROUTING_KEY,
        event_action : 'trigger',
        payload      : [
            summary   : summary,
            severity  : severity,
            source    : 'Jenkins CI/CD',
            custom_details: [
                build_url  : buildUrl,
                job_name   : env.JOB_NAME,
                build_num  : env.BUILD_NUMBER,
                git_commit : env.GIT_COMMIT ?: 'unknown'
            ]
        ],
        links: [[href: buildUrl, text: "Jenkins Build #${env.BUILD_NUMBER}"]]
    ])

    sh """
        curl -s -X POST \
            -H "Content-Type: application/json" \
            -d '${payload}' \
            "https://events.pagerduty.com/v2/enqueue" || true
    """
    echo "🚨 Incidente PagerDuty enviado: ${summary}"
}
