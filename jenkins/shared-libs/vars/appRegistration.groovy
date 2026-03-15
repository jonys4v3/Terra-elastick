// jenkins/shared-libs/vars/appRegistration.groovy

/**
 * Inyecta una nueva app en el bloque locals.apps de un entorno Terraform.
 * Lee el main.tf del entorno, encuentra locals.apps y añade la nueva entrada.
 */
def injectIntoEnv(Map args) {
    def appName     = args.appName
    def environment = args.environment
    def instanceType   = args.instanceType   ?: 't3.medium.search'
    def instanceCount  = args.instanceCount  ?: 1
    def ebsVolumeSize  = args.ebsVolumeSize  ?: 20
    def alertEmails    = args.alertEmails    ?: []

    def mainTfPath = "environments/${environment}/main.tf"

    if (!fileExists(mainTfPath)) {
        error("No se encontró ${mainTfPath}")
    }

    def mainTf = readFile(mainTfPath)

    // Verificar que la app no existe ya
    if (mainTf.contains("${appName} = {")) {
        echo "⚠️ La app '${appName}' ya existe en ${environment}/main.tf — omitiendo"
        return
    }

    // Construir el bloque de la nueva app
    def emailList = alertEmails.collect { "\"${it}\"" }.join(', ')
    def newAppBlock = """
    ${appName} = {
      instance_type   = "${instanceType}"
      instance_count  = ${instanceCount}
      ebs_volume_size = ${ebsVolumeSize}
      alert_emails    = [${emailList}]
    }"""

    // Insertar antes del cierre del bloque apps
    // Buscamos el último '}' antes de '  }' que cierra locals.apps
    def updatedMainTf = mainTf.replaceFirst(
        /(\s*)(#\s*─+\s*añadir nuevas apps aquí\s*─+[^\n]*\n)/,
        "\$1\$2${newAppBlock}\n"
    )

    if (updatedMainTf == mainTf) {
        // Fallback: insertar antes del cierre de apps map
        updatedMainTf = mainTf.replaceFirst(
            /(apps\s*=\s*\{[^}]*?)(\s*\}\s*\n\s*common_tags)/,
            "\$1${newAppBlock}\n  \$2"
        )
    }

    writeFile file: mainTfPath, text: updatedMainTf
    echo "✅ App '${appName}' añadida a environments/${environment}/main.tf"
}
