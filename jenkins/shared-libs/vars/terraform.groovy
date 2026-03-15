// ─────────────────────────────────────────────────────────────────────────────
// jenkins/shared-libs/vars/terraform.groovy
// Shared Library: funciones reutilizables para Terraform.
// Se usa en todos los Jenkinsfiles como: terraform.plan(environment: 'prod')
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Inicializa Terraform con el backend remoto del entorno dado.
 */
def init(Map args) {
    def env = args.environment
    dir("environments/${env}") {
        sh """
            terraform init \
                -backend-config=backend.hcl \
                -reconfigure \
                -input=false \
                -no-color
        """
    }
}

/**
 * Ejecuta terraform fmt -check recursivo.
 */
def fmt(Map args = [:]) {
    def check = args.containsKey('check') ? args.check : true
    def checkFlag = check ? '-check' : ''
    sh "terraform fmt ${checkFlag} -recursive -no-color"
}

/**
 * Valida los módulos para los entornos dados.
 */
def validate(Map args) {
    def envs = args.envs ?: ['dev', 'staging', 'prod']
    envs.each { e ->
        dir("environments/${e}") {
            sh """
                terraform init -backend=false -input=false -no-color
                terraform validate -no-color
            """
        }
    }
}

/**
 * Ejecuta tflint en todos los módulos y entornos.
 */
def lint() {
    sh """
        tflint --init --config=.tflint.hcl
        tflint --recursive --config=.tflint.hcl --no-color
    """
}

/**
 * Ejecuta terraform plan y devuelve el output como string.
 * También guarda el plan binario para el apply posterior.
 */
def plan(Map args) {
    def env       = args.environment
    def extraArgs = args.extraArgs ?: ''
    def planOutput = ''

    dir("environments/${env}") {
        init(environment: env)
        planOutput = sh(
            script: """
                terraform plan \
                    -out=tfplan \
                    -detailed-exitcode \
                    -input=false \
                    -no-color \
                    ${extraArgs} 2>&1
            """,
            returnStdout: true
        ).trim()

        // Guardar en artefacto para auditoría
        writeFile file: 'plan_output.txt', text: planOutput
        archiveArtifacts artifacts: 'plan_output.txt', fingerprint: true
    }

    echo "📋 Plan [${env}]:\n${planOutput.take(2000)}"
    return planOutput
}

/**
 * Aplica el plan previamente generado (o plan+apply si no hay tfplan).
 */
def apply(Map args) {
    def env         = args.environment
    def autoApprove = args.containsKey('autoApprove') ? args.autoApprove : false
    def approveFlag = autoApprove ? '-auto-approve' : ''

    dir("environments/${env}") {
        if (fileExists('tfplan')) {
            sh "terraform apply ${approveFlag} -input=false -no-color tfplan"
            sh "rm -f tfplan"
        } else {
            sh "terraform apply ${approveFlag} -input=false -no-color"
        }
    }
}

/**
 * Obtiene los outputs de Terraform de un entorno y los devuelve como mapa.
 */
def outputs(Map args) {
    def env = args.environment
    def outputJson = ''

    dir("environments/${env}") {
        outputJson = sh(
            script: 'terraform output -json -no-color',
            returnStdout: true
        ).trim()
    }

    try {
        return readJSON text: outputJson
    } catch (e) {
        echo "⚠️ No se pudieron parsear los outputs: ${e.message}"
        return [:]
    }
}

/**
 * Ejecuta terraform destroy con confirmación extra.
 * SOLO para entornos no-prod.
 */
def destroy(Map args) {
    def env = args.environment
    if (env == 'prod') {
        error("❌ terraform destroy en PROD está bloqueado en el pipeline. Hazlo manualmente con supervisión.")
    }
    dir("environments/${env}") {
        sh "terraform destroy -auto-approve -input=false -no-color"
    }
}
