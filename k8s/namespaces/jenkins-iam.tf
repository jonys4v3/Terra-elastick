# ─────────────────────────────────────────────────────────────────────────────
# k8s/namespaces/jenkins-iam.tf
# Recursos IAM necesarios para Jenkins en EKS:
#   - Role del controller (IRSA) → leer Secrets Manager
#   - Role de los agentes (IRSA) → ejecutar Terraform en cada entorno
#   - Repositorio ECR para la imagen del agente
# ─────────────────────────────────────────────────────────────────────────────

data "aws_eks_cluster" "main" {
  name = var.cluster_name
}

data "aws_iam_openid_connect_provider" "eks" {
  url = data.aws_eks_cluster.main.identity[0].oidc[0].issuer
}

locals {
  oidc_provider_arn = data.aws_iam_openid_connect_provider.eks.arn
  oidc_issuer       = trimprefix(data.aws_eks_cluster.main.identity[0].oidc[0].issuer, "https://")
}

# ── Role del controller Jenkins ──────────────────────────────────────────────
data "aws_iam_policy_document" "jenkins_controller_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer}:sub"
      values   = ["system:serviceaccount:jenkins:jenkins"]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "jenkins_controller" {
  name               = "${var.company}-jenkins-controller"
  assume_role_policy = data.aws_iam_policy_document.jenkins_controller_assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "jenkins_secrets_manager" {
  role       = aws_iam_role.jenkins_controller.name
  policy_arn = "arn:aws:iam::aws:policy/SecretsManagerReadWrite"
}

# ── Role de los agentes Terraform ────────────────────────────────────────────
data "aws_iam_policy_document" "jenkins_agent_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer}:sub"
      values   = ["system:serviceaccount:jenkins-agents:jenkins-agent-terraform"]
    }
  }
}

resource "aws_iam_role" "jenkins_agent" {
  name               = "${var.company}-jenkins-agent-terraform"
  assume_role_policy = data.aws_iam_policy_document.jenkins_agent_assume.json
  tags               = var.tags
}

# Adjuntar la política de Terraform CI (generada en el repo de ES)
resource "aws_iam_role_policy_attachment" "jenkins_agent_terraform" {
  role       = aws_iam_role.jenkins_agent.name
  policy_arn = var.terraform_ci_policy_arn
}

# ── ECR para la imagen del agente ─────────────────────────────────────────────
resource "aws_ecr_repository" "jenkins_agent" {
  name                 = "${var.company}/jenkins-terraform-agent"
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  tags = var.tags
}

# Política de ciclo de vida: mantener solo las últimas 10 imágenes
resource "aws_ecr_lifecycle_policy" "jenkins_agent" {
  repository = aws_ecr_repository.jenkins_agent.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Mantener solo las últimas 10 imágenes"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 10
      }
      action = { type = "expire" }
    }]
  })
}

# ── Outputs ───────────────────────────────────────────────────────────────────
output "jenkins_controller_role_arn" {
  value = aws_iam_role.jenkins_controller.arn
}

output "jenkins_agent_role_arn" {
  value = aws_iam_role.jenkins_agent.arn
}

output "ecr_repository_url" {
  value = aws_ecr_repository.jenkins_agent.repository_url
}

# ── Variables ─────────────────────────────────────────────────────────────────
variable "cluster_name"           { type = string }
variable "company"                { type = string }
variable "terraform_ci_policy_arn"{ type = string }
variable "tags"                   { type = map(string); default = {} }
