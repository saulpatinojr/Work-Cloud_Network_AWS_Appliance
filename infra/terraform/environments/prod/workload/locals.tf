locals {
  name_prefix = "${var.project_name}-${var.environment}-${var.region_short}"
  tags = {
    Environment = title(var.environment)
    CostCenter  = "CNA"
    Owner       = "cna-platform"
    Project     = var.project_name
    ManagedBy   = "terraform"
  }

  # ── AI mode ─────────────────────────────────────────────────────────────────
  ai_saas = var.ai_mode == "saas"

  # Mode-independent runtime contract, injected into all three services. The
  # app resolves its engine family from these (apps/cna-web/lib/ai-engine-rules.ts,
  # cna/ai_engine/chat_agent.py).
  ai_mode_env_vars = {
    CNA_AI_MODE           = var.ai_mode
    CNA_APPLIANCE_CLOUD   = "aws"
    CNA_AI_ENGINE_DEFAULT = var.ai_engine_default
  }

  # saas-only env. Bedrock Converse accepts a model ARN or an inference-profile
  # ARN as modelId; the app prefers the profile when present (stable routing,
  # billed through the profile) and falls back to the model ARN.
  bedrock_inference_profile_arn = one(module.ai[*].inference_profile_arn)
  bedrock_env_vars = local.ai_saas ? {
    CNA_BEDROCK_MODEL_ID              = one(module.ai[*].chat_model_arn)
    CNA_BEDROCK_INFERENCE_PROFILE_ARN = local.bedrock_inference_profile_arn != null ? local.bedrock_inference_profile_arn : ""
  } : {}
}
