#!/usr/bin/env bash
# Detects whether an Azure Landing Zone (ALZ) governance policy already manages
# diagnostic settings on the target subscription via a DeployIfNotExists (DINE)
# effect. ALZ deployments assign a "Deploy diagnostic settings" initiative
# (commonly named Deploy-Diag-Logs) at a management-group scope ABOVE the
# subscription. That policy auto-creates a "setByPolicy-*" diagnostic setting on
# every supported resource the instant it is created, and races any
# Terraform-managed diagnostic setting on the same resource — which the azurerm
# provider surfaces as a false "already exists / needs import" error mid-apply.
#
# Rather than fight org-owned governance (which is not ours to remove on a
# customer ALZ), we DETECT it and tell Terraform to stand down: this writes
# `manage_diagnostic_settings=false` to GITHUB_OUTPUT so the deploy workflow can
# export TF_VAR_manage_diagnostic_settings=false. Logs still flow — to the
# centrally governed workspace the policy targets.
#
# Detection is non-fatal and fail-safe: any error, or no policy found, defaults
# to manage_diagnostic_settings=true (Terraform manages diagnostics), preserving
# behaviour on non-ALZ subscriptions.
#
# IMPORTANT: ALZ diagnostics policies are assigned at MANAGEMENT GROUP scope, not
# the subscription. `az policy assignment list --scope <sub>` does NOT return
# inherited MG assignments, so we walk the subscription's MG ancestor chain.
#
# Required env:
#   AZURE_SUBSCRIPTION_ID  — target subscription (defaults to current az context)
# Optional env:
#   GITHUB_OUTPUT          — when set, the decision is written here
#   GITHUB_STEP_SUMMARY    — when set, a human-readable note is appended here
set -euo pipefail

# Disable MSYS path mangling so /subscriptions/... and /providers/... scopes
# survive intact when this ever runs under Git Bash on Windows.
export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL="*"

SUBSCRIPTION_ID="${AZURE_SUBSCRIPTION_ID:-$(az account show --query id -o tsv 2>/dev/null || echo "")}"

emit_decision() {
  local value="$1"
  [[ -n "${GITHUB_OUTPUT:-}" ]] && echo "manage_diagnostic_settings=${value}" >> "$GITHUB_OUTPUT"
  echo "Decision: manage_diagnostic_settings=${value}"
}

if [[ -z "$SUBSCRIPTION_ID" ]]; then
  echo "::warning::Could not resolve subscription; defaulting to manage_diagnostic_settings=true"
  emit_decision "true"
  exit 0
fi

echo "Scanning policy assignments governing subscription ${SUBSCRIPTION_ID} for ALZ diagnostic-settings (DeployIfNotExists)..."

# Build the list of scopes to check: the subscription itself, plus every
# management-group ancestor up to the tenant root.
SCOPES=("/subscriptions/${SUBSCRIPTION_ID}")

# Find the immediate parent MG of the subscription, then walk upward.
# managementGroups/{mg}?$expand=ancestors returns the full ancestor chain.
PARENT_MG="$(az rest --method get \
  --url "https://management.azure.com/providers/Microsoft.Management/managementGroups?api-version=2020-05-01&\$filter=children/any(c: c/name eq '${SUBSCRIPTION_ID}')" \
  --query "value[0].name" -o tsv 2>/dev/null || echo "")"

# Fallback: derive parent via the subscription's own management-group membership.
if [[ -z "$PARENT_MG" ]]; then
  PARENT_MG="$(az rest --method get \
    --url "https://management.azure.com/providers/Microsoft.Management/managementGroups/?api-version=2020-05-01" \
    --query "value[].name" -o tsv 2>/dev/null | while read -r mg; do
      if az rest --method get \
        --url "https://management.azure.com/providers/Microsoft.Management/managementGroups/${mg}/descendants?api-version=2020-05-01" \
        --query "value[?name=='${SUBSCRIPTION_ID}'] | [0].name" -o tsv 2>/dev/null | grep -q "${SUBSCRIPTION_ID}"; then
        echo "$mg"; break
      fi
    done || echo "")"
fi

# Walk the ancestor chain via the ancestors expansion on the parent MG.
if [[ -n "$PARENT_MG" ]]; then
  ANCESTORS="$(az rest --method get \
    --url "https://management.azure.com/providers/Microsoft.Management/managementGroups/${PARENT_MG}?api-version=2020-05-01&\$expand=ancestors" \
    --query "[properties.details.parent.name, properties.name] | []" -o tsv 2>/dev/null || echo "")"
  # Always include the direct parent, then any ancestors we can resolve.
  for mg in "$PARENT_MG" $ANCESTORS; do
    [[ -n "$mg" ]] && SCOPES+=("/providers/Microsoft.Management/managementGroups/${mg}")
  done
fi

# As a comprehensive backstop, also scan every MG the runner identity can see.
# On an ALZ the diagnostics initiative lives on a platform/intermediate MG, so a
# breadth scan guarantees we find it even if ancestor resolution is incomplete.
while read -r mg; do
  [[ -n "$mg" ]] && SCOPES+=("/providers/Microsoft.Management/managementGroups/${mg}")
done < <(az account management-group list --query "[].name" -o tsv 2>/dev/null || true)

# De-duplicate scopes.
readarray -t SCOPES < <(printf '%s\n' "${SCOPES[@]}" | awk '!seen[$0]++')

# An ALZ diagnostics assignment is recognised by the assignment name or its
# policy definition id matching the well-known "Deploy-Diag" / diagnostic-logs
# pattern. We match on the assignment NAME (fast, no per-definition lookups),
# which on ALZ is consistently "Deploy-Diag-Logs" (and variants).
DIAG_NAME_PATTERN='[Dd]eploy.*[Dd]iag|[Dd]iagnostic.*[Ll]og|setByPolicy'

DETECTED="false"
DETECTED_WHERE=""
DETECTED_NAME=""

for scope in "${SCOPES[@]}"; do
  # Pull assignment name + definition id pairs at this scope.
  MATCH="$(az policy assignment list --scope "$scope" \
    --query "[].{n:name, d:policyDefinitionId, dn:displayName}" -o tsv 2>/dev/null \
    | grep -iE "$DIAG_NAME_PATTERN" | head -1 || true)"
  if [[ -n "$MATCH" ]]; then
    DETECTED="true"
    DETECTED_WHERE="$scope"
    DETECTED_NAME="$(echo "$MATCH" | cut -f1)"
    break
  fi
done

# When an ALZ DeployIfNotExists policy is detected, Terraform STANDS DOWN by
# default: the policy owns diagnostic settings, so we emit `false` and the module
# skips its own settings entirely (policy-only diagnostics, logs still flow to the
# centrally governed workspace). This is the correct behaviour on a governed ALZ —
# trying to "dual-ship" a second, uniquely-named setting races the policy's
# remediation and the azurerm provider surfaces it as a false "already exists /
# needs import" error mid-apply (no stabilization delay reliably avoids this,
# e.g. when the firewall itself takes 10+ minutes to create).
#
# An operator can opt Terraform BACK IN (manage its own settings alongside the
# policy) by setting the repo/environment variable ALZ_DIAGNOSTICS_MANAGE=true —
# only do this when shipping to a different workspace than the policy targets and
# you have accepted the create-race risk.
MANAGE_OVERRIDE="${ALZ_DIAGNOSTICS_MANAGE:-false}"

if [[ "$DETECTED" == "true" ]]; then
  if [[ "$MANAGE_OVERRIDE" == "true" ]]; then
    echo "::warning::ALZ diagnostic-settings policy '${DETECTED_NAME}' detected at ${DETECTED_WHERE}; ALZ_DIAGNOSTICS_MANAGE=true -> Terraform will manage its own settings alongside the policy (create-race risk accepted)."
    DECISION="true"
    TF_STATE="enabled (operator opt-in alongside policy)"
  else
    echo "::warning::ALZ diagnostic-settings policy '${DETECTED_NAME}' detected at ${DETECTED_WHERE}. Terraform diagnostic settings DISABLED by default (policy owns diagnostics). Set ALZ_DIAGNOSTICS_MANAGE=true to manage them in Terraform anyway."
    DECISION="false"
    TF_STATE="disabled (policy owns diagnostics)"
  fi
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    {
      echo "## Diagnostic settings governance"
      echo ""
      echo "⚠️ An **Azure Landing Zone DeployIfNotExists policy** governs diagnostic settings for this subscription."
      echo ""
      echo "| | |"
      echo "|---|---|"
      echo "| Terraform-managed diagnostics | **${TF_STATE}** |"
      echo "| Detected assignment | \`${DETECTED_NAME}\` |"
      echo "| Scope | \`${DETECTED_WHERE}\` |"
      echo "| Behaviour | Terraform stands down by default; the policy's \`setByPolicy-*\` settings own diagnostics (logs flow to the centrally governed workspace). |"
      echo "| Override | Set \`ALZ_DIAGNOSTICS_MANAGE=true\` to have Terraform manage its own settings alongside the policy (create-race risk). |"
    } >> "$GITHUB_STEP_SUMMARY"
  fi
  emit_decision "$DECISION"
else
  echo "No ALZ diagnostic-settings policy detected across ${#SCOPES[@]} scope(s). Terraform manages diagnostic settings normally."
  emit_decision "true"
fi
