# =============================================================================
# Database — RDS for PostgreSQL (source: migrate/rds.tf). Mirrors the Azure
# PostgreSQL Flexible Server module.
# =============================================================================

data "aws_partition" "current" {}

# Enhanced monitoring publishes OS-level metrics through a service role that
# RDS assumes; created only when a monitoring interval is set.
resource "aws_iam_role" "monitoring" {
  count = var.monitoring_interval > 0 ? 1 : 0
  name  = "${var.name_prefix}-rds-monitoring"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "monitoring.rds.amazonaws.com" }
    }]
  })

  tags = merge(var.tags, { Name = "${var.name_prefix}-rds-monitoring" })
}

resource "aws_iam_role_policy_attachment" "monitoring" {
  count      = var.monitoring_interval > 0 ? 1 : 0
  role       = aws_iam_role.monitoring[0].name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}

resource "aws_db_subnet_group" "this" {
  name       = local.subnet_group_name
  subnet_ids = var.subnet_ids

  tags = merge(var.tags, { Name = local.subnet_group_name })
}

resource "aws_db_instance" "this" {
  identifier = local.instance_identifier

  engine         = "postgres"
  engine_version = var.postgres_major_version
  instance_class = var.instance_class

  allocated_storage     = var.allocated_storage_gb
  max_allocated_storage = var.allocated_storage_gb * 2
  storage_type          = "gp3"
  storage_encrypted     = var.storage_encrypted
  kms_key_id            = var.kms_key_id

  db_name  = var.db_name
  username = var.admin_username
  password = var.admin_password
  port     = 5432

  multi_az               = var.multi_az
  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = var.security_group_ids
  publicly_accessible    = false

  backup_retention_period = var.backup_retention_days
  backup_window           = "03:00-04:00"
  maintenance_window      = "sun:04:30-sun:05:30"

  deletion_protection       = var.deletion_protection
  skip_final_snapshot       = var.skip_final_snapshot
  final_snapshot_identifier = var.skip_final_snapshot ? null : "${local.instance_identifier}-final"

  enabled_cloudwatch_logs_exports = ["postgresql"]
  auto_minor_version_upgrade      = true
  copy_tags_to_snapshot           = true

  # Observability and credential-free auth — each environment-driven because
  # each carries a cost or behaviour trade-off (T-111).
  performance_insights_enabled          = var.performance_insights_enabled
  performance_insights_kms_key_id       = var.performance_insights_enabled ? var.kms_key_id : null
  performance_insights_retention_period = var.performance_insights_enabled ? var.performance_insights_retention_days : null
  monitoring_interval                   = var.monitoring_interval
  monitoring_role_arn                   = var.monitoring_interval > 0 ? aws_iam_role.monitoring[0].arn : null
  iam_database_authentication_enabled   = var.iam_database_authentication_enabled

  tags = merge(var.tags, { Name = local.instance_identifier })

  lifecycle {
    ignore_changes = [password]
  }
}
