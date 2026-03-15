# Runbook Operacional — Jenkins + Elasticsearch en EKS

## 1. Añadir nueva aplicación ES (flujo completo)

```bash
# Opción A: desde línea de comandos
curl -X POST "https://jenkins.acme.internal/job/elasticsearch-new-app/buildWithParameters" \
     -u "user:token" \
     --data "APP_NAME=mi-nueva-app&TARGET_ENV=all&INSTANCE_TYPE=r6g.large.search&JIRA_TICKET=PLAT-1234"

# Opción B: desde Jenkins UI
# 1. Ir a: https://jenkins.acme.internal/job/elasticsearch-new-app/
# 2. Clic en "Build with Parameters"
# 3. Rellenar APP_NAME, TARGET_ENV, etc.
# 4. Clic en "Build"
```

El pipeline automáticamente:
1. Valida el nombre de la app
2. Crea la rama `feat/add-app-<nombre>`
3. Añade la app en `environments/*/main.tf`
4. Ejecuta `terraform plan`
5. Abre un PR en GitHub con el diff
6. Tras merge → apply progresivo dev → staging → prod (con aprobaciones)

---

## 2. Emergencia: rollback en PROD

```bash
# Ver el último estado estable
cd environments/prod
terraform show

# Rollback al commit anterior (solo si el tfstate no ha divergido)
git revert HEAD --no-edit
git push origin main
# → Jenkins lanzará el pipeline de apply automáticamente

# Si el estado está corrupto: restaurar desde S3
aws s3 cp s3://acme-terraform-state-prod/elasticsearch/prod/terraform.tfstate.backup \
          s3://acme-terraform-state-prod/elasticsearch/prod/terraform.tfstate
```

---

## 3. Jenkins controller no arranca

```bash
# Ver logs
kubectl logs -n jenkins statefulset/jenkins -c jenkins --tail=200

# Reiniciar
kubectl rollout restart statefulset/jenkins -n jenkins

# Ver eventos
kubectl describe pod -n jenkins -l app.kubernetes.io/component=jenkins-controller

# Acceso de emergencia (bypass OIDC)
# Obtener admin password inicial
kubectl exec -n jenkins statefulset/jenkins -c jenkins -- \
    cat /run/secrets/additional/chart-admin-password
```

---

## 4. Agente Terraform stuck / no arranca

```bash
# Ver pods de agentes
kubectl get pods -n jenkins-agents

# Describir pod con error
kubectl describe pod -n jenkins-agents <pod-name>

# Ver logs del agente
kubectl logs -n jenkins-agents <pod-name> -c terraform

# Forzar limpieza de pods stuck
kubectl delete pods -n jenkins-agents --field-selector status.phase=Failed
kubectl delete pods -n jenkins-agents --field-selector status.phase=Unknown
```

---

## 5. Desbloquear semáforo Terraform bloqueado

Si un build falló a mitad y el lockableResource quedó bloqueado:

```
Jenkins UI → Manage Jenkins → Lockable Resources → Unlock "terraform-lock-prod"
```

O via API:
```bash
curl -X POST "https://jenkins.acme.internal/lockable-resources/unlock" \
     -u "admin:token" \
     --data "resourceName=terraform-lock-prod"
```

---

## 6. Actualizar versión de Terraform

```bash
# 1. Actualizar versions.tf
sed -i 's/required_version = ">= 1.7.0"/required_version = ">= 1.8.0"/' versions.tf

# 2. Reconstruir imagen del agente
./scripts/build-agent-image.sh 1.8.0

# 3. Actualizar tag en helm/jenkins/values.yaml
# 4. Actualizar Jenkins
helm upgrade jenkins jenkins/jenkins -n jenkins -f helm/jenkins/values.yaml

# 5. Verificar en un entorno no-prod primero
```

---

## 7. Diagnóstico de dominio ES en estado RED

```bash
# Ver alarmas activas
aws cloudwatch describe-alarms \
    --state-value ALARM \
    --alarm-name-prefix "acme-" \
    --region eu-west-1

# Ver logs del dominio
aws logs filter-log-events \
    --log-group-name "/aws/opensearch/acme-payments-prod-es/application" \
    --start-time $(date -d '1 hour ago' +%s)000 \
    --region eu-west-1

# Estado del clúster
aws opensearch describe-domain \
    --domain-name acme-payments-prod-es \
    --query 'DomainStatus.{Status:Processing,Endpoint:Endpoints}' \
    --region eu-west-1
```

---

## 8. Rotación de credenciales AWS en Jenkins

```bash
# 1. Generar nuevas credenciales en AWS IAM
# 2. Actualizar en AWS Secrets Manager
aws secretsmanager put-secret-value \
    --secret-id "acme/jenkins/aws-prod" \
    --secret-string '{"access_key":"NEW_KEY","secret_key":"NEW_SECRET"}'

# 3. Resincronizar en Kubernetes
./scripts/bootstrap.sh  # re-ejecuta solo el paso de secrets

# 4. Verificar en Jenkins
# Jenkins UI → Credentials → aws-credentials-prod → Update
```
