#!/usr/bin/env bash
# Copyright (c) Microsoft Corporation.
# SPDX-License-Identifier: MIT
#
# Run Copilot CLI through the ACA gateway created by step 1.

set +x
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

trap cleanup_apim_session EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

azure() {
  az "$@" --subscription "${AZURE_SUBSCRIPTION_ID}" --only-show-errors
}

main() {
  load_env
  require_command az
  require_command copilot
  require_env AZURE_SUBSCRIPTION_ID APIM_SUBSCRIPTION_ID APIM_NAME \
    OPENAI_ACCOUNT_NAME OPENAI_DEPLOYMENT_NAME

  local apim_id resource_group app_name gateway_name fqdn image state
  local configuration_endpoint model_version cli_version exit_code=0
  local verify_only=false verbose=false
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --verbose) verbose=true; shift ;;
      --verify-only) verify_only=true; shift ;;
      *) break ;;
    esac
  done
  if [[ "${verify_only}" == "true" && "$#" -ne 0 ]]; then
    echo "--verify-only cannot be combined with Copilot CLI arguments." >&2
    exit 1
  fi
  local -a copilot_args=("$@")
  apim_id="$(resolve_apim_resource_id)"
  resource_group="${apim_id#*/resourceGroups/}"
  resource_group="${resource_group%%/*}"
  app_name="${SELF_HOSTED_GATEWAY_APP_NAME:-shg-${APIM_NAME:0:20}}"
  gateway_name="${SELF_HOSTED_GATEWAY_NAME:-${app_name}}"
  if [[ ! "${gateway_name}" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    echo "Invalid self-hosted gateway name." >&2
    exit 1
  fi
  azure rest --method HEAD \
    --uri "https://management.azure.com${apim_id}/gateways/${gateway_name}/apis/self-hosted-openai?api-version=2024-05-01" \
    --output none
  state="$(azure containerapp show --resource-group "${resource_group}" \
    --name "${app_name}" --query properties.provisioningState --output tsv)"
  if [[ "${state}" != "Succeeded" ]]; then
    echo "Container App is not provisioned successfully. Run step 1 first." >&2
    exit 1
  fi
  fqdn="$(azure containerapp show --resource-group "${resource_group}" \
    --name "${app_name}" \
    --query properties.configuration.ingress.fqdn --output tsv)"
  if [[ ! "${fqdn}" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*[a-zA-Z0-9]$ ]]; then
    echo "Container App did not return a valid ingress FQDN." >&2
    exit 1
  fi
  configuration_endpoint="$(azure containerapp show \
    --resource-group "${resource_group}" --name "${app_name}" \
    --query "properties.template.containers[0].env[?name=='config.service.endpoint'].value | [0]" \
    --output tsv)"
  if [[ "${configuration_endpoint}" != "https://${APIM_NAME}.configuration.azure-api.net" ]]; then
    echo "Container App is not configured for the selected APIM instance." >&2
    exit 1
  fi
  image="$(azure containerapp show --resource-group "${resource_group}" \
    --name "${app_name}" \
    --query 'properties.template.containers[0].image' --output tsv)"
  OPENAI_MODEL_NAME="$(azure cognitiveservices account deployment show \
    --resource-group "${resource_group}" --name "${OPENAI_ACCOUNT_NAME}" \
    --deployment-name "${OPENAI_DEPLOYMENT_NAME}" \
    --query properties.model.name --output tsv)"
  model_version="$(azure cognitiveservices account deployment show \
    --resource-group "${resource_group}" --name "${OPENAI_ACCOUNT_NAME}" \
    --deployment-name "${OPENAI_DEPLOYMENT_NAME}" \
    --query properties.model.version --output tsv)"
  if [[ -z "${OPENAI_MODEL_NAME}" || -z "${model_version}" || -z "${image}" ]]; then
    echo "Deployment model, version, or gateway image was not returned." >&2
    exit 1
  fi
  if [[ "${verbose}" == "true" ]]; then
    cli_version="$(copilot --version)"
  fi
  APIM_KEY="$(get_apim_subscription_key "${apim_id}")"
  APIM_GATEWAY_URL="https://${fqdn}/self-hosted"
  configure_apim_copilot
  if ! has_copilot_stream_option ${copilot_args[@]+"${copilot_args[@]}"}; then
    copilot_args+=(--stream off)
  fi

  print_copilot_config "APIM Self-hosted Gateway" "API Key (APIM subscription)" "${verbose}"
  if [[ "${verbose}" == "true" ]]; then
    echo "   STARTED_AT_UTC               = $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo "   COPILOT_CLI_VERSION          = ${cli_version}"
    echo "   APIM_RESOURCE_ID             = ${apim_id}"
    echo "   APIM_SUBSCRIPTION_ID         = ${APIM_SUBSCRIPTION_ID}"
    echo "   API_KEY_HEADER               = Ocp-Apim-Subscription-Key (value redacted)"
    echo "   SELF_HOSTED_GATEWAY_NAME     = ${gateway_name}"
    echo "   CONTAINER_APP_NAME           = ${app_name}"
    echo "   GATEWAY_IMAGE                = ${image}"
    echo "   OPENAI_ACCOUNT_NAME          = ${OPENAI_ACCOUNT_NAME}"
    echo "   OPENAI_MODEL_VERSION         = ${model_version}"
    echo "   ROUTE                        = ACA self-hosted gateway -> Azure OpenAI (backend API key)"
    echo ""
  fi
  if [[ "${verify_only}" == "true" ]]; then
    verify_apim_key_auth || exit_code=$?
    echo "   FINISHED_AT_UTC              = $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo "   API_KEY_VERIFY_EXIT_CODE     = ${exit_code}"
    return "${exit_code}"
  fi
  echo "🚀 Copilot CLI 를 시작합니다..."
  echo ""
  copilot "${copilot_args[@]}" || exit_code=$?
  if [[ "${verbose}" == "true" ]]; then
    echo ""
    echo "   FINISHED_AT_UTC              = $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo "   COPILOT_EXIT_CODE            = ${exit_code}"
  fi
  return "${exit_code}"
}

main "$@"
