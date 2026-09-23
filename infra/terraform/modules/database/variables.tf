variable "name_prefix" {
  description = "Normalized name prefix for database resources (e.g. cna-dev-use1)"
  type        = string
}

variable "tags" {
  description = "Tags applied to database resources"
  type        = map(string)
  default     = {}
  nullable    = false
}

variable "subnet_ids" {
  description = "Database subnet IDs (from the platform networking) for the DB subnet group."
  type        = list(string)
  nullable    = false
}

variable "security_group_ids" {
  description = "Security group IDs (from the platform networking) attached to the RDS instance."
  type        = list(string)
  nullable    = false
}

variable "db_name" {
  description = "Initial database name."
  type        = string
  default     = "cna"
}

variable "admin_username" {
  description = "Master username for the PostgreSQL instance."
  type        = string
  default     = "cnaadmin"
}

variable "admin_password" {
  description = "Master password for the PostgreSQL instance."
  type        = string
  sensitive   = true
}

variable "instance_class" {
  description = "RDS instance class."
  type        = string
  default     = "db.t4g.small"
}

variable "allocated_storage_gb" {
  description = "Initial allocated storage in GB. max_allocated_storage is set to twice this for storage autoscaling."
  type        = number
  default     = 20
}

variable "postgres_major_version" {
  description = "PostgreSQL MAJOR version only (e.g. \"16\"). AWS selects the latest supported minor; auto_minor_version_upgrade keeps it current."
  type        = string
  default     = "16"
}

variable "multi_az" {
  description = "Enable Multi-AZ for the RDS instance. Enabled in prod, disabled in dev."
  type        = bool
  default     = false
}

variable "backup_retention_days" {
  description = "Automated backup retention in days."
  type        = number
  default     = 7
}

variable "deletion_protection" {
  description = "Prevent accidental deletion of the RDS instance. Enabled in prod, disabled in dev."
  type        = bool
  default     = false
}

variable "skip_final_snapshot" {
  description = "Skip the final snapshot on destroy. True in dev, false in prod."
  type        = bool
  default     = true
}

variable "storage_encrypted" {
  description = "Encrypt RDS storage at rest with the customer-managed KMS key."
  type        = bool
  default     = true
}

variable "kms_key_id" {
  description = "ARN of the customer-managed KMS key (from the identity module) used for storage encryption. Null falls back to the default aws/rds key."
  type        = string
  default     = null
}

variable "performance_insights_enabled" {
  description = "Enable RDS Performance Insights (encrypted with kms_key_id). Adds cost beyond the 7-day free retention tier; typically on for prod."
  type        = bool
  default     = false
}

variable "performance_insights_retention_days" {
  description = "Performance Insights retention in days: 7 (free tier) or a multiple of 31 up to 731."
  type        = number
  default     = 7

  validation {
    condition     = var.performance_insights_retention_days == 7 || (var.performance_insights_retention_days % 31 == 0 && var.performance_insights_retention_days <= 731)
    error_message = "performance_insights_retention_days must be 7 or a multiple of 31 no greater than 731."
  }
}

variable "monitoring_interval" {
  description = "Enhanced-monitoring interval in seconds (0 disables it and creates no monitoring role). Publishes OS metrics to CloudWatch at extra cost; typically 60 for prod."
  type        = number
  default     = 0

  validation {
    condition     = contains([0, 1, 5, 10, 15, 30, 60], var.monitoring_interval)
    error_message = "monitoring_interval must be one of 0, 1, 5, 10, 15, 30 or 60."
  }
}

variable "iam_database_authentication_enabled" {
  description = "Allow IAM-token authentication to PostgreSQL alongside the password. The application connects with DATABASE_URL today, so this is off unless a credential-free client is introduced."
  type        = bool
  default     = false
}
