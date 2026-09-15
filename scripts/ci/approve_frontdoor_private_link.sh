#!/usr/bin/env bash
set -euo pipefail

: "${RESOURCE_GROUP_NAME:?RESOURCE_GROUP_NAME is required}"
if [[ -z "${MANAGED_ENV_ID:-}" && -z "${MANAGED_ENV_NAME:-}" ]]; then
  echo "::error::Either MANAGED_ENV_ID or MANAGED_ENV_NAME is required."
  exit 1
fi

REQUEST_DESCRIPTION="${REQUEST_DESCRIPTION:-Azure Front Door Private Link request for CNA web origin}"
MAX_ATTEMPTS="${MAX_ATTEMPTS:-30}"
SLEEP_SECONDS="${SLEEP_SECONDS:-20}"
# When "true", a run that finds no matching request exits 0 instead of failing.
# Used by the always()-guarded workflow step after a FAILED apply, where the
# origin (and therefore the request) may legitimately not exist yet.
TOLERATE_MISSING="${TOLERATE_MISSING:-false}"
MANAGED_ENV_NAME="${MANAGED_ENV_NAME:-${MANAGED_ENV_ID##*/}}"

echo "Checking Front Door private endpoint requests for managed environment: ${MANAGED_ENV_NAME}"
echo "Expected request description: ${REQUEST_DESCRIPTION}"

matching_ids=""

for ((attempt=1; attempt<=MAX_ATTEMPTS; attempt++)); do
  connections_json="$(
    az network private-endpoint-connection list \
      --name "$MANAGED_ENV_NAME" \
      --resource-group "$RESOURCE_GROUP_NAME" \
      --type Microsoft.App/managedEnvironments \
      --output json
  )"

  pending_ids="$(
    jq -r --arg desc "$REQUEST_DESCRIPTION" '
      .[]
      | select(.properties.privateLinkServiceConnectionState.description == $desc)
      | select(.properties.privateLinkServiceConnectionState.status == "Pending")
      | .id
    ' <<<"$connections_json"
  )"

  approved_existing_ids="$(
    jq -r --arg desc "$REQUEST_DESCRIPTION" '
      .[]
      | select(.properties.privateLinkServiceConnectionState.description == $desc)
      | select(.properties.privateLinkServiceConnectionState.status == "Approved")
      | .id
    ' <<<"$connections_json"
  )"

  pending_count="$(grep -cve '^[[:space:]]*$' <<<"$pending_ids" || true)"
  approved_count="$(grep -cve '^[[:space:]]*$' <<<"$approved_existing_ids" || true)"

  if [[ "$pending_count" -gt 1 ]]; then
    echo "::error::Multiple pending Front Door private endpoint requests matched description '${REQUEST_DESCRIPTION}'. Refusing ambiguous approval."
    jq -r --arg desc "$REQUEST_DESCRIPTION" '
      .[]
      | select(.properties.privateLinkServiceConnectionState.description == $desc)
      | "  \(.id) status=\(.properties.privateLinkServiceConnectionState.status)"
    ' <<<"$connections_json"
    exit 1
  fi

  if [[ "$pending_count" -eq 1 ]]; then
    matching_ids="$pending_ids"
    echo "Found one pending private endpoint connection request on attempt ${attempt}/${MAX_ATTEMPTS}."
    break
  fi

  if [[ "$approved_count" -gt 0 ]]; then
    matching_ids="$approved_existing_ids"
    echo "Found existing approved private endpoint connection request(s) on attempt ${attempt}/${MAX_ATTEMPTS}."
    break
  fi

  echo "No matching private endpoint request yet (${attempt}/${MAX_ATTEMPTS}); waiting ${SLEEP_SECONDS}s..."
  sleep "$SLEEP_SECONDS"
done

if [[ -z "$matching_ids" ]]; then
  if [[ "$TOLERATE_MISSING" == "true" ]]; then
    echo "No Front Door private endpoint connection request matched description '${REQUEST_DESCRIPTION}'; tolerated (TOLERATE_MISSING=true)."
    exit 0
  fi
  echo "::error::No Front Door private endpoint connection request matched description '${REQUEST_DESCRIPTION}'."
  exit 1
fi

approved_ids=()
while IFS= read -r connection_id; do
  [[ -z "$connection_id" ]] && continue
  status="$(
    az network private-endpoint-connection show \
      --id "$connection_id" \
      --query "properties.privateLinkServiceConnectionState.status" \
      --output tsv
  )"

  echo "Connection ${connection_id} currently reports status: ${status}"
  case "$status" in
    Approved)
      approved_ids+=("$connection_id")
      ;;
    Pending)
      az network private-endpoint-connection approve --id "$connection_id" 1>/dev/null
      approved_ids+=("$connection_id")
      echo "Approved pending connection: ${connection_id}"
      ;;
    *)
      echo "::error::Connection ${connection_id} is in unexpected state '${status}'."
      exit 1
      ;;
  esac
done <<<"$matching_ids"

for ((attempt=1; attempt<=MAX_ATTEMPTS; attempt++)); do
  pending=0
  while IFS= read -r connection_id; do
    [[ -z "$connection_id" ]] && continue
    status="$(
      az network private-endpoint-connection show \
        --id "$connection_id" \
        --query "properties.privateLinkServiceConnectionState.status" \
        --output tsv
    )"
    echo "Approval check ${attempt}/${MAX_ATTEMPTS} for ${connection_id}: ${status}"
    if [[ "$status" != "Approved" ]]; then
      pending=1
    fi
  done <<<"$(printf '%s\n' "${approved_ids[@]}")"

  if [[ "$pending" -eq 0 ]]; then
    break
  fi

  if [[ "$attempt" -lt "$MAX_ATTEMPTS" ]]; then
    sleep "$SLEEP_SECONDS"
  fi
done

for connection_id in "${approved_ids[@]}"; do
  final_status="$(
    az network private-endpoint-connection show \
      --id "$connection_id" \
      --query "properties.privateLinkServiceConnectionState.status" \
      --output tsv
  )"
  if [[ "$final_status" != "Approved" ]]; then
    echo "::error::Connection ${connection_id} did not reach Approved state. Final status: ${final_status}"
    exit 1
  fi
done

approved_ids_csv="$(IFS=,; echo "${approved_ids[*]}")"
echo "Approved Front Door private endpoint connection IDs: ${approved_ids_csv}"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    echo "approved_connection_ids=${approved_ids_csv}"
    echo "managed_environment_id=${MANAGED_ENV_ID}"
    echo "request_description=${REQUEST_DESCRIPTION}"
  } >> "$GITHUB_OUTPUT"
fi
