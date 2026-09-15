locals {
  # Region is embedded in the foundation-model ARN; account is omitted because
  # foundation models are AWS-owned (arn:...:bedrock:<region>::foundation-model/<id>).
  foundation_model_arns = [
    for m in var.model_ids :
    "arn:${data.aws_partition.current.partition}:bedrock:${data.aws_region.current.name}::foundation-model/${m}"
  ]

  # The primary chat model ARN (first in the list) — used by inference profile
  # and provisioned throughput resources.
  chat_model_arn = local.foundation_model_arns[0]

  # Inference profile name follows the Azure deployment naming convention:
  # a stable, human-readable name the app references.
  inference_profile_name = "${var.name_prefix}-${var.chat_profile_name}"

  # All ARNs that the task role should be allowed to invoke:
  # foundation models + any provisioned throughput ARN + inference profile ARN.
  provisioned_arns = var.enable_provisioned_throughput ? [
    "arn:${data.aws_partition.current.partition}:bedrock:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:provisioned-model/${var.name_prefix}-chat-pmt"
  ] : []

  inference_profile_arns = var.enable_inference_profile ? [
    "arn:${data.aws_partition.current.partition}:bedrock:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:inference-profile/${local.inference_profile_name}"
  ] : []

  all_invocable_arns = concat(
    local.foundation_model_arns,
    local.provisioned_arns,
    local.inference_profile_arns,
  )
}
