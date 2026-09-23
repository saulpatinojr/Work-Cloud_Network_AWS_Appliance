output "artifacts_bucket_id" {
  description = "Name (ID) of the artifacts S3 bucket. Passed to compute as CNA_STORAGE_BUCKET."
  value       = aws_s3_bucket.artifacts.id
}

output "artifacts_bucket_arn" {
  description = "ARN of the artifacts S3 bucket."
  value       = aws_s3_bucket.artifacts.arn
}

output "static_site_bucket_id" {
  description = "Name (ID) of the static-site S3 bucket. Passed to the security module for the CloudFront OAC bucket policy."
  value       = aws_s3_bucket.static_site.id
}

output "static_site_bucket_arn" {
  description = "ARN of the static-site S3 bucket. Passed to the security module for the CloudFront OAC bucket policy."
  value       = aws_s3_bucket.static_site.arn
}

output "logs_bucket_id" {
  description = "Name (ID) of the edge access-log bucket. Passed to 330 for emptying before destroy."
  value       = aws_s3_bucket.logs.id
}

output "logs_bucket_arn" {
  description = "ARN of the edge access-log bucket."
  value       = aws_s3_bucket.logs.arn
}

output "logs_bucket_domain_name" {
  description = "Bucket domain name of the edge access-log bucket (<bucket>.s3.amazonaws.com, the form CloudFront logging_config takes). Passed to the security module; ready only once ACLs are enabled on the bucket, which CloudFront checks when the distribution is created."
  value       = aws_s3_bucket.logs.bucket_domain_name

  depends_on = [
    aws_s3_bucket_ownership_controls.logs,
    aws_s3_bucket_public_access_block.logs,
  ]
}
