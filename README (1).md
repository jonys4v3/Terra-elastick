# Plataforma Elasticsearch en AWS — Terraform + Jenkins en EKS

> Infraestructura como código para desplegar instancias **Amazon OpenSearch / Elasticsearch** aisladas por aplicación en AWS, con un pipeline CI/CD completamente automatizado sobre **Jenkins en EKS**.

---

## Tabla de contenidos

1. [Visión general](#1-visión-general)
2. [Arquitectura](#2-arquitectura)
3. [Prerrequisitos](#3-prerrequisitos)
4. [Estructura de repositorios](#4-estructura-de-repositorios)
5. [Instalación paso a paso](#5-instalación-paso-a-paso)
   - [5.1 Preparar AWS](#51-preparar-aws)
   - [5.2 Crear secrets en AWS Secrets Manager](#52-crear-secrets-en-aws-secrets-manager)
   - [5.3 Inicializar backend de Terraform](#53-inicializar-backend-de-terraform)
   - [5.4 Desplegar IAM y ECR](#54-desplegar-iam-y-ecr)
   - [5.5 Construir imagen del agente](#55-construir-imagen-del-agente)
   - [5.6 Instalar Jenkins en EKS](#56-instalar-jenkins-en-eks)
   - [5.7 Verificar la instalación](#57-verificar-la-instalación)
6. [Añadir una nueva aplicación](#6-añadir-una-nueva-aplicación)
7. [Pipelines de CI/CD](#7-pipelines-de-cicd)
8. [Configuración por entorno](#8-configuración-por-entorno)
9. [Seguridad](#9-seguridad)
10. [Monitorización y alertas](#10-monitorización-y-alertas)
11. [Operaciones habituales](#11-operaciones-habituales)
12. [Resolución de problemas](#12-resolución-de-problemas)
13. [Referencia de variables](#13-referencia-de-variables)

---

## 1. Visión general

Esta plataforma permite:

- Desplegar un dominio **Amazon OpenSearch independiente** (con KMS, IAM, SG y alarmas propios) por cada aplicación nueva, en tres entornos (dev / staging / prod).
- Automatizar todo el ciclo de vida mediante **Jenkins en EKS** con agentes efímeros Kubernetes que escalan automáticamente con **Karpenter**.
- Añadir una nueva app en **menos de 5 minutos** ejecutando un único comando en Jenkins.
- Garantizar que ningún apply en producción ocurre sin **aprobación humana explícita**.

### Convención de nombres

```
<company>-<app>-<env>-es
```

Ejemplos: `acme-payments-prod-es`, `acme-search-staging-es`, `acme-analytics-dev-es`

---

## 2. Arquitectura

```
┌──────────────────────────────────────────────────────────────────┐
│  GitHub                                                          │
│  Push / PR → Webhook ─────────────────────────────────────┐     │
└──────────────────────────────────────────────────────────────┘  │
                                                                   ▼
┌────────────────────────── Amazon EKS ────────────────────────────┐
│                                                                   │
│  namespace: jenkins                                               │
│  ┌─────────────────────────────────────────────────────────┐     │
│  │  Jenkins Controller (StatefulSet)                       │     │
│  │  · JCasC (Configuration as Code)                       │     │
│  │  · Credenciales desde AWS Secrets Manager               │     │
│  │  · OIDC auth (GitHub/Okta)                              │     │
│  │  · Job DSL auto-seed de pipelines                       │     │
│  └──────────────────────┬──────────────────────────────────┘     │
│                         │ crea pods dinámicos por build           │
│  namespace: jenkins-agents                                        │
│  ┌──────────────────────▼──────────────────────────────────┐     │
│  │  Pods efímeros (eliminados al terminar el build)        │     │
│  │  · terraform-agent  (Terraform + AWS CLI + tflint)     │     │
│  │  · kubectl-agent                                        │     │
│  └─────────────────────────────────────────────────────────┘     │
│                         │                                         │
│  Karpenter              │ escala nodos EC2 Spot automáticamente   │
│  ┌──────────────────────▼──────────────────────────────────┐     │
│  │  NodePool jenkins-agents                                │     │
│  │  c6i/m6i large→2xlarge · Spot primero · On-Demand backup│     │
│  └─────────────────────────────────────────────────────────┘     │
└───────────────────────────────────────────────────────────────────┘
          │                               │
          ▼                               ▼
  Amazon OpenSearch             AWS Services
  (dominio por app/env)    S3 · DynamoDB · KMS · IAM
  acme-payments-prod-es    (estado Terraform + locking)
  acme-search-prod-es
  acme-analytics-prod-es
```

### Flujo de un Pull Request

```
PR abierto → Jenkins (Jenkinsfile.pr)
  ├── Stage 1: Validate & Lint    (terraform fmt, validate, tflint)
  ├── Stage 2: Plan DEV           → comentario con diff en el PR
  ├── Stage 3: Plan STAGING       → comentario con diff en el PR
  ├── Stage 4: Plan PROD          → comentario con diff en el PR
  └── Stage 5: Resumen final      → tabla de estado en el PR

PR mergeado a main → Jenkins (Jenkinsfile.prod)
  ├── Apply DEV          (automático, sin aprobación)
  ├── ── Gate ──         (aprobación manual requerida)
  ├── Apply STAGING      (tras aprobación)
  ├── ── Gate ──         (aprobación manual requerida, con checkbox)
  ├── Apply PROD         (tras aprobación)
  └── Smoke Tests PROD   (verifica endpoints ES activos)
```

---

## 3. Prerrequisitos

### Herramientas locales

| Herramienta | Versión mínima | Instalación |
|---|---|---|
| AWS CLI | >= 2.15 | `brew install awscli` |
| kubectl | >= 1.29 | `brew install kubectl` |
| helm | >= 3.14 | `brew install helm` |
| eksctl | >= 0.175 | `brew tap weaveworks/tap && brew install eksctl` |
| Terraform | >= 1.7 | `brew install terraform` |
| Docker | >= 24 | [docker.com](https://docker.com) |
| git | >= 2.40 | `brew install git` |

### Permisos AWS necesarios

El usuario/role con el que ejecutes el bootstrap necesita:

- `AdministratorAccess` en la cuenta de AWS (o políticas específicas de EKS, IAM, ECR, S3, DynamoDB).
- Acceso al cluster EKS: `aws eks update-kubeconfig --name <cluster> --region <region>`

### Cluster EKS existente

Esta plataforma **no crea el cluster EKS** — asume que ya existe uno. Si necesitas crearlo:

```bash
eksctl create cluster \
  --name acme-eks-prod \
  --region eu-west-1 \
  --nodegroup-name system \
  --node-type m5.large \
  --nodes 3 \
  --nodes-min 2 \
  --nodes-max 5 \
  --managed
```

---

## 4. Estructura de repositorios

Este proyecto se compone de **dos repositorios** que trabajan juntos:

```
.
├── terraform-elasticsearch/       ← Repositorio 1: Infraestructura ES
│   ├── modules/
│   │   ├── elasticsearch/         # Módulo principal: dominio OpenSearch
│   │   ├── monitoring/            # CloudWatch alarms + SNS + dashboard
│   │   ├── security/              # IAM roles y políticas por app
│   │   └── networking/            # Data sources de VPC/subnets
│   ├── environments/
│   │   ├── dev/                   # main.tf, variables.tf, backend.hcl
│   │   ├── staging/
│   │   └── prod/                  # ← Aquí se añaden las nuevas apps
│   ├── apps/
│   │   └── app-example/           # Plantilla para nuevas apps
│   ├── policies/
│   │   └── terraform-ci-policy.json
│   └── scripts/
│       ├── bootstrap.sh           # Crea S3 + DynamoDB para el estado
│       ├── deploy.sh              # Wrapper plan/apply/destroy
│       └── new-app.sh             # Scaffolding nueva app
│
└── jenkins-eks/                   ← Repositorio 2: CI/CD Jenkins
    ├── helm/jenkins/values.yaml   # Chart Jenkins (plugins, recursos, ingress)
    ├── jenkins/
    │   ├── casc/jenkins.yaml      # Configuration as Code completo
    │   ├── pipelines/             # Jenkinsfile por tipo/entorno
    │   └── shared-libs/vars/      # Librería Groovy compartida
    ├── k8s/
    │   ├── rbac/                  # RBAC, NetworkPolicy
    │   ├── agents/                # Dockerfile, Karpenter, ResourceQuota
    │   └── namespaces/            # IAM roles (Terraform) + ECR
    ├── scripts/
    │   ├── bootstrap.sh           # Instalación completa desde cero
    │   └── build-agent-image.sh   # Build + scan + push imagen agente
    └── docs/
        ├── runbook.md
        └── architecture-decisions.md
```

---

## 5. Instalación paso a paso

### 5.1 Preparar AWS

```bash
# Clonar ambos repositorios
git clone git@github.com:acme/terraform-elasticsearch.git
git clone git@github.com:acme/jenkins-eks.git

# Configurar perfil AWS
aws configure --profile acme-prod
# → AWS Access Key ID: <tu-key>
# → AWS Secret Access Key: <tu-secret>
# → Default region: eu-west-1

# Verificar identidad
aws sts get-caller-identity --profile acme-prod

# Apuntar kubectl al cluster EKS
aws eks update-kubeconfig \
  --name acme-eks-prod \
  --region eu-west-1 \
  --profile acme-prod

# Verificar conectividad
kubectl get nodes
```

### 5.2 Crear secrets en AWS Secrets Manager

Jenkins lee todos sus secretos desde AWS Secrets Manager. Créalos antes de instalar:

```bash
# Función helper
create_secret() {
  aws secretsmanager create-secret \
    --name "acme/$1" \
    --secret-string "$2" \
    --region eu-west-1
}

# Token de GitHub (necesita permisos: repo, write:discussion, admin:repo_hook)
create_secret "jenkins/github-token" "ghp_xxxxxxxxxxxxxxxxxxxx"

# Slack Incoming Webhook
create_secret "jenkins/slack-webhook" "https://hooks.slack.com/services/XXX/YYY/ZZZ"

# Credenciales AWS por entorno (o usa IRSA si el agente asume roles directamente)
create_secret "jenkins/aws-dev"     '{"access_key":"AKIADEV...","secret_key":"..."}'
create_secret "jenkins/aws-staging" '{"access_key":"AKIASTG...","secret_key":"..."}'
create_secret "jenkins/aws-prod"    '{"access_key":"AKIAPRD...","secret_key":"..."}'

# OIDC (si usas GitHub OAuth / Okta)
create_secret "jenkins/oidc-client" '{"client_id":"xxx","client_secret":"yyy"}'
```

### 5.3 Inicializar backend de Terraform

El estado de Terraform se almacena en S3 con locking en DynamoDB. Ejecuta esto **una sola vez por entorno**:

```bash
cd terraform-elasticsearch

# Para cada entorno (dev, staging, prod):
export COMPANY=acme
bash scripts/bootstrap.sh dev     eu-west-1 acme-prod
bash scripts/bootstrap.sh staging eu-west-1 acme-prod
bash scripts/bootstrap.sh prod    eu-west-1 acme-prod
```

Esto crea:
- `acme-terraform-state-dev` (S3, versionado, cifrado)
- `acme-terraform-state-staging`
- `acme-terraform-state-prod`
- `acme-terraform-lock` (DynamoDB, PAY_PER_REQUEST)

### 5.4 Desplegar IAM y ECR

Los roles IAM para Jenkins y el repositorio ECR para la imagen del agente se crean con Terraform:

```bash
cd jenkins-eks/k8s/namespaces

# Inicializar
terraform init

# Revisar lo que se creará
terraform plan \
  -var="cluster_name=acme-eks-prod" \
  -var="company=acme" \
  -var="terraform_ci_policy_arn=arn:aws:iam::<ACCOUNT_ID>:policy/acme-jenkins-terraform-policy"

# Aplicar
terraform apply \
  -var="cluster_name=acme-eks-prod" \
  -var="company=acme" \
  -var="terraform_ci_policy_arn=arn:aws:iam::<ACCOUNT_ID>:policy/acme-jenkins-terraform-policy"

# Guardar los ARNs del output — los necesitarás en el siguiente paso
terraform output jenkins_controller_role_arn
terraform output jenkins_agent_role_arn
terraform output ecr_repository_url
```

> **Nota:** La política `acme-jenkins-terraform-policy` se encuentra en `terraform-elasticsearch/policies/terraform-ci-policy.json`. Créala primero:
> ```bash
> aws iam create-policy \
>   --policy-name acme-jenkins-terraform-policy \
>   --policy-document file://terraform-elasticsearch/policies/terraform-ci-policy.json
> ```

### 5.5 Construir imagen del agente

La imagen del agente incluye Terraform, AWS CLI, tflint y kubectl con versiones exactas:

```bash
cd jenkins-eks

# Sustituye con la URL de tu ECR (output del paso anterior)
export AWS_REGION=eu-west-1
export COMPANY=acme

bash scripts/build-agent-image.sh 1.7.5
```

El script realiza automáticamente:
1. Crea el repositorio ECR si no existe
2. Hace login en ECR
3. Build de la imagen (`linux/amd64`)
4. Scan de vulnerabilidades con **Trivy** (alerta si hay CVEs críticos)
5. Push con tag `1.7.5` y `latest`

Actualiza la imagen en `helm/jenkins/values.yaml`:

```yaml
# helm/jenkins/values.yaml → sección podTemplates.terraform.containers
image: "<ACCOUNT_ID>.dkr.ecr.eu-west-1.amazonaws.com/acme/jenkins-terraform-agent"
tag: "1.7.5"
```

### 5.6 Instalar Jenkins en EKS

```bash
cd jenkins-eks

# Variables de entorno requeridas
export CLUSTER_NAME=acme-eks-prod
export AWS_REGION=eu-west-1
export JENKINS_DOMAIN=jenkins.acme.internal
export COMPANY=acme

# Instalación completa (8 pasos automáticos)
bash scripts/bootstrap.sh

# O en modo dry-run para ver qué haría sin ejecutar:
bash scripts/bootstrap.sh --dry-run
```

El script instala en orden:
1. Verifica conexión al cluster
2. Crea IAM Role (IRSA) para el controller
3. Aplica RBAC, namespaces y NetworkPolicy
4. Instala **cert-manager** (TLS automático)
5. Instala **NGINX Ingress** con NLB en AWS
6. Sincroniza secrets desde Secrets Manager a Kubernetes
7. Instala Jenkins vía Helm con los values configurados
8. Verifica que el rollout es exitoso

### 5.7 Verificar la instalación

```bash
# Controller running
kubectl get pods -n jenkins
# → NAME                      READY   STATUS    RESTARTS   AGE
# → jenkins-0                 2/2     Running   0          3m

# Logs del controller (sin errores)
kubectl logs -n jenkins statefulset/jenkins -c jenkins --tail=50

# Acceso web
echo "Jenkins disponible en: https://${JENKINS_DOMAIN}"

# Obtener password inicial (solo si no se configuró OIDC aún)
kubectl exec -n jenkins statefulset/jenkins -c jenkins -- \
  cat /run/secrets/additional/chart-admin-password
```

**Checks en la UI de Jenkins:**

| URL | Qué verificar |
|---|---|
| `https://jenkins.acme.internal/configuration-as-code` | JCasC aplicado correctamente |
| `https://jenkins.acme.internal/credentials` | Todos los secrets visibles |
| `https://jenkins.acme.internal/view/all` | Pipelines auto-creados por Job DSL |
| `https://jenkins.acme.internal/lockable-resources` | 3 semáforos (dev/staging/prod) |

---

## 6. Añadir una nueva aplicación

### Opción A — Desde Jenkins UI (recomendado)

1. Abre `https://jenkins.acme.internal/job/elasticsearch-new-app/`
2. Haz clic en **"Build with Parameters"**
3. Rellena los campos:

| Parámetro | Ejemplo | Descripción |
|---|---|---|
| `APP_NAME` | `recommendations` | Nombre lowercase, máx 20 chars |
| `TARGET_ENV` | `all` | `dev`, `staging`, `prod` o `all` |
| `INSTANCE_TYPE` | `r6g.large.search` | Tipo instancia para prod |
| `INSTANCE_COUNT` | `3` | Nodos de datos (>=2 para HA) |
| `EBS_VOLUME_SIZE` | `100` | GB por nodo |
| `ALERT_EMAILS` | `team@acme.com,oncall@acme.com` | Emails de alerta |
| `JIRA_TICKET` | `PLAT-1234` | Para trazabilidad (opcional) |

4. Haz clic en **"Build"**

### Opción B — Desde línea de comandos (API de Jenkins)

```bash
curl -X POST \
  "https://jenkins.acme.internal/job/elasticsearch-new-app/buildWithParameters" \
  --user "usuario:api-token" \
  --data-urlencode "APP_NAME=recommendations" \
  --data-urlencode "TARGET_ENV=all" \
  --data-urlencode "INSTANCE_TYPE=r6g.large.search" \
  --data-urlencode "INSTANCE_COUNT=3" \
  --data-urlencode "EBS_VOLUME_SIZE=100" \
  --data-urlencode "ALERT_EMAILS=team@acme.com" \
  --data-urlencode "JIRA_TICKET=PLAT-1234"
```

### Opción C — Manualmente (para casos especiales)

```bash
cd terraform-elasticsearch

# 1. Crear scaffolding
bash scripts/new-app.sh recommendations

# 2. Editar apps/recommendations/terraform.tfvars con tus valores

# 3. Añadir la app en environments/prod/main.tf:
#    Dentro de locals.apps añade:
#
#    recommendations = {
#      instance_type   = "r6g.large.search"
#      instance_count  = 3
#      ebs_volume_size = 100
#      alert_emails    = ["team@acme.com"]
#    }

# 4. Commit y PR
git checkout -b feat/add-app-recommendations
git add -A
git commit -m "feat(es): add recommendations app [PLAT-1234]"
git push origin feat/add-app-recommendations
# → Abre el PR → Jenkins ejecuta el plan automáticamente
```

### Recursos que se crean por app

| Recurso AWS | Nombre ejemplo |
|---|---|
| `aws_opensearch_domain` | `acme-recommendations-prod-es` |
| `aws_kms_key` | KMS key dedicada para cifrado |
| `aws_security_group` | `acme-recommendations-prod-es-sg` |
| `aws_iam_role` | `recommendations-prod-es-role` |
| `aws_iam_policy` | `recommendations-prod-es-access` |
| `aws_cloudwatch_log_group` × 3 | index-slow, search-slow, application |
| `aws_cloudwatch_metric_alarm` × 6 | CPU, JVM, storage, status, snapshot |
| `aws_sns_topic` | `acme-recommendations-prod-es-alerts` |
| `aws_cloudwatch_dashboard` | Dashboard por app |

---

## 7. Pipelines de CI/CD

### Mapa de pipelines

| Pipeline | Fichero | Se lanza cuando |
|---|---|---|
| **PR Validation** | `Jenkinsfile.pr` | Se abre o actualiza un PR |
| **Deploy DEV** | `Jenkinsfile.dev` | Merge a `main` (automático) |
| **Deploy STAGING** | `Jenkinsfile.staging` | Tras apply DEV + aprobación |
| **Deploy PROD** | `Jenkinsfile.prod` | Orquesta dev→staging→prod |
| **Nueva App** | `Jenkinsfile.new-app` | Manualmente con parámetros |

### Aprobaciones manuales

Las aprobaciones en Jenkins (`input` step) notifican por Slack al canal `#ci-cd-prod-approvals`. Para aprobar:

- **Desde Slack:** clic en el enlace del mensaje → Jenkins UI → botón "Aprobar"
- **Desde Jenkins UI:** `Build #N` → "Paused for Input" → "Aprobar STAGING/PROD"

Los deploys en PROD requieren adicionalmente:
- Marcar la casilla **"He revisado el plan de Terraform"**
- Especificar el ticket JIRA del motivo

### Semáforos (Lockable Resources)

Para evitar que dos builds apliquen Terraform al mismo entorno simultáneamente:

| Recurso | Entorno protegido |
|---|---|
| `terraform-lock-dev` | DEV |
| `terraform-lock-staging` | STAGING |
| `terraform-lock-prod` | PROD |

Si un semáforo queda bloqueado tras un fallo: `Jenkins UI → Manage Jenkins → Lockable Resources → Unlock`

---

## 8. Configuración por entorno

### Diferencias entre entornos

| Parámetro | DEV | STAGING | PROD |
|---|---|---|---|
| Instance type | `t3.small.search` | `m6g.large.search` | `r6g.large.search` |
| Instance count | 1 | 2 | 3+ |
| AZs | 1 | 2 | 3 |
| Master nodes dedicados | ❌ | ❌ | ✅ (3) |
| Log retention | 7 días | 30 días | 180 días |
| `prevent_destroy` | ❌ | ❌ | ✅ |
| Apply automático | ✅ | Manual | Manual |
| Smoke tests | Básico | Básico | Completo |

### Personalizar un entorno

Edita el archivo `environments/<env>/main.tf` dentro de `locals.apps`:

```hcl
locals {
  apps = {
    payments = {
      instance_type            = "r6g.xlarge.search"   # Cambiar tamaño
      instance_count           = 6                      # Más nodos
      dedicated_master_enabled = true
      ebs_volume_size          = 500
      ebs_iops                 = 6000
      alert_emails             = ["team-payments@acme.com", "oncall@acme.com"]
    }
  }
}
```

---

## 9. Seguridad

### Modelo de seguridad

| Capa | Mecanismo |
|---|---|
| **Autenticación Jenkins** | OIDC (GitHub OAuth / Okta) — sin usuarios locales |
| **Credenciales** | AWS Secrets Manager → Kubernetes Secrets (nunca en código) |
| **Acceso AWS** | IRSA (IAM Roles for Service Accounts) — sin access keys estáticas |
| **Red ES** | Solo VPC privada — sin endpoint público |
| **Cifrado ES en reposo** | KMS key dedicada por dominio |
| **Cifrado ES en tránsito** | TLS 1.2 mínimo obligatorio + node-to-node encryption |
| **Control de acceso ES** | Fine-Grained Access Control (FGAC) + resource policy |
| **Agentes CI** | Pods efímeros, eliminados tras cada build |
| **Aislamiento K8s** | NetworkPolicy: agentes solo pueden hablar con el controller |
| **Mínimo privilegio IAM** | Política de CI solo con permisos necesarios |

### Rotar credenciales AWS

```bash
# 1. Generar nuevas credenciales en IAM
# 2. Actualizar en Secrets Manager
aws secretsmanager put-secret-value \
  --secret-id "acme/jenkins/aws-prod" \
  --secret-string '{"access_key":"NEW_KEY","secret_key":"NEW_SECRET"}' \
  --region eu-west-1

# 3. Resincronizar en Kubernetes (re-ejecutar paso de secrets del bootstrap)
export CLUSTER_NAME=acme-eks-prod
export AWS_REGION=eu-west-1
bash jenkins-eks/scripts/bootstrap.sh
```

---

## 10. Monitorización y alertas

### Alarmas CloudWatch por dominio ES

Cada dominio tiene **6 alarmas** activas:

| Alarma | Umbral | Severidad |
|---|---|---|
| `ClusterStatus.red` | >= 1 durante 1 min | 🔴 Crítico |
| `ClusterStatus.yellow` | >= 1 durante 3 min | 🟡 Warning |
| `FreeStorageSpace` | < 5120 MB | 🔴 Crítico |
| `CPUUtilization` | > 80% durante 15 min | 🟡 Warning |
| `JVMMemoryPressure` | > 85% durante 15 min | 🟡 Warning |
| `AutomatedSnapshotFailure` | >= 1 | 🔴 Crítico |

Las alertas se envían al SNS topic del dominio y a los emails configurados en `alert_emails`.

### Dashboard CloudWatch

Cada dominio tiene un dashboard en CloudWatch:

```
AWS Console → CloudWatch → Dashboards → acme-<app>-<env>-es
```

### Métricas de Jenkins

Jenkins expone métricas Prometheus en `/prometheus`. Si tienes `kube-prometheus-stack` instalado, el `ServiceMonitor` se crea automáticamente.

---

## 11. Operaciones habituales

### Ver endpoints de todos los dominios ES en prod

```bash
cd terraform-elasticsearch/environments/prod
terraform output elasticsearch_endpoints
```

### Actualizar la versión de Terraform en los agentes

```bash
# 1. Actualizar versions.tf
# required_version = ">= 1.8.0"

# 2. Reconstruir y publicar imagen
bash jenkins-eks/scripts/build-agent-image.sh 1.8.0

# 3. Actualizar tag en helm/jenkins/values.yaml → podTemplates.terraform.tag

# 4. Actualizar Jenkins
helm upgrade jenkins jenkins/jenkins \
  -n jenkins \
  -f jenkins-eks/helm/jenkins/values.yaml
```

### Actualizar un plugin de Jenkins

Edita `helm/jenkins/values.yaml` → sección `installPlugins` → actualiza la versión.

```bash
helm upgrade jenkins jenkins/jenkins \
  -n jenkins \
  -f jenkins-eks/helm/jenkins/values.yaml
```

> Jenkins aplicará JCasC automáticamente al reiniciar. No hace falta entrar en la UI.

### Forzar re-aplicación de JCasC

```bash
kubectl exec -n jenkins statefulset/jenkins -c jenkins -- \
  curl -s -X POST http://localhost:8080/configuration-as-code/reload \
  -H "Authorization: Bearer $(cat /run/secrets/additional/chart-admin-password)"
```

### Escalar manualmente el pool de agentes Karpenter

```bash
# Ver nodos del pool
kubectl get nodes -l role=jenkins-agents

# Karpenter escala automáticamente — no es necesario intervención manual.
# Para forzar eliminación de nodos vacíos:
kubectl annotate node <node-name> karpenter.sh/do-not-disrupt-
```

### Destruir un dominio ES (solo dev/staging)

```bash
# NUNCA ejecutar en prod directamente
cd terraform-elasticsearch
bash scripts/deploy.sh dev destroy
```

---

## 12. Resolución de problemas

### Jenkins no arranca

```bash
# Ver logs del controller
kubectl logs -n jenkins statefulset/jenkins -c jenkins --tail=100

# Ver eventos del pod
kubectl describe pod -n jenkins -l app.kubernetes.io/component=jenkins-controller

# Reiniciar
kubectl rollout restart statefulset/jenkins -n jenkins
kubectl rollout status statefulset/jenkins -n jenkins --timeout=300s
```

### Agente Terraform no arranca

```bash
# Listar pods de agentes (incluye los fallidos)
kubectl get pods -n jenkins-agents -a

# Ver error del pod específico
kubectl describe pod -n jenkins-agents <pod-name>
kubectl logs -n jenkins-agents <pod-name> -c terraform

# Limpiar pods en estado Failed/Unknown
kubectl delete pods -n jenkins-agents --field-selector status.phase=Failed
kubectl delete pods -n jenkins-agents --field-selector status.phase=Unknown
```

### Terraform plan falla con error de autenticación AWS

```bash
# Verificar que el secret de AWS está bien en Kubernetes
kubectl get secret aws-creds-prod -n jenkins -o jsonpath='{.data.value}' | base64 -d

# Verificar que el IAM Role puede asumir permisos
aws sts assume-role \
  --role-arn "$(terraform output -raw jenkins_agent_role_arn)" \
  --role-session-name test
```

### Dominio ES en estado RED

```bash
# Ver alarmas activas
aws cloudwatch describe-alarms \
  --state-value ALARM \
  --alarm-name-prefix "acme-" \
  --region eu-west-1

# Ver logs de aplicación del dominio
aws logs filter-log-events \
  --log-group-name "/aws/opensearch/acme-payments-prod-es/application" \
  --start-time $(date -d '2 hours ago' +%s)000 \
  --region eu-west-1

# Estado completo del dominio
aws opensearch describe-domain \
  --domain-name acme-payments-prod-es \
  --region eu-west-1
```

### Semáforo Terraform bloqueado tras fallo

```
Jenkins UI → Manage Jenkins → Lockable Resources → terraform-lock-prod → Unlock
```

O via API:
```bash
curl -X POST \
  "https://jenkins.acme.internal/lockable-resources/unlock" \
  --user "admin:api-token" \
  --data "resourceName=terraform-lock-prod"
```

---

## 13. Referencia de variables

### Variables de entorno del bootstrap

| Variable | Por defecto | Descripción |
|---|---|---|
| `CLUSTER_NAME` | `acme-eks-prod` | Nombre del cluster EKS |
| `AWS_REGION` | `eu-west-1` | Región AWS |
| `JENKINS_DOMAIN` | `jenkins.acme.internal` | Dominio HTTPS de Jenkins |
| `COMPANY` | `acme` | Prefijo para todos los recursos |

### Variables principales del módulo Elasticsearch

| Variable | Tipo | Por defecto | Descripción |
|---|---|---|---|
| `app_name` | string | — | Nombre de la app (requerido) |
| `environment` | string | — | dev / staging / prod |
| `instance_type` | string | `t3.medium.search` | Tipo de instancia |
| `instance_count` | number | `2` | Nodos de datos |
| `ebs_volume_size` | number | `20` | GB por nodo |
| `ebs_volume_type` | string | `gp3` | Tipo de volumen |
| `dedicated_master_enabled` | bool | `false` | Master nodes dedicados |
| `log_retention_days` | number | `90` | Retención de logs CW |
| `snapshot_hour` | number | `3` | Hora UTC del snapshot |

### Tipos de instancia recomendados

| Caso de uso | DEV | STAGING | PROD |
|---|---|---|---|
| General | `t3.small.search` | `m6g.large.search` | `r6g.large.search` |
| Alta búsqueda | `t3.small.search` | `m6g.xlarge.search` | `r6g.xlarge.search` |
| Alto volumen datos | `t3.small.search` | `m6g.large.search` | `r6g.2xlarge.search` |
| Análisis intensivo | `t3.small.search` | `c6g.large.search` | `c6g.2xlarge.search` |

---

## Contribuir

1. Crea una rama: `git checkout -b feat/mi-cambio`
2. Realiza los cambios
3. Ejecuta las validaciones localmente:
   ```bash
   cd terraform-elasticsearch
   terraform fmt -recursive
   terraform validate  # en cada environments/*/
   tflint --recursive
   ```
4. Abre un PR → Jenkins ejecutará el plan automáticamente
5. Espera la revisión del equipo de Platform Engineering

---

## Contacto y soporte

| Canal | Uso |
|---|---|
| `#ci-cd-alerts` | Notificaciones automáticas de builds |
| `#ci-cd-prod-approvals` | Aprobaciones de deploy en PROD |
| `#platform-engineering` | Soporte y consultas |
| [Runbook operacional](docs/runbook.md) | Procedimientos de emergencia |
| [Decisiones de arquitectura](docs/architecture-decisions.md) | ADRs del proyecto |
