// jenkins/shared-libs/vars/audit.groovy

/**
 * Registra una acción de aprobación/deploy en S3 para auditoría.
 */
def log(Map args) {
    def record = groovy.json.JsonOutput.toJson([
        timestamp   : new Date().format("yyyy-MM-dd'T'HH:mm:ss'Z'", TimeZone.getTimeZone('UTC')),
        action      : args.action,
        environment : args.environment,
        approver    : args.approver,
        reason      : args.reason ?: '',
        build       : args.build,
        job         : env.JOB_NAME,
        buildUrl    : env.BUILD_URL
    ])
    echo "📝 AUDIT: ${record}"
    // En producción real: enviar a S3, Splunk, o sistema de auditoría
}

/**
 * Guarda el log del build en S3.
 */
def saveToS3(Map args) {
    def bucket = args.bucket ?: 'acme-jenkins-audit-logs'
    def key    = "builds/${env.JOB_NAME}/${args.buildNumber}.json"
    sh """
        aws s3 cp \$JENKINS_HOME/jobs/\$JOB_NAME/builds/${args.buildNumber}/log \
            s3://${bucket}/${key} \
            --content-type text/plain || true
    """
}
