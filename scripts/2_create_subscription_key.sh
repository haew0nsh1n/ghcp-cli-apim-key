#!/usr/bin/env bash
# Copyright (c) Microsoft Corporation.
# SPDX-License-Identifier: MIT
#
# Usage: ./scripts/2_create_subscription_key.sh [count] [id-prefix] [display-name]
#
# Examples:
#   ./scripts/2_create_subscription_key.sh
#     Creates one subscription: copilot-cli-<UUID>
#     Display name: Copilot CLI copilot-cli-<UUID>
#   ./scripts/2_create_subscription_key.sh 3
#     Creates copilot-cli-<UUID>-1, copilot-cli-<UUID>-2, copilot-cli-<UUID>-3.
#   ./scripts/2_create_subscription_key.sh 3 dev
#     Creates dev-1, dev-2, dev-3.
#   ./scripts/2_create_subscription_key.sh 1 dev-01 "Developer 01"
#     Creates dev-01 with display name "Developer 01".
# Each subscription has its own APIM-generated primary/secondary key pair.
# Key values are not printed.

set +x
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

azure() {
  az "$@" --subscription "${AZURE_SUBSCRIPTION_ID}"
}

main() {
  if [[ "$#" -gt 3 ]]; then
    echo "Usage: $0 [count] [id-prefix] [display-name]" >&2
    exit 1
  fi
  local count="${1-1}"
  if [[ ! "${count}" =~ ^[1-9][0-9]*$ ]]; then
    echo "Count must be a positive integer." >&2
    exit 1
  fi
  require_command node
  node -e '
if (!Number.isSafeInteger(Number(process.argv[1]))) {
  console.error("Count exceeds the supported integer range.");
  process.exit(1);
}
' "${count}"

  local prefix="${2-}"
  if [[ "$#" -lt 2 ]]; then
    prefix="$(node -e 'console.log("copilot-cli-" + require("node:crypto").randomUUID())')"
  fi
  local display_prefix="${3-Copilot CLI ${prefix}}"
  local subscription_id display_name index
  local -a subscription_ids=() display_names=()
  for ((index = 1; index <= count; index++)); do
    subscription_id="${prefix}"
    display_name="${display_prefix}"
    if ((count > 1)); then
      subscription_id="${prefix}-${index}"
      display_name="${display_prefix} ${index}"
    fi
    if [[ ! "${prefix}" =~ ^[a-zA-Z0-9._-]+$ ||
      "${#subscription_id}" -gt 256 ]]; then
      echo "Each subscription ID must be 1-256 letters, numbers, dots, underscores or hyphens." >&2
      exit 1
    fi
    if [[ -z "${display_prefix}" || "${#display_name}" -gt 100 ]]; then
      echo "Each display name must contain 1-100 characters." >&2
      exit 1
    fi
    subscription_ids+=("${subscription_id}")
    display_names+=("${display_name}")
  done

  load_env
  require_command az
  require_env AZURE_SUBSCRIPTION_ID APIM_NAME

  local apim_id product_id collection_uri subscription_uri next_uri page exists body result
  apim_id="$(resolve_apim_resource_id)"
  product_id="${apim_id}/products/copilot-cli"
  collection_uri="https://management.azure.com${apim_id}/subscriptions"
  azure rest --method GET \
    --uri "https://management.azure.com${product_id}?api-version=2024-05-01" \
    --output none

  for subscription_id in "${subscription_ids[@]}"; do
    next_uri="${collection_uri}?api-version=2024-05-01"
    while [[ -n "${next_uri}" ]]; do
      page="$(azure rest --method GET --uri "${next_uri}" \
        --query "{exists: length(value[?name=='${subscription_id}']), nextLink: nextLink}" \
        --output json |
        node -e '
const fs = require("node:fs");
const page = JSON.parse(fs.readFileSync(0, "utf8"));
if (!Number.isInteger(page.exists) || page.exists < 0 ||
    !(page.nextLink == null || (typeof page.nextLink === "string" &&
      !/[\r\n]/.test(page.nextLink)))) {
  console.error("APIM returned an invalid subscription listing.");
  process.exit(1);
}
process.stdout.write(`${page.exists}\n${page.nextLink || "-"}`);
')"
      exists="${page%%$'\n'*}"
      if [[ "${exists}" != "0" ]]; then
        echo "APIM subscription ${subscription_id} already exists. No changes were made." >&2
        exit 1
      fi
      next_uri="${page#*$'\n'}"
      if [[ "${next_uri}" == "-" ]]; then
        next_uri=""
      fi
      if [[ -n "${next_uri}" && "${next_uri}" != "${collection_uri}?"* ]]; then
        echo "APIM returned an unexpected subscription pagination URL." >&2
        exit 1
      fi
    done
  done

  for ((index = 0; index < count; index++)); do
    subscription_id="${subscription_ids[index]}"
    display_name="${display_names[index]}"
    subscription_uri="${collection_uri}/${subscription_id}?api-version=2024-05-01"
    body="$(node - "${display_name}" "${product_id}" <<'NODE'
console.log(JSON.stringify({properties: {
  displayName: process.argv[2],
  scope: process.argv[3],
  state: 'active',
  allowTracing: false
}}));
NODE
)"
    azure rest --method PUT --uri "${subscription_uri}" \
      --headers Content-Type=application/json --body "${body}" --output none
    result="$(azure rest --method GET --uri "${subscription_uri}" \
      --query '{state: properties.state, scope: properties.scope}' --output json)"
    printf '%s' "${result}" | node -e '
const fs = require("node:fs");
const result = JSON.parse(fs.readFileSync(0, "utf8"));
if (result.state !== "active" || result.scope !== process.argv[1]) {
  console.error("Created subscription is not active in the expected Product.");
  process.exit(1);
}
' "${product_id}"

    echo "APIM subscription created and verified."
    echo "APIM_SUBSCRIPTION_ID=${subscription_id}"
  done
  echo "CREATED_SUBSCRIPTION_COUNT=${count}"
  echo "PRODUCT_ID=${product_id}"
  echo "Primary and secondary keys were generated by APIM. Key values are not printed."
  echo "Wait for gateway configuration synchronization before calling the API."
}

main "$@"
