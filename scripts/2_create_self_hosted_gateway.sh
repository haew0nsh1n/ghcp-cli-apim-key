#!/usr/bin/env bash
# Copyright (c) Microsoft Corporation.
# SPDX-License-Identifier: MIT
#
# Deploy the gateway and PII sidecar after 0_azd_up.sh and 1_build_pii_image.sh.

set +x
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

WORK_DIR=""
cleanup() {
  if [[ -n "${WORK_DIR}" ]]; then
    rm -f "${WORK_DIR}/gateway.json" \
      "${WORK_DIR}/token-request.json" "${WORK_DIR}/app.json" \
      "${WORK_DIR}/filter-key.txt"
    rmdir "${WORK_DIR}"
  fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

azure() {
  az "$@" --subscription "${AZURE_SUBSCRIPTION_ID}"
}

main() {
  load_env
  require_command az
  require_command node
  require_command curl
  require_env AZURE_SUBSCRIPTION_ID APIM_NAME ACR_NAME ACR_PULL_IDENTITY_ID PII_FILTER_IMAGE
  if [[ ! "${APIM_NAME}" =~ ^[a-zA-Z0-9-]+$ ]]; then
    echo "APIM_NAME must contain only letters, numbers, and hyphens." >&2
    exit 1
  fi

  local apim_id resource_group location sku gateway_name app_name
  local environment_name environment_id gateway_image gateway_uri api_uri
  local environment_workload_profiles
  local login_server rules_file latest_revision ready_revision app_uri provisioning_state
  local environment_count app_count fqdn health_ready attempt response_code
  apim_id="$(azure apim list \
    --query "[?name=='${APIM_NAME}'].id | [0]" --output tsv)"
  if [[ -z "${apim_id}" ]]; then
    echo "APIM ${APIM_NAME} was not found. Run 0_azd_up.sh first." >&2
    exit 1
  fi
  resource_group="${apim_id#*/resourceGroups/}"
  resource_group="${resource_group%%/*}"
  sku="$(azure apim show --resource-group "${resource_group}" \
    --name "${APIM_NAME}" --query sku.name --output tsv)"
  if [[ "${sku}" != "Developer" && "${sku}" != "Premium" ]]; then
    echo "Self-hosted gateways require classic Developer or Premium." >&2
    exit 1
  fi
  location="$(azure apim show --resource-group "${resource_group}" \
    --name "${APIM_NAME}" --query location --output tsv)"
  app_name="${SELF_HOSTED_GATEWAY_APP_NAME:-shg-${APIM_NAME:0:20}}"
  environment_name="${SELF_HOSTED_GATEWAY_ENV_NAME:-${app_name}-env}"
  gateway_name="${SELF_HOSTED_GATEWAY_NAME:-${app_name}}"
  gateway_image="${SELF_HOSTED_GATEWAY_IMAGE:-mcr.microsoft.com/azure-api-management/gateway:v2}"
  rules_file="${PII_RULES_FILE:-${ROOT_DIR}/pii-filter/rules.json}"
  if [[ ! "${ACR_NAME}" =~ ^[a-zA-Z0-9]{5,50}$ ]]; then
    echo "Invalid ACR_NAME." >&2
    exit 1
  fi
  login_server="$(azure acr show --name "${ACR_NAME}" --query loginServer --output tsv)"

  # Validate identifiers before using them in ARM paths or JMESPath filters.
  node - "${app_name}" "${environment_name}" "${gateway_name}" \
    "${PII_FILTER_IMAGE}" "${login_server}" "${ACR_PULL_IDENTITY_ID}" "${rules_file}" <<'NODE'
const fs = require('node:fs');
const [app, environment, gateway, image, server, identity, rulesFile] = process.argv.slice(2);
if (!/^[a-z][a-z0-9-]{0,30}[a-z0-9]$/.test(app) || app.includes('--') ||
    !/^[a-zA-Z0-9][a-zA-Z0-9-]{0,58}[a-zA-Z0-9]$/.test(environment) ||
    !/^[a-zA-Z0-9][a-zA-Z0-9_-]{0,79}$/.test(gateway)) {
  console.error('Invalid gateway, Container App, or environment name.');
  process.exit(1);
}
if (!/^[a-zA-Z0-9.-]+$/.test(server) ||
    !image.startsWith(`${server}/pii-filter@sha256:`) ||
    !/\/pii-filter@sha256:[a-f0-9]{64}$/.test(image) ||
    !/^\/subscriptions\/[^/]+\/resourceGroups\/[^/]+\/providers\/Microsoft\.ManagedIdentity\/userAssignedIdentities\/[a-zA-Z0-9_-]+$/.test(identity)) {
  console.error('Invalid ACR image or pull identity. Run 1_build_pii_image.sh first.');
  process.exit(1);
}
if (!fs.existsSync(rulesFile) || fs.statSync(rulesFile).size > 131072) {
  console.error('PII_RULES_FILE must exist and be at most 128 KiB.');
  process.exit(1);
}
let rules;
try {
  rules = JSON.parse(fs.readFileSync(rulesFile, 'utf8'));
} catch {
  console.error('PII_RULES_FILE must contain valid JSON.');
  process.exit(1);
}
if (!rules || typeof rules !== 'object' ||
    typeof rules.version !== 'string' || !/^[A-Za-z0-9._-]{1,64}$/.test(rules.version) ||
    !Array.isArray(rules.rules) || rules.rules.length < 1 || rules.rules.length > 32 ||
    !rules.rules.some(rule => rule?.enabled === true)) {
  console.error('Invalid PII rules configuration.');
  process.exit(1);
}
NODE

  umask 077
  WORK_DIR="$(mktemp -d "${SCRIPT_DIR}/.self-hosted-gateway.XXXXXX")"
  node - "${WORK_DIR}" "${location}" <<'NODE'
const fs = require('node:fs');
const [dir, location] = process.argv.slice(2);
const write = (name, value) =>
  fs.writeFileSync(`${dir}/${name}.json`, JSON.stringify(value), {mode: 0o600});
write('gateway', {properties: {
  description: 'Self-hosted gateway on Azure Container Apps',
  locationData: {name: location}
}});
write('token-request', {
  keyType: 'primary',
  expiry: new Date(Date.now() + 29 * 86400000).toISOString()
});
NODE

  gateway_uri="https://management.azure.com${apim_id}/gateways/${gateway_name}"
  api_uri="https://management.azure.com${apim_id}/apis/self-hosted-openai"
  echo "Checking the Bicep-managed proxy API on ${APIM_NAME}..."
  azure rest --method GET --uri "${api_uri}?api-version=2024-05-01" \
    --output none
  azure rest --method GET \
    --uri "https://management.azure.com${apim_id}/namedValues/openai-backend-key?api-version=2024-05-01" \
    --output none
  azure rest --method POST \
    --uri "https://management.azure.com${apim_id}/namedValues/pii-filter-key/listValue?api-version=2024-05-01" \
    --query value --output tsv > "${WORK_DIR}/filter-key.txt"
  node - "${WORK_DIR}/filter-key.txt" <<'NODE'
const key = require('node:fs').readFileSync(process.argv[2], 'utf8').trim();
if (!/^[\x21-\x7e]{32,}$/.test(key)) {
  console.error('APIM did not return a valid PII filter key. Run 0_azd_up.sh first.');
  process.exit(1);
}
NODE
  echo "Registering gateway on ${APIM_NAME}..."
  azure rest --method PUT --uri "${gateway_uri}?api-version=2024-05-01" \
    --body "@${WORK_DIR}/gateway.json" --output none
  azure rest --method PUT \
    --uri "${gateway_uri}/apis/self-hosted-openai?api-version=2024-05-01" \
    --body '{}' --output none

  environment_count="$(azure containerapp env list \
    --resource-group "${resource_group}" \
    --query "length([?name=='${environment_name}'])" --output tsv)"
  if [[ "${environment_count}" == "0" ]]; then
    echo "Creating Container Apps environment ${environment_name}..."
    azure containerapp env create --name "${environment_name}" \
      --resource-group "${resource_group}" --location "${location}" \
      --enable-workload-profiles true \
      --logs-destination none --output none
  fi
  environment_id="$(azure containerapp env show --name "${environment_name}" \
    --resource-group "${resource_group}" --query id --output tsv)"
  if [[ -z "${environment_id}" ]]; then
    echo "Container Apps environment ID was not returned." >&2
    exit 1
  fi
  environment_workload_profiles="$(azure containerapp env show \
    --name "${environment_name}" --resource-group "${resource_group}" \
    --query properties.workloadProfiles --output json)"

  # Keep the generated token out of command arguments, output, and azd settings.
  azure rest --method POST \
    --uri "${gateway_uri}/generateToken?api-version=2024-05-01" \
    --body "@${WORK_DIR}/token-request.json" --query value --output tsv |
    node -e '
const fs = require("node:fs");
const [file, name, location, environmentId, image, apimName, profilesJson,
  piiImage, registryServer, pullIdentity, rulesFile] = process.argv.slice(1);
const profiles = JSON.parse(profilesJson);
if (profiles !== null && !Array.isArray(profiles)) {
  console.error("Container Apps environment returned invalid workload profiles.");
  process.exit(1);
}
const consumptionOnly = profiles === null || profiles.length === 0;
if (!consumptionOnly && !profiles.some(profile =>
  profile.name === "Consumption" && profile.workloadProfileType === "Consumption")) {
  console.error("Environment has no Consumption workload profile. Create or select an environment with a Consumption profile.");
  process.exit(1);
}
const token = fs.readFileSync(0, "utf8").trim();
if (!token || token === "null") {
  console.error("Gateway configuration token was not returned.");
  process.exit(1);
}
const expiry = JSON.parse(fs.readFileSync(
  require("node:path").join(require("node:path").dirname(file), "token-request.json"), "utf8")).expiry;
const filterKey = fs.readFileSync(
  require("node:path").join(require("node:path").dirname(file), "filter-key.txt"), "utf8").trim();
const rulesJson = fs.readFileSync(rulesFile, "utf8");
const manifest = {
  name, type: "Microsoft.App/containerApps", location,
  identity: {type: "UserAssigned", userAssignedIdentities: {[pullIdentity]: {}}},
  properties: {
    managedEnvironmentId: environmentId,
    configuration: {
      activeRevisionsMode: "Single",
      secrets: [
        {name: "gateway-token", value: `GatewayKey ${token}`},
        {name: "pii-filter-key", value: filterKey},
        {name: "pii-rules", value: rulesJson}
      ],
      registries: [{server: registryServer, identity: pullIdentity}],
      ingress: {external: true, targetPort: 8080, transport: "auto", allowInsecure: false}
    },
    template: {
      containers: [{
        name: "gateway", image,
        resources: {cpu: 1, memory: "2Gi"},
        env: [
          {name: "config.service.endpoint", value: `https://${apimName}.configuration.azure-api.net`},
          {name: "config.service.auth", secretRef: "gateway-token"},
          {name: "GATEWAY_TOKEN_EXPIRES_AT", value: expiry},
          {name: "net.server.http.forwarded.proto.enabled", value: "true"}
        ],
        probes: [{
          type: "Readiness",
          httpGet: {path: "/status-0123456789abcdef", port: 8080},
          initialDelaySeconds: 10, periodSeconds: 10
        }]
      }, {
        name: "pii-filter", image: piiImage,
        resources: {cpu: 0.5, memory: "1Gi"},
        env: [
          {name: "PII_FILTER_KEY", secretRef: "pii-filter-key"},
          {name: "PII_RULES_JSON", secretRef: "pii-rules"}
        ],
        probes: [
          {type: "Startup", httpGet: {path: "/healthz", port: 8000},
            periodSeconds: 5, failureThreshold: 30},
          {type: "Readiness", httpGet: {path: "/healthz", port: 8000}, periodSeconds: 5},
          {type: "Liveness", httpGet: {path: "/healthz", port: 8000},
            initialDelaySeconds: 30, periodSeconds: 10}
        ]
      }],
      scale: {minReplicas: 1, maxReplicas: 1}
    }
  }
};
if (consumptionOnly) {
  console.log("Using existing Consumption-only environment.");
} else {
  manifest.properties.workloadProfileName = "Consumption";
}
fs.writeFileSync(file, JSON.stringify(manifest), {mode: 0o600});
' "${WORK_DIR}/app.json" "${app_name}" "${location}" \
      "${environment_id}" "${gateway_image}" "${APIM_NAME}" \
      "${environment_workload_profiles}" "${PII_FILTER_IMAGE}" "${login_server}" \
      "${ACR_PULL_IDENTITY_ID}" "${rules_file}"

  app_count="$(azure containerapp list --resource-group "${resource_group}" \
    --query "length([?name=='${app_name}'])" --output tsv)"
  echo "Deploying ${gateway_image} to ${app_name}..."
  app_uri="https://management.azure.com/subscriptions/${AZURE_SUBSCRIPTION_ID}/resourceGroups/${resource_group}/providers/Microsoft.App/containerApps/${app_name}?api-version=2024-03-01"
  # The Container Apps YAML update path removes empty user-assigned identity objects.
  azure rest --method PUT --uri "${app_uri}" \
    --headers Content-Type=application/json --body "@${WORK_DIR}/app.json" --output none
  echo "Waiting for Container App provisioning..."
  provisioning_state=""
  for ((attempt = 1; attempt <= 60; attempt++)); do
    provisioning_state="$(azure containerapp show --name "${app_name}" \
      --resource-group "${resource_group}" --query properties.provisioningState --output tsv)"
    case "${provisioning_state}" in
      Succeeded) break ;;
      InProgress|Accepted|Creating|Updating|Provisioning) sleep 10 ;;
      *)
        echo "Container App provisioning did not succeed (${provisioning_state}). Check Container App deployment errors." >&2
        exit 1
        ;;
    esac
  done
  if [[ "${provisioning_state}" != "Succeeded" ]]; then
    echo "Container App provisioning timed out (${provisioning_state})." >&2
    exit 1
  fi
  latest_revision="$(azure containerapp show --name "${app_name}" \
    --resource-group "${resource_group}" --query properties.latestRevisionName --output tsv)"
  if [[ -z "${latest_revision}" || "${latest_revision}" == "null" || "${latest_revision}" == "None" ]]; then
    echo "Container App revision name was not returned." >&2
    exit 1
  fi
  if [[ "${app_count}" != "0" ]]; then
    azure containerapp revision restart --name "${app_name}" \
      --resource-group "${resource_group}" --revision "${latest_revision}" --output none
  fi
  ready_revision=""
  for ((attempt = 1; attempt <= 30; attempt++)); do
    ready_revision="$(azure containerapp show --name "${app_name}" \
      --resource-group "${resource_group}" --query properties.latestReadyRevisionName --output tsv)"
    if [[ "${ready_revision}" == "${latest_revision}" ]]; then
      break
    fi
    sleep 10
  done
  if [[ "${ready_revision}" != "${latest_revision}" ]]; then
    echo "Gateway/PII sidecar revision did not become ready. Check rules, identity and image." >&2
    exit 1
  fi
  fqdn="$(azure containerapp show --name "${app_name}" \
    --resource-group "${resource_group}" \
    --query properties.configuration.ingress.fqdn --output tsv)"
  if [[ -z "${fqdn}" ]]; then
    echo "Container App ingress FQDN was not returned." >&2
    exit 1
  fi
  health_ready=false
  for ((attempt = 1; attempt <= 30; attempt++)); do
    if curl --fail --silent --show-error --max-time 10 --output /dev/null \
      "https://${fqdn}/status-0123456789abcdef"; then
      health_ready=true
      break
    fi
    sleep 10
  done
  if [[ "${health_ready}" != "true" ]]; then
    echo "Gateway health check failed. Inspect Container App logs." >&2
    exit 1
  fi
  # A healthy process can still be downloading its initial API configuration.
  for ((attempt = 1; attempt <= 30; attempt++)); do
    response_code="$(curl --silent --show-error --max-time 30 \
      --output /dev/null --write-out '%{http_code}' --request POST \
      --header 'Content-Type: application/json' --data '{}' \
      "https://${fqdn}/self-hosted/openai/chat/completions")"
    if [[ "${response_code}" != "404" && "${response_code}" != "503" ]]; then
      break
    fi
    sleep 10
  done
  if [[ "${response_code}" != "401" ]]; then
    echo "Expected unauthenticated proxy response 401, got ${response_code}." >&2
    exit 1
  fi
  echo "Gateway is healthy; unauthenticated API requests are rejected (401)."
  echo "SELF_HOSTED_GATEWAY_URL=https://${fqdn}/self-hosted"
  echo "Rerun this script before the configuration token expires in 29 days."
}

main "$@"
