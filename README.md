# Jenkins en EKS — CI/CD para Terraform + Elasticsearch

Infraestructura completa para desplegar **Jenkins en Amazon EKS** con agentes
dinámicos Kubernetes, integración OIDC con AWS, pipelines declarativos para
Terraform y autoescalado de dominios Elasticsearch por aplicación.

## Arquitectura global

```
┌─────────────────────────────────────────────────────────────┐
│  GitHub / GitLab                                            │
│  Push / PR  →  Webhook  ──────────────────────────────┐    │
└─────────────────────────────────────────────────────────┘  │
                                                              ▼
┌─────────────────────── Amazon EKS ──────────────────────────┐
│                                                              │
│  namespace: jenkins                                          │
│  ┌──────────────────────────────────────────────────────┐   │
│  │  Jenkins Controller (StatefulSet)                    │   │
│  │  - CasC (config-as-code)                             │   │
│  │  - Credentials via AWS Secrets Manager               │   │
│  │  - Job DSL auto-seed                                 │   │
│  └───────────────────┬──────────────────────────────────┘   │
│                      │ crea pods dinámicamente               │
│  ┌───────────────────▼──────────────────────────────────┐   │
│  │  Jenkins Agents (Pods efímeros por build)            │   │
│  │  - terraform-agent  (imagen custom con tf+aws cli)  │   │
│  │  - kubectl-agent                                     │   │
│  └──────────────────────────────────────────────────────┘   │
│                                                              │
│  namespace: monitoring                                       │
│  ┌──────────────────────────────────────────────────────┐   │
│  │  Prometheus + Grafana (métricas Jenkins + ES)        │   │
│  └──────────────────────────────────────────────────────┘   │
└──────────────────────────────────────────────────────────────┘
         │                          │
         ▼                          ▼
   AWS OpenSearch              AWS Services
   (por app/entorno)      S3·DynamoDB·KMS·IAM
```

## Flujo completo de una nueva app

```
1. Developer: ./scripts/new-app.sh mi-app
2. Edita apps/mi-app/terraform.tfvars + environments/prod/main.tf
3. git push → PR abierto
4. Jenkins detecta PR → ejecuta pipeline
   ├── Stage: Validate & Lint (tflint, fmt)
   ├── Stage: Plan DEV     ──→ comenta diff en PR
   ├── Stage: Plan STAGING ──→ comenta diff en PR
   └── Stage: Plan PROD    ──→ comenta diff en PR
5. Aprobación del PR → merge a main
6. Jenkins ejecuta pipeline de apply
   ├── Apply DEV     (automático)
   ├── Gate: aprobación humana STAGING
   ├── Apply STAGING (tras aprobación)
   ├── Gate: aprobación humana PROD
   └── Apply PROD    (tras aprobación)
```

## Estructura de ficheros

```
jenkins-eks/
├── helm/jenkins/           # Chart values para instalar Jenkins vía Helm
├── k8s/                    # Manifiestos Kubernetes (RBAC, namespaces, agentes)
├── jenkins/
│   ├── casc/               # Jenkins Configuration as Code (JCasC)
│   ├── pipelines/          # Jenkinsfiles declarativos por tipo de pipeline
│   └── shared-libs/        # Shared Library: funciones reutilizables
├── scripts/                # Instalación, bootstrap, utilidades
└── docs/                   # Guías operacionales
```

## Requisitos

| Herramienta | Versión    |
|-------------|------------|
| kubectl     | >= 1.29    |
| helm        | >= 3.14    |
| AWS CLI     | >= 2.x     |
| eksctl      | >= 0.175   |
| Terraform   | >= 1.7     |
