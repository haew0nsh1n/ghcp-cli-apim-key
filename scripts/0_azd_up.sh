#!/usr/bin/env bash
# Copyright (c) Microsoft Corporation.
# SPDX-License-Identifier: MIT
#
# Usage: ./scripts/0_azd_up.sh [azd up options]

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

main() {
  local env_file="${ROOT_DIR}/.env"
  local -a environment_args=()
  local -a args=("$@")
  local index

  require_command azd
  cd "${ROOT_DIR}"

  if [[ ! -f "${env_file}" ]]; then
    echo "Missing ${env_file}. Copy .env.example to .env and configure it." >&2
    exit 1
  fi

  for ((index = 0; index < ${#args[@]}; index++)); do
    case "${args[index]}" in
      -e|--environment)
        if ((index + 1 >= ${#args[@]})) ||
          [[ -z "${args[index + 1]}" || "${args[index + 1]}" == -* ]]; then
          echo "${args[index]} requires an environment name." >&2
          exit 1
        fi
        environment_args=(--environment "${args[index + 1]}")
        index=$((index + 1))
        ;;
      --environment=*)
        if [[ -z "${args[index]#*=}" ]]; then
          echo "--environment requires an environment name." >&2
          exit 1
        fi
        environment_args=(--environment "${args[index]#*=}")
        ;;
    esac
  done

  azd env set --file "${env_file}" ${environment_args[@]+"${environment_args[@]}"}
  exec azd up "$@"
}

main "$@"
