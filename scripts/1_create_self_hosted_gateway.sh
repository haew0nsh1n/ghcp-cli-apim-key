#!/usr/bin/env bash
# Copyright (c) Microsoft Corporation.
# SPDX-License-Identifier: MIT
#
# Deploy an APIM self-hosted gateway to Azure Container Apps after 0_azd_up.sh.

set +x
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

WORK_DIR=""
cleanup() {
  if [[ -n "${WORK_DIR}" ]]; then
    rm -f "${WORK_DIR}/gateway.json" \
      "${WORK_DIR}/token-request.json" "${WORK_DIR}/app.json"
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
  require_env AZURE_SUBSCRIPTION_ID APIM_NAME
  if [[ ! "${APIM_NAME}" =~ ^[a-zA-Z0-9-]+$ ]]; then
    echo "APIM_NAME must contain only letters, numbers, and hyphens." >&2
    exit 1
  fi

  local apim_id resource_group location sku gateway_name app_name
  local environment_name environment_id gateway_image gateway_uri api_uri
  local environment_workload_profiles
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

  # Validate identifiers before using them in ARM paths or JMESPath filters.
  node - "${app_name}" "${environment_name}" "${gateway_name}" <<'NODE'
const [app, environment, gateway] = process.argv.slice(2);
if (!/^[a-z][a-z0-9-]{0,30}[a-z0-9]$/.test(app) || app.includes('--') ||
    !/^[a-zA-Z0-9][a-zA-Z0-9-]{0,58}[a-zA-Z0-9]$/.test(environment) ||
    !/^[a-zA-Z0-9][a-zA-Z0-9_-]{0,79}$/.test(gateway)) {
  console.error('Invalid gateway, Container App, or environment name.');
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
const [file, name, location, environmentId, image, apimName, profilesJson] = process.argv.slice(1);
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
const manifest = {
  name, type: "Microsoft.App/containerApps", location,
  properties: {
    managedEnvironmentId: environmentId,
    configuration: {
      activeRevisionsMode: "Single",
      secrets: [{name: "gateway-token", value: `GatewayKey ${token}`}],
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
      "${environment_workload_profiles}"

  app_count="$(azure containerapp list --resource-group "${resource_group}" \
    --query "length([?name=='${app_name}'])" --output tsv)"
  echo "Deploying ${gateway_image} to ${app_name}..."
  if [[ "${app_count}" == "0" ]]; then
    azure containerapp create --name "${app_name}" \
      --resource-group "${resource_group}" --yaml "${WORK_DIR}/app.json" \
      --output none
  else
    azure containerapp update --name "${app_name}" \
      --resource-group "${resource_group}" --yaml "${WORK_DIR}/app.json" \
      --output none
    azure containerapp revision restart --name "${app_name}" \
      --resource-group "${resource_group}" --revision \
      "$(azure containerapp show --name "${app_name}" \
        --resource-group "${resource_group}" \
        --query properties.latestRevisionName --output tsv)" --output none
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
