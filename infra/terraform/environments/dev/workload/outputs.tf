output "ecs_cluster_name" {
  description = "ECS cluster name."
  value       = module.compute.cluster_name
}

output "alb_dns_name" {
  description = "ALB DNS name."
  value       = module.compute.alb_dns_name
}

output "cloudfront_domain_name" {
  description = "CloudFront distribution domain name."
  value       = module.security.cloudfront_domain_name
}

output "cloudfront_distribution_id" {
  description = "CloudFront distribution ID."
  value       = module.security.cloudfront_distribution_id
}

output "kms_key_arn" {
  description = "Customer-managed KMS key ARN."
  value       = module.identity.kms_key_arn
}

output "task_role_arn" {
  description = "ECS task role ARN (application identity)."
  value       = module.identity.task_role_arn
}

output "github_deploy_role_arn" {
  description = "GitHub Actions OIDC deploy role ARN."
  value       = module.identity.github_deploy_role_arn
}

output "db_address" {
  description = "RDS instance hostname."
  value       = module.database.address
}

output "db_name" {
  description = "Initial database name."
  value       = module.database.db_name
}

output "artifacts_bucket" {
  description = "Artifacts S3 bucket name."
  value       = module.storage.artifacts_bucket_id
}

output "ai_mode" {
  description = "AI provisioning mode this workload was applied with (saas | byo-api). Recorded in the deployment manifest so image updates preserve it."
  value       = var.ai_mode
}

output "logs_bucket" {
  description = "Edge access-log S3 bucket name (CloudFront standard logs). Emptied by 330 before destroy."
  value       = module.storage.logs_bucket_id
}

output "waf_log_group_name" {
  description = "WAF web-ACL CloudWatch log group (us-east-1), or null when edge logging is disabled."
  value       = module.security.waf_log_group_name
}
