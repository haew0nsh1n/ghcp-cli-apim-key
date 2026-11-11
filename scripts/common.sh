#!/usr/bin/env bash
# Copyright (c) Microsoft Corporation.
# SPDX-License-Identifier: MIT

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

load_env() {
  if [[ -z "${AZURE_ENV_NAME:-}" && -f "${ROOT_DIR}/.env" ]]; then
    set -a
    # shellcheck disable=SC1091
    source "${ROOT_DIR}/.env"
    set +a
  fi
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Required command not found: $1" >&2
    exit 1
  fi
}

require_env() {
  local name
  local azd_value
  for name in "$@"; do
    if [[ -z "${!name:-}" ]] && command -v azd >/dev/null 2>&1; then
      azd_value=""
      if ! azd_value="$(azd env get-value "${name}" 2>/dev/null)"; then
        azd_value=""
      fi
      if [[ -n "${azd_value}" ]]; then
        printf -v "${name}" '%s' "${azd_value}"
        export "${name}"
      fi
    fi
    if [[ -z "${!name:-}" ]]; then
      echo "Required environment variable is not set: ${name}" >&2
      exit 1
    fi
  done
}

resolve_apim_resource_id() {
  require_env AZURE_SUBSCRIPTION_ID APIM_NAME
  local apim_id
  if [[ ! "${APIM_NAME}" =~ ^[a-zA-Z0-9-]+$ ]]; then
    echo "Invalid APIM_NAME." >&2
    return 1
  fi
  apim_id="$(az apim list --subscription "${AZURE_SUBSCRIPTION_ID}" \
    --query "[?name=='${APIM_NAME}'].id | [0]" --output tsv)"
  if [[ -z "${apim_id}" ]]; then
    echo "APIM ${APIM_NAME} was not found. Run 0_azd_up.sh first." >&2
    return 1
  fi
  printf '%s' "${apim_id}"
}

get_apim_subscription_key() {
  require_env AZURE_SUBSCRIPTION_ID APIM_SUBSCRIPTION_ID
  local apim_id="${1:-}"
  local state key uri
  if [[ ! "${APIM_SUBSCRIPTION_ID}" =~ ^[a-zA-Z0-9._-]+$ ]]; then
    echo "Invalid APIM_SUBSCRIPTION_ID." >&2
    return 1
  fi
  if [[ -z "${apim_id}" ]]; then
    apim_id="$(resolve_apim_resource_id)"
  fi
  uri="https://management.azure.com${apim_id}/subscriptions/${APIM_SUBSCRIPTION_ID}"
  state="$(az rest --method GET --uri "${uri}?api-version=2024-05-01" \
    --subscription "${AZURE_SUBSCRIPTION_ID}" \
    --query properties.state --output tsv)"
  if [[ "${state}" != "active" ]]; then
    echo "APIM subscription is not active. Redeploy or activate it first." >&2
    return 1
  fi
  key="$(az rest --method POST \
    --uri "${uri}/listSecrets?api-version=2024-05-01" \
    --subscription "${AZURE_SUBSCRIPTION_ID}" --query primaryKey --output tsv)"
  if [[ -z "${key}" || "${key}" == "null" || "${key}" == "None" ||
    "${key}" == *$'\r'* || "${key}" == *$'\n'* ]]; then
    echo "APIM did not return a valid subscription key." >&2
    return 1
  fi
  printf '%s' "${key}"
}

cleanup_apim_session() {
  unset APIM_KEY COPILOT_PROVIDER_API_KEY COPILOT_PROVIDER_HEADERS \
    COPILOT_PROVIDER_BEARER_TOKEN
  if [[ -n "${APIM_VERIFY_DIR:-}" ]]; then
    rm -f "${APIM_VERIFY_DIR}/response.json"
    rmdir "${APIM_VERIFY_DIR}"
    unset APIM_VERIFY_DIR
  fi
}

configure_apim_copilot() {
  local provider_help
  if [[ -z "${APIM_KEY:-}" ]]; then
    echo "An APIM subscription key is required." >&2
    exit 1
  fi
  provider_help="$(copilot help environment)"
  if [[ "${provider_help}" != *"COPILOT_PROVIDER_HEADERS"* ]]; then
    echo "This Copilot CLI must support COPILOT_PROVIDER_HEADERS. Update it first." >&2
    exit 1
  fi
  unset COPILOT_PROVIDER_BEARER_TOKEN COPILOT_PROVIDER_API_KEY_COMMAND \
    COPILOT_PROVIDER_AZURE_API_VERSION
  export COPILOT_OFFLINE="true"
  export COPILOT_PROVIDER_BASE_URL="${APIM_GATEWAY_URL%/}/openai"
  export COPILOT_PROVIDER_TYPE="openai"
  export COPILOT_PROVIDER_API_KEY="${APIM_KEY}"
  export COPILOT_PROVIDER_HEADERS="Ocp-Apim-Subscription-Key: ${APIM_KEY}"
  export COPILOT_PROVIDER_WIRE_API="completions"
  export COPILOT_MODEL="${OPENAI_MODEL_NAME}"
  export COPILOT_PROVIDER_MODEL_ID="${OPENAI_MODEL_NAME}"
  export COPILOT_PROVIDER_WIRE_MODEL="${OPENAI_DEPLOYMENT_NAME}"
  export COPILOT_PROVIDER_MAX_PROMPT_TOKENS="${COPILOT_PROVIDER_MAX_PROMPT_TOKENS:-32768}"
  export COPILOT_PROVIDER_MAX_OUTPUT_TOKENS="${COPILOT_PROVIDER_MAX_OUTPUT_TOKENS:-4096}"
}

print_copilot_config() {
  local destination="$1"
  local auth_label="$2"
  local show_details="${3:-true}"

  echo "🔗 Copilot CLI BYOK (OFFLINE_MODE → ${destination}) 구성 완료"
  echo "   COPILOT_OFFLINE              = ${COPILOT_OFFLINE}"
  echo "   COPILOT_PROVIDER_TYPE        = ${COPILOT_PROVIDER_TYPE}"
  echo "   COPILOT_PROVIDER_BASE_URL    = ${COPILOT_PROVIDER_BASE_URL}"
  echo "   COPILOT_PROVIDER_WIRE_API    = ${COPILOT_PROVIDER_WIRE_API:-completions}"
  echo "   AUTH                         = ${auth_label}"
  if [[ "${show_details}" == "true" && -n "${COPILOT_PROVIDER_AZURE_API_VERSION:-}" ]]; then
    echo "   COPILOT_PROVIDER_AZURE_API_VERSION = ${COPILOT_PROVIDER_AZURE_API_VERSION}"
  fi
  if [[ -n "${COPILOT_MODEL:-}" ]]; then
    echo "   COPILOT_MODEL                = ${COPILOT_MODEL}"
  fi
  if [[ "${show_details}" == "true" && -n "${COPILOT_PROVIDER_MODEL_ID:-}" ]]; then
    echo "   COPILOT_PROVIDER_MODEL_ID    = ${COPILOT_PROVIDER_MODEL_ID}"
  fi
  if [[ "${show_details}" == "true" && -n "${COPILOT_PROVIDER_WIRE_MODEL:-}" ]]; then
    echo "   COPILOT_PROVIDER_WIRE_MODEL  = ${COPILOT_PROVIDER_WIRE_MODEL}"
  fi
  if [[ "${show_details}" == "true" && -n "${COPILOT_PROVIDER_MAX_PROMPT_TOKENS:-}" ]]; then
    echo "   COPILOT_PROVIDER_MAX_PROMPT_TOKENS = ${COPILOT_PROVIDER_MAX_PROMPT_TOKENS}"
  fi
  if [[ "${show_details}" == "true" && -n "${COPILOT_PROVIDER_MAX_OUTPUT_TOKENS:-}" ]]; then
    echo "   COPILOT_PROVIDER_MAX_OUTPUT_TOKENS = ${COPILOT_PROVIDER_MAX_OUTPUT_TOKENS}"
  fi
  echo ""
}

apim_key_curl_header() {
  local key="$1"
  key="${key//\\/\\\\}"
  key="${key//\"/\\\"}"
  printf 'header = "Ocp-Apim-Subscription-Key: %s"\n' "${key}"
}

verify_apim_key_auth() {
  require_command curl
  require_command node
  local scenario key response_code expected_code
  umask 077
  APIM_VERIFY_DIR="$(mktemp -d "${ROOT_DIR}/scripts/.api-key-check.XXXXXX")"
  for scenario in missing invalid valid; do
    key=""
    expected_code="401"
    if [[ "${scenario}" == "invalid" ]]; then
      key="invalid-subscription-key"
    elif [[ "${scenario}" == "valid" ]]; then
      key="${APIM_KEY}"
      expected_code="200"
    fi
    response_code="$(
      if [[ -n "${key}" ]]; then apim_key_curl_header "${key}"; fi |
        curl --config - --silent --show-error --max-time 120 \
          --output "${APIM_VERIFY_DIR}/response.json" \
          --write-out '%{http_code}' --request POST \
          --header 'Content-Type: application/json' \
          --data '{"messages":[{"role":"user","content":"Reply with OK."}],"max_completion_tokens":256,"reasoning_effort":"minimal","stream":false}' \
          "${COPILOT_PROVIDER_BASE_URL}/chat/completions"
    )"
    printf '   API_KEY_CHECK %-7s = HTTP %s\n' "${scenario}" "${response_code}"
    if [[ "${response_code}" != "${expected_code}" ]]; then
      echo "API key check failed: expected ${expected_code} for ${scenario}." >&2
      return 1
    fi
  done
  node - "${APIM_VERIFY_DIR}/response.json" <<'NODE'
const fs = require('node:fs');
let response;
try {
  response = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
} catch {
  console.error('API key check failed: response is not valid JSON.');
  process.exit(1);
}
if (!Array.isArray(response.choices) || !response.choices.length ||
    response.choices[0].message?.role !== 'assistant' ||
    !Number.isInteger(response.usage?.total_tokens) ||
    response.usage.total_tokens < 0) {
  console.error('API key check failed: expected chat completion and usage.');
  process.exit(1);
}
console.log('   API_KEY_CHECK response = chat completion with usage');
NODE
}

has_copilot_stream_option() {
  local arg
  for arg in "$@"; do
    if [[ "${arg}" == "--stream" || "${arg}" == --stream=* ]]; then
      return 0
    fi
  done
  return 1
}
