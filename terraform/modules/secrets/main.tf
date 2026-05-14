# ── OpenAI API Key ────────────────────────────────────────────────────────────
# Note: RDS credentials are managed by the RDS module, not here.
resource "aws_secretsmanager_secret" "openai" {
  name        = "petclinic/${var.environment}/openai-api-key"
  description = "OpenAI API key for GenAI service in ${var.project}-${var.environment}"

  tags = merge(var.tags, {
    Name = "petclinic/${var.environment}/openai-api-key"
  })
}

resource "aws_secretsmanager_secret_version" "openai" {
  secret_id     = aws_secretsmanager_secret.openai.id
  secret_string = var.openai_api_key == "" ? "demo" : var.openai_api_key
}
