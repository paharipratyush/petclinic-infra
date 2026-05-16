# ── Random password ───────────────────────────────────────────────────────────
resource "random_password" "db" {
  length           = 16
  special          = true
  override_special = "!#$%^&*()-_=+[]{}|"
}

# ── DB Subnet Group ───────────────────────────────────────────────────────────
resource "aws_db_subnet_group" "main" {
  name        = "${var.project}-${var.environment}-db-subnet-group"
  subnet_ids  = var.subnet_ids
  description = "DB subnet group for ${var.project}-${var.environment}"

  tags = merge(var.tags, {
    Name = "${var.project}-${var.environment}-db-subnet-group"
  })
}

# ── DB Parameter Group ────────────────────────────────────────────────────────
resource "aws_db_parameter_group" "main" {
  name        = "${var.project}-${var.environment}-mysql8"
  family      = "mysql8.0"
  description = "MySQL 8.0 parameter group for ${var.project}-${var.environment}"

  parameter {
    name  = "character_set_server"
    value = "utf8mb4"
  }

  parameter {
    name  = "collation_server"
    value = "utf8mb4_unicode_ci"
  }

  tags = merge(var.tags, {
    Name = "${var.project}-${var.environment}-mysql8"
  })
}

# ── RDS Instance ──────────────────────────────────────────────────────────────
resource "aws_db_instance" "main" {
  identifier        = "${var.project}-${var.environment}-mysql"
  engine            = "mysql"
  engine_version    = "8.0"
  instance_class    = var.instance_class
  db_name           = "petclinic"
  username          = "petclinic"
  password          = random_password.db.result

  allocated_storage     = var.allocated_storage
  max_allocated_storage = var.max_allocated_storage
  storage_type          = "gp2"
  storage_encrypted     = true

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [var.rds_sg_id]
  parameter_group_name   = aws_db_parameter_group.main.name

  multi_az                = var.multi_az
  publicly_accessible     = false
  backup_retention_period = var.backup_retention_period
  skip_final_snapshot     = var.skip_final_snapshot
  deletion_protection     = var.deletion_protection

  tags = merge(var.tags, {
    Name = "${var.project}-${var.environment}-mysql"
  })
}

# ── Secrets Manager — RDS credentials ────────────────────────────────────────
resource "aws_secretsmanager_secret" "rds" {
  name                    = "petclinic/${var.environment}/rds-credentials"
  recovery_window_in_days = 0
  description = "RDS MySQL credentials for ${var.project}-${var.environment}"

  tags = merge(var.tags, {
    Name = "petclinic/${var.environment}/rds-credentials"
  })
}

resource "aws_secretsmanager_secret_version" "rds" {
  secret_id = aws_secretsmanager_secret.rds.id
  secret_string = jsonencode({
    username = aws_db_instance.main.username
    password = random_password.db.result
    host     = aws_db_instance.main.address
    port     = tostring(aws_db_instance.main.port)
    dbname   = aws_db_instance.main.db_name
  })
}
