"""
Update deployment manifest after Terraform apply completes.

Reads from environment variables. The cloud-neutral keys are what the verify
job reads; the Azure and AWS blocks are recorded verbatim for evidence.

  MANIFEST_PATH                   — path to deployment-manifest.json
  EDGE_HOST_NAME                  — public edge hostname the app answers on
                                    (Front Door endpoint on Azure, CloudFront
                                    domain on AWS); falls back to
                                    FRONTDOOR_ENDPOINT_HOST_NAME
  NEXTAUTH_URL                    — derived runtime public URL

  Azure (Front Door / Container Apps):
  FRONTDOOR_ENDPOINT_HOST_NAME    — terraform output value
  FRONTDOOR_PROFILE_ID            — terraform output value
  FRONTDOOR_ENDPOINT_ID           — terraform output value
  FRONTDOOR_ORIGIN_GROUP_ID       — terraform output value
  FRONTDOOR_ROUTE_ID              — terraform output value
  FRONTDOOR_CUSTOM_DOMAIN_ID      — terraform output value (optional)
  FRONTDOOR_SECRET_ID             — terraform output value (optional)
  FRONTDOOR_PRIVATE_LINK_CONNECTION_IDS — approved private endpoint connection IDs
  CONTAINER_APP_ENVIRONMENT_ID    — terraform output value
  WEB_CONTAINER_APP_NAME          — terraform output value
  PRIVATE_ENDPOINT_SUBNET_PREFIX  — terraform output value

  AWS (CloudFront / ECS), each written only when set:
  CLOUDFRONT_DISTRIBUTION_ID, ECS_CLUSTER_NAME, ALB_DNS_NAME, DB_ADDRESS,
  ARTIFACTS_BUCKET               — terraform output values

  AI_PATH_CHECKS                  — optional JSON object of validation-check
                                    name → state, written by the in-environment
                                    AI-path probe (Azure: the Foundry private
                                    DNS + managed-identity inference job; AWS:
                                    the Bedrock task-role probe). Merged into
                                    validation_checks verbatim; the verify job's
                                    evaluator refuses "healthy" while any check
                                    is not passed / not_applicable.
"""

import json
import os
from pathlib import Path

manifest = Path(os.environ["MANIFEST_PATH"])

with manifest.open() as f:
    data = json.load(f)

data["validation_checks"]["terraform_apply"] = "passed"
if os.environ.get("FRONTDOOR_PRIVATE_LINK_CONNECTION_IDS"):
    data["validation_checks"]["private_endpoint_approval"] = "passed"

ai_path_checks: dict[str, str] = {}
if os.environ.get("AI_PATH_CHECKS", "").strip():
    ai_path_checks = json.loads(os.environ["AI_PATH_CHECKS"])
    if not isinstance(ai_path_checks, dict):
        raise SystemExit("AI_PATH_CHECKS must be a JSON object of check name -> state")
    data["validation_checks"].update({str(k): str(v) for k, v in ai_path_checks.items()})

edge_host_name = os.environ.get("EDGE_HOST_NAME") or os.environ.get(
    "FRONTDOOR_ENDPOINT_HOST_NAME", ""
)

platform_context = {
    "edge_host_name": edge_host_name,
    "frontdoor_endpoint_host_name": os.environ.get("FRONTDOOR_ENDPOINT_HOST_NAME", ""),
    "nextauth_url": os.environ.get("NEXTAUTH_URL", ""),
    "frontdoor_profile_id": os.environ.get("FRONTDOOR_PROFILE_ID", ""),
    "frontdoor_endpoint_id": os.environ.get("FRONTDOOR_ENDPOINT_ID", ""),
    "frontdoor_origin_group_id": os.environ.get("FRONTDOOR_ORIGIN_GROUP_ID", ""),
    "frontdoor_route_id": os.environ.get("FRONTDOOR_ROUTE_ID", ""),
    "frontdoor_custom_domain_id": os.environ.get("FRONTDOOR_CUSTOM_DOMAIN_ID", ""),
    "frontdoor_secret_id": os.environ.get("FRONTDOOR_SECRET_ID", ""),
    "frontdoor_private_link_connection_ids": os.environ.get(
        "FRONTDOOR_PRIVATE_LINK_CONNECTION_IDS", ""
    ),
    "container_app_environment_id": os.environ.get("CONTAINER_APP_ENVIRONMENT_ID", ""),
    "web_container_app_name": os.environ.get("WEB_CONTAINER_APP_NAME", ""),
    "private_endpoint_subnet_prefix": os.environ.get("PRIVATE_ENDPOINT_SUBNET_PREFIX", ""),
}

# AWS keys are additive: absent on an Azure run, so its manifests keep their shape.
for env_name, key in (
    ("CLOUDFRONT_DISTRIBUTION_ID", "cloudfront_distribution_id"),
    ("ECS_CLUSTER_NAME", "ecs_cluster_name"),
    ("ALB_DNS_NAME", "alb_dns_name"),
    ("DB_ADDRESS", "db_address"),
    ("ARTIFACTS_BUCKET", "artifacts_bucket"),
):
    value = os.environ.get(env_name)
    if value:
        platform_context[key] = value

data["platform_context"] = platform_context

with manifest.open("w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")

print(f"Updated manifest: {manifest}")
print("  terraform_apply = passed")
if os.environ.get("FRONTDOOR_PRIVATE_LINK_CONNECTION_IDS"):
    print("  private_endpoint_approval = passed")
for name, state in ai_path_checks.items():
    print(f"  {name} = {state}")
print(f"  edge_host_name = {data['platform_context']['edge_host_name']}")
print(f"  nextauth_url = {data['platform_context']['nextauth_url']}")
