#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# scripts/bootstrap.sh
# Script completo para instalar Jenkins en EKS partiendo de cero.
# Instala: eksctl, helm, cert-manager, nginx-ingress, Jenkins.
#
# Prerrequisitos:
#   - AWS CLI configurado con permisos suficientes
#   - kubectl apuntando al cluster EKS correcto
#   - helm >= 3.14
#
# Uso: ./scripts/bootstrap.sh [--dry-run]
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

DRY_RUN="${1:-}"
CLUSTER_NAME="${CLUSTER_NAME:-acme-eks-prod}"
AWS_REGION="${AWS_REGION:-eu-west-1}"
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
JENKINS_DOMAIN="${JENKINS_DOMAIN:-jenkins.acme.internal}"
COMPANY="${COMPANY:-acme}"

log()  { echo -e "\033[0;36m[INFO]\033[0m  $*"; }
ok()   { echo -e "\033[0;32m[ OK ]\033[0m  $*"; }
warn() { echo -e "\033[0;33m[WARN]\033[0m  $*"; }
err()  { echo -e "\033[0;31m[ERR ]\033[0m  $*"; exit 1; }

run() {
    if [[ "${DRY_RUN}" == "--dry-run" ]]; then
        echo "  [DRY-RUN] $*"
    else
        eval "$@"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
log "🚀 Bootstrap Jenkins en EKS — cluster: ${CLUSTER_NAME}"
log "   AWS Account : ${AWS_ACCOUNT_ID}"
log "   Region      : ${AWS_REGION}"
log "   Domain      : ${JENKINS_DOMAIN}"
echo ""

# ── 1. Verificar conectividad al cluster ─────────────────────────────────────
log "1/8 Verificando conexión al cluster EKS..."
kubectl cluster-info --context "$(kubectl config current-context)" \
    || err "No se puede conectar al cluster. Ejecuta: aws eks update-kubeconfig --name ${CLUSTER_NAME}"
ok "Cluster accesible"

# ── 2. Crear IAM Role para Jenkins (IRSA) ────────────────────────────────────
log "2/8 Creando IAM Role para Jenkins (IRSA)..."

# Crear OIDC provider para el cluster si no existe
run eksctl utils associate-iam-oidc-provider \
    --cluster "${CLUSTER_NAME}" \
    --region "${AWS_REGION}" \
    --approve

# Crear role para el controller
JENKINS_ROLE_ARN=$(aws iam get-role --role-name "${COMPANY}-jenkins-controller" \
    --query 'Role.Arn' --output text 2>/dev/null || echo "")

if [[ -z "${JENKINS_ROLE_ARN}" ]]; then
    run eksctl create iamserviceaccount \
        --name jenkins \
        --namespace jenkins \
        --cluster "${CLUSTER_NAME}" \
        --region "${AWS_REGION}" \
        --attach-policy-arn "arn:aws:iam::aws:policy/SecretsManagerReadWrite" \
        --attach-policy-arn "arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${COMPANY}-jenkins-terraform-policy" \
        --role-name "${COMPANY}-jenkins-controller" \
        --approve \
        --override-existing-serviceaccounts
    JENKINS_ROLE_ARN=$(aws iam get-role --role-name "${COMPANY}-jenkins-controller" \
        --query 'Role.Arn' --output text)
    ok "IAM Role creado: ${JENKINS_ROLE_ARN}"
else
    ok "IAM Role ya existe: ${JENKINS_ROLE_ARN}"
fi

# ── 3. Crear Namespaces y RBAC ───────────────────────────────────────────────
log "3/8 Aplicando namespaces y RBAC..."
# Reemplazar el placeholder del ARN antes de aplicar
sed "s|\${JENKINS_CONTROLLER_IAM_ROLE_ARN}|${JENKINS_ROLE_ARN}|g" \
    k8s/rbac/jenkins-rbac.yaml | kubectl apply -f -
ok "RBAC aplicado"

# ── 4. Instalar cert-manager ─────────────────────────────────────────────────
log "4/8 Instalando cert-manager..."
helm repo add jetstack https://charts.jetstack.io --force-update
run helm upgrade --install cert-manager jetstack/cert-manager \
    --namespace cert-manager \
    --create-namespace \
    --version v1.14.4 \
    --set installCRDs=true \
    --wait
ok "cert-manager instalado"

# ── 5. Instalar NGINX Ingress ─────────────────────────────────────────────────
log "5/8 Instalando NGINX Ingress Controller..."
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx --force-update
run helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
    --namespace ingress-nginx \
    --create-namespace \
    --version 4.10.0 \
    --set controller.service.type=LoadBalancer \
    --set controller.service.annotations."service\.beta\.kubernetes\.io/aws-load-balancer-type"=nlb \
    --wait
ok "NGINX Ingress instalado"

# ── 6. Crear Secrets desde AWS Secrets Manager ───────────────────────────────
log "6/8 Sincronizando secrets desde AWS Secrets Manager..."

create_k8s_secret() {
    local name="$1"
    local sm_key="$2"
    local namespace="${3:-jenkins}"

    local value
    value=$(aws secretsmanager get-secret-value \
        --secret-id "${COMPANY}/${sm_key}" \
        --region "${AWS_REGION}" \
        --query 'SecretString' \
        --output text 2>/dev/null || echo "")

    if [[ -z "${value}" ]]; then
        warn "Secret '${COMPANY}/${sm_key}' no encontrado en Secrets Manager — crea el secret primero"
        return
    fi

    kubectl create secret generic "${name}" \
        --namespace "${namespace}" \
        --from-literal="value=${value}" \
        --dry-run=client -o yaml | kubectl apply -f -
    ok "Secret '${name}' sincronizado"
}

create_k8s_secret "github-token"       "jenkins/github-token"
create_k8s_secret "slack-webhook"      "jenkins/slack-webhook"
create_k8s_secret "aws-creds-dev"      "jenkins/aws-dev"
create_k8s_secret "aws-creds-staging"  "jenkins/aws-staging"
create_k8s_secret "aws-creds-prod"     "jenkins/aws-prod"
create_k8s_secret "oidc-client"        "jenkins/oidc-client"

# ── 7. Instalar Jenkins vía Helm ─────────────────────────────────────────────
log "7/8 Instalando Jenkins..."
helm repo add jenkins https://charts.jenkins.io --force-update

# Inyectar el ARN del rol en los values
sed "s|\${JENKINS_IAM_ROLE_ARN}|${JENKINS_ROLE_ARN}|g" \
    helm/jenkins/values.yaml > /tmp/jenkins-values-rendered.yaml

run helm upgrade --install jenkins jenkins/jenkins \
    --namespace jenkins \
    --create-namespace \
    --version 5.3.3 \
    --values /tmp/jenkins-values-rendered.yaml \
    --set controller.ingress.hostName="${JENKINS_DOMAIN}" \
    --wait \
    --timeout 10m

ok "Jenkins instalado"

# ── 8. Verificar y mostrar URL ───────────────────────────────────────────────
log "8/8 Verificando instalación..."
kubectl rollout status statefulset/jenkins -n jenkins --timeout=300s
ok "Jenkins controller running"

JENKINS_URL="https://${JENKINS_DOMAIN}"
log ""
log "════════════════════════════════════════════════════"
ok "✅ Jenkins instalado correctamente"
log "   URL    : ${JENKINS_URL}"
log "   Namespace: jenkins"
log ""
log "   Próximos pasos:"
log "   1. Configurar DNS para ${JENKINS_DOMAIN}"
log "   2. Verificar JCasC en: ${JENKINS_URL}/configuration-as-code"
log "   3. Revisar pipelines en: ${JENKINS_URL}/view/all"
log "════════════════════════════════════════════════════"
