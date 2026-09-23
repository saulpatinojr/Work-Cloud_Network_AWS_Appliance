"""
Probe the Amazon Bedrock path from inside the ECS cluster.

210-deploy runs this as a one-off Fargate task in the same cluster, subnets and
task role — and the same api image — as cna-api ("Verify the Bedrock path from
inside the environment", saas only). It answers the two questions the
deployment manifest used to leave as `required` markers that nothing ever
flipped (the AWS twin of the Azure appliance's TODO.md → T-104):

  BEDROCK_MODEL_ACCESS     is the configured model (or inference profile)
                           enabled for this account and region? (the console
                           opt-in REVIEW.md R-005 asks a human for)
  BEDROCK_INFERENCE        does one Converse call against it succeed with the
                           task role's credentials — the exact call path
                           cna-api's bedrock engine uses?

Each result is printed as KEY=passed|failed|unverified so the workflow can read
it back from the task's CloudWatch log stream; the exit status is 0 only when
both pass. A denial that names the model ("You don't have access to the model
with the specified model ID") is the missing opt-in; any other failure leaves
model access `unverified`, which the evidence evaluator treats as not passed.

Configuration comes from the task's environment, copied from the api task
definition so the probe tests what the app is actually configured with:
  CNA_BEDROCK_INFERENCE_PROFILE_ARN  preferred, when Terraform created one;
  CNA_BEDROCK_MODEL_ID               otherwise.
"""

from __future__ import annotations

import os
import sys

# Reasoning-class models reject very small budgets; 16 is a safe floor.
MAX_TOKENS = 16


def main() -> int:
    model_id = (
        os.environ.get("CNA_BEDROCK_INFERENCE_PROFILE_ARN", "").strip()
        or os.environ.get("CNA_BEDROCK_MODEL_ID", "").strip()
    )
    results = {"BEDROCK_MODEL_ACCESS": "unverified", "BEDROCK_INFERENCE": "failed"}

    if not model_id:
        print("probe: not configured — neither CNA_BEDROCK_INFERENCE_PROFILE_ARN nor CNA_BEDROCK_MODEL_ID is set; the api task is not wired for saas.")
        results["BEDROCK_MODEL_ACCESS"] = "failed"
    else:
        try:
            import boto3
            from botocore.exceptions import BotoCoreError, ClientError

            client = boto3.client("bedrock-runtime")
            try:
                response = client.converse(
                    modelId=model_id,
                    messages=[{"role": "user", "content": [{"text": "Reply with the single word: pong"}]}],
                    inferenceConfig={"maxTokens": MAX_TOKENS},
                )
                usage = response.get("usage", {})
                print(
                    f"inference: {model_id} answered "
                    f"(stop reason {response.get('stopReason', '?')}, "
                    f"{usage.get('totalTokens', '?')} tokens)"
                )
                results["BEDROCK_MODEL_ACCESS"] = "passed"
                results["BEDROCK_INFERENCE"] = "passed"
            except ClientError as exc:
                code = exc.response.get("Error", {}).get("Code", "")
                message = exc.response.get("Error", {}).get("Message", "")
                print(f"inference: {code}: {message[:400]}")
                if code in ("AccessDeniedException", "ResourceNotFoundException") and (
                    "access to the model" in message.lower() or "model with the specified model id" in message.lower()
                ):
                    print("model-access: the model is not enabled for this account and region (REVIEW.md R-005).")
                    results["BEDROCK_MODEL_ACCESS"] = "failed"
                elif code == "AccessDeniedException":
                    print("model-access: denied by IAM (the task role cannot invoke this model) — model opt-in unverified.")
            except BotoCoreError as exc:
                print(f"inference: probe error: {type(exc).__name__}: {exc}")
        except Exception as exc:  # noqa: BLE001 — a probe reports, it never crashes silently
            print(f"probe: error: {type(exc).__name__}: {exc}")

    for key, value in results.items():
        print(f"{key}={value}")
    return 0 if all(v == "passed" for v in results.values()) else 1


if __name__ == "__main__":
    sys.exit(main())
