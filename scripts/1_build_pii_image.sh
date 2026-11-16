#!/usr/bin/env bash
# Copyright (c) Microsoft Corporation.
# SPDX-License-Identifier: MIT

set +x
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

main() {
  load_env
  require_command az
  require_command node
  require_env AZURE_SUBSCRIPTION_ID ACR_NAME
  if [[ ! "${ACR_NAME}" =~ ^[a-zA-Z0-9]{5,50}$ ]]; then
    echo "Invalid ACR_NAME." >&2
    exit 1
  fi

  local login_server tag digest image
  login_server="$(az acr show --name "${ACR_NAME}" \
    --subscription "${AZURE_SUBSCRIPTION_ID}" --query loginServer --output tsv)"
  if [[ -z "${login_server}" || "${login_server}" == "null" ]]; then
    echo "Registry login server was not returned. Run 0_azd_up.sh first." >&2
    exit 1
  fi
  tag="$(date -u +%Y%m%d%H%M%S)-$(node -e 'console.log(require("node:crypto").randomBytes(4).toString("hex"))')"
  echo "Building the PII sidecar in ACR ${ACR_NAME}..."
  az acr build --registry "${ACR_NAME}" \
    --subscription "${AZURE_SUBSCRIPTION_ID}" \
    --image "pii-filter:${tag}" --platform linux/amd64 "${ROOT_DIR}/pii-filter"
  digest="$(az acr repository show --name "${ACR_NAME}" \
    --subscription "${AZURE_SUBSCRIPTION_ID}" --image "pii-filter:${tag}" \
    --query digest --output tsv)"
  if [[ ! "${digest}" =~ ^sha256:[a-f0-9]{64}$ ]]; then
    echo "ACR did not return a valid PII image digest." >&2
    exit 1
  fi
  image="${login_server}/pii-filter@${digest}"
  if command -v azd >/dev/null 2>&1; then
    if [[ -n "${AZURE_ENV_NAME:-}" ]]; then
      azd env set PII_FILTER_IMAGE "${image}" --environment "${AZURE_ENV_NAME}"
    else
      azd env set PII_FILTER_IMAGE "${image}"
    fi
  fi
  echo "PII_FILTER_IMAGE=${image}"
  echo "Image build completed. Run 2_create_self_hosted_gateway.sh to deploy it."
}

main "$@"
