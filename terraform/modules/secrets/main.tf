# ── OpenAI API Key ────────────────────────────────────────────────────────────
# Note: RDS credentials are managed by the RDS module, not here.
resource "aws_secretsmanager_secret" "openai" {
  name                    = "petclinic/${var.environment}/openai-api-key"
  recovery_window_in_days = 0
  description = "OpenAI API key for GenAI service in ${var.project}-${var.environment}"

  tags = merge(var.tags, {
    Name = "petclinic/${var.environment}/openai-api-key"
  })
}

resource "aws_secretsmanager_secret_version" "openai" {
  secret_id     = aws_secretsmanager_secret.openai.id
  secret_string = var.openai_api_key == "" ? "demo" : var.openai_api_key
}

# ── Grafana Admin Credentials ─────────────────────────────────────────────────
resource "random_password" "grafana" {
  length           = 16
  special          = true
  override_special = "!#$%^&*()-_=+[]{}|"
}

resource "aws_secretsmanager_secret" "grafana" {
  name                    = "petclinic/${var.environment}/grafana-credentials"
  recovery_window_in_days = 0
  description             = "Grafana admin credentials for ${var.project}-${var.environment}"

  tags = merge(var.tags, {
    Name = "petclinic/${var.environment}/grafana-credentials"
  })
}

resource "aws_secretsmanager_secret_version" "grafana" {
  secret_id = aws_secretsmanager_secret.grafana.id
  secret_string = jsonencode({
    username = "admin"
    password = random_password.grafana.result
  })
}


# ── IRSA Role: External Secrets Operator ─────────────────────────────────────
resource "aws_iam_role" "eso" {
  name = "${var.project}-${var.environment}-eso-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = var.oidc_provider_arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${replace(var.oidc_provider_url, "https://", "")}:aud" = "sts.amazonaws.com"
          "${replace(var.oidc_provider_url, "https://", "")}:sub" = "system:serviceaccount:external-secrets:external-secrets-sa"
        }
      }
    }]
  })

  tags = var.tags
}

resource "aws_iam_policy" "eso" {
  name        = "${var.project}-${var.environment}-eso-policy"
  description = "Allow ESO to read secrets from Secrets Manager"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret"
        ]
        Resource = "arn:aws:secretsmanager:*:*:secret:petclinic/*"
      }
    ]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "eso" {
  role       = aws_iam_role.eso.name
  policy_arn = aws_iam_policy.eso.arn
}
