#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# scripts/build-agent-image.sh
# Construye y publica la imagen del agente Terraform en Amazon ECR.
#
# Uso: ./scripts/build-agent-image.sh [tf-version]
# Ejemplo: ./scripts/build-agent-image.sh 1.7.5
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

TF_VERSION="${1:-1.7.5}"
AWS_REGION="${AWS_REGION:-eu-west-1}"
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
COMPANY="${COMPANY:-acme}"
ECR_REPO="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${COMPANY}/jenkins-terraform-agent"
IMAGE_TAG="${TF_VERSION}"

echo "🐳 Construyendo imagen: ${ECR_REPO}:${IMAGE_TAG}"

# Crear repositorio ECR si no existe
aws ecr describe-repositories \
    --repository-names "${COMPANY}/jenkins-terraform-agent" \
    --region "${AWS_REGION}" 2>/dev/null || \
aws ecr create-repository \
    --repository-name "${COMPANY}/jenkins-terraform-agent" \
    --region "${AWS_REGION}" \
    --image-scanning-configuration scanOnPush=true \
    --encryption-configuration encryptionType=AES256

# Login en ECR
aws ecr get-login-password --region "${AWS_REGION}" | \
    docker login --username AWS --password-stdin \
    "${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

# Build
docker build \
    --build-arg TERRAFORM_VERSION="${TF_VERSION}" \
    --platform linux/amd64 \
    -f k8s/agents/Dockerfile.terraform-agent \
    -t "${ECR_REPO}:${IMAGE_TAG}" \
    -t "${ECR_REPO}:latest" \
    .

# Scan de vulnerabilidades antes de subir
echo "🔍 Escaneando imagen con Trivy..."
docker run --rm \
    -v /var/run/docker.sock:/var/run/docker.sock \
    aquasec/trivy:latest image \
    --exit-code 0 \
    --severity CRITICAL \
    "${ECR_REPO}:${IMAGE_TAG}" || \
    echo "⚠️  Vulnerabilidades encontradas — revisa el reporte antes de usar en prod"

# Push
docker push "${ECR_REPO}:${IMAGE_TAG}"
docker push "${ECR_REPO}:latest"

echo "✅ Imagen publicada: ${ECR_REPO}:${IMAGE_TAG}"
echo ""
echo "📝 Actualiza helm/jenkins/values.yaml:"
echo "   image: \"${ECR_REPO}\""
echo "   tag: \"${IMAGE_TAG}\""
