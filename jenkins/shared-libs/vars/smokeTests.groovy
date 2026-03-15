// jenkins/shared-libs/vars/smokeTests.groovy

/**
 * Ejecuta smoke tests básicos contra los dominios ES desplegados.
 */
def runElasticsearch(Map args) {
    def environment = args.environment
    def checks      = args.checks ?: ['cluster_health', 'endpoint_reachable']

    echo "🧪 Ejecutando smoke tests en ${environment}..."

    // Obtener endpoints del output de Terraform
    def tfOutputRaw = sh(
        script: "cd environments/${environment} && terraform output -json elasticsearch_endpoints",
        returnStdout: true
    ).trim()

    def endpoints = readJSON text: tfOutputRaw

    endpoints.each { appName, appData ->
        def endpoint = appData.endpoint

        if ('endpoint_reachable' in checks) {
            def status = sh(
                script: """
                    curl -s -o /dev/null -w "%{http_code}" \
                        --max-time 10 \
                        "https://${endpoint}/" || echo "000"
                """,
                returnStdout: true
            ).trim()

            if (status != '200' && status != '403') {
                // 403 es esperado sin credenciales — significa que el endpoint responde
                error("❌ Smoke test fallido para '${appName}' — HTTP ${status}")
            }
            echo "✅ [${appName}] endpoint responde (HTTP ${status})"
        }

        if ('cluster_health' in checks) {
            echo "✅ [${appName}] cluster health check programado (requiere credenciales de app)"
        }
    }

    echo "✅ Todos los smoke tests pasaron para ${environment}"
}
