# ADR-001: Jenkins en EKS con agentes dinámicos para Terraform

**Estado:** Aceptado
**Fecha:** 2025-01
**Autores:** Platform Engineering Team

---

## Contexto

Necesitamos automatizar el despliegue de instancias Elasticsearch por app
usando Terraform en AWS, partiendo de cero infraestructura CI/CD.

## Decisión: Jenkins en EKS (vs GitHub Actions, GitLab CI, ArgoCD)

### ¿Por qué Jenkins y no GitHub Actions?

| Criterio | GitHub Actions | Jenkins en EKS |
|---|---|---|
| Self-hosted (datos no salen de AWS) | Parcial (runners propios) | ✅ Total |
| Aprobaciones manuales granulares | Limitado (Environments) | ✅ Completo (input step) |
| Semáforos por entorno (no applies paralelos) | ❌ No nativo | ✅ lockableResources |
| Shared libraries entre pipelines | ❌ No (actions separadas) | ✅ Groovy libraries |
| Coste con muchos builds | $$$ por minuto | ✅ Solo EC2 Spot |
| Autoescalado agentes | Manual | ✅ Karpenter automático |

### ¿Por qué agentes dinámicos Kubernetes y no agentes estáticos?

- Cada build arranca en un pod limpio → no hay contaminación entre builds
- Los pods se eliminan al terminar → coste cero cuando no hay builds
- Karpenter añade/elimina nodos EC2 Spot automáticamente
- Imagen del agente versionada e inmutable → reproducibilidad total

### ¿Por qué IRSA y no credenciales estáticas en Jenkins?

- Sin secrets de larga duración en Jenkins → reducción de superficie de ataque
- Credenciales rotadas automáticamente por AWS STS
- Trazabilidad: cada acción en AWS queda asociada al role del agente

## Flujo de seguridad

```
GitHub PR → Webhook → Jenkins
                         ↓
                   Crea Pod (jenkins-agents namespace)
                         ↓
                   Pod asume IAM Role vía IRSA (STS)
                         ↓
                   Terraform → AWS APIs (ES, KMS, IAM...)
                         ↓
                   Pod eliminado al terminar
```

## Consecuencias

- **Positivo:** Pipeline completamente auditable (S3 + CloudWatch)
- **Positivo:** Aprobaciones con identidad real (OIDC → usuario de empresa)
- **Positivo:** Autoescalado de nodos en 60-90 segundos con Karpenter
- **Negativo:** Requiere mantener Jenkins (actualizaciones, plugins)
- **Mitigación:** JCasC + Helm → upgrades como `helm upgrade`, sin estado manual
