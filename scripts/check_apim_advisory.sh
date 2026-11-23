#!/usr/bin/env bash
# Copyright (c) Microsoft Corporation.
# SPDX-License-Identifier: MIT

set +x
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

usage() {
  cat <<'TEXT'
Usage: check_apim_advisory.sh [--subscription ID_OR_NAME ... | --all]
                              [--tracking-id ID] [--json]
Defaults: current Azure subscription; tracking ID MZK9-GH0.
Requires: az login, jq, and permissions to read APIM and advisory impacted resources.
Shows APIM information and advisory status in a table; --json returns the detailed report.
Table output is followed by credential metadata reads and non-executing rotation guidance.
Diagnostics go to stderr. No Azure configuration is changed.
Exit codes: 0 = queries completed (not proof of safety), 1 = setup/input failure,
            2 = one or more checks incomplete.
TEXT
}

tracking_id="MZK9-GH0"
all=false
json_output=false
selectors=()
while (($#)); do
  case "$1" in
    --subscription|--tracking-id)
      if (($# < 2)) || [[ -z "$2" || "$2" == --* ]]; then
        echo "Missing value for $1." >&2
        exit 1
      fi
      if [[ "$1" == "--subscription" ]]; then
        selectors+=("$2")
      else
        tracking_id="$2"
      fi
      shift 2
      ;;
    --all) all=true; shift ;;
    --json) json_output=true; shift ;;
    --help|-h) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 1 ;;
  esac
done
if [[ ! "$tracking_id" =~ ^[a-zA-Z0-9._-]+$ ]] ||
  { [[ "$all" == true ]] && ((${#selectors[@]})); }; then
  echo "Invalid tracking ID or conflicting --all and --subscription options." >&2
  exit 1
fi
require_command az
require_command jq

umask 077
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/apim-advisory.XXXXXX")"
trap 'rm -f "${work_dir}/subscriptions.json" "${work_dir}/reports.jsonl" "${work_dir}/resources.jsonl" "${work_dir}/query-error.txt"; rmdir "${work_dir}"' EXIT
account_query='{id:id, name:name, tenantId:tenantId, state:state}'
if [[ "$all" == true ]]; then
  az account list --all --query "[?state=='Enabled'].${account_query}" \
    --output json >"${work_dir}/subscriptions.json"
elif ((${#selectors[@]})); then
  for selector in "${selectors[@]}"; do
    az account show --subscription "$selector" --query "$account_query" --output json
  done | jq -s 'unique_by(.id)' >"${work_dir}/subscriptions.json"
else
  az account show --query "$account_query" --output json |
    jq '[.]' >"${work_dir}/subscriptions.json"
fi
jq -e 'type == "array" and length > 0 and all(.[];
  (.id | type == "string" and test("^[a-zA-Z0-9-]+$")) and
  (.name | type == "string") and (.state | type == "string"))' \
  "${work_dir}/subscriptions.json" >/dev/null || {
  echo "No valid accessible Azure subscriptions were returned." >&2
  exit 1
}

# Only accept pagination within the original ARM collection.
pages() {
  local subscription="$1" uri="$2" method="$3" query="$4"
  local collection="${2%%\?*}" page next_uri seen=""
  local items='[]'
  : >"${work_dir}/query-error.txt"
  while [[ -n "$uri" ]]; do
    if [[ "$uri" != "$collection?"* || "$uri" == *$'\n'* ||
      "$uri" == *$'\r'* || "$seen" == *"|${uri}|"* ]]; then
      echo "Invalid or repeated pagination URL for subscription $subscription." >&2
      return 1
    fi
    seen+="|${uri}|"
    if ! page="$(az rest --subscription "$subscription" --method "$method" \
      --uri "$uri" --query "$query" --output json 2>"${work_dir}/query-error.txt")"; then
      cat "${work_dir}/query-error.txt" >&2
      echo "Collection query failed for subscription $subscription." >&2
      return 1
    fi
    cat "${work_dir}/query-error.txt" >&2
    : >"${work_dir}/query-error.txt"
    if ! jq -e 'type == "object" and (.value | type == "array") and
      (.nextLink == null or (.nextLink | type == "string"))' <<<"$page" >/dev/null; then
      echo "Invalid collection response for subscription $subscription." >&2
      return 1
    fi
    items="$(jq -cn --argjson previous "$items" --argjson page "$page" \
      '$previous + $page.value')"
    next_uri="$(jq -r '.nextLink // empty' <<<"$page")"
    uri="$next_uri"
    method="GET"
  done
  printf '%s\n' "$items"
}

read_rotation_metadata() {
  local subscription="$1" base="$2" path="$3"
  local items
  echo "   ${path}:"
  if ! items="$(pages "$subscription" "${base}/${path}?api-version=2024-05-01" \
    GET '{nextLink:nextLink, value:value[].{name:name}}')"; then
    if [[ -s "${work_dir}/query-error.txt" ]]; then
      cat "${work_dir}/query-error.txt"
    else
      echo "   목록 조회 실패"
    fi
    exit_code=2
    return
  fi
  if ! jq -e 'all(.[]; (.name | type == "string"))' <<<"$items" >/dev/null; then
    echo "Invalid metadata response for ${path} in subscription ${subscription}." >&2
    echo "   목록 응답 형식 오류"
    exit_code=2
    return
  fi
  jq -r 'if length == 0 then "   없음" else .[] | "   - \(.name)" end' <<<"$items"
  if [[ "$path" == "apis" ]]; then
    local api api_path
    while IFS= read -r api; do
      api_path="$(jq -rn --arg name "$api" '$name | @uri')"
      read_rotation_metadata "$subscription" "$base" "apis/${api_path}/policies"
    done < <(jq -r '.[].name' <<<"$items")
  fi
}

print_rotation_flow() {
  local subscription resource_id name path
  echo ""
  echo "키 회전 작업 흐름 (조회만 실행: 재발급·갱신·삭제는 실행하지 않음)"
  echo "영향 목록 조회 결과는 위 테이블입니다. 아래에서는 사용처 메타데이터 조회와 수동 회전 안내를 구분합니다."
  echo "공지 원문과 영향 범위를 확인하고, 비운영 환경 검증 및 승인 후 별도로 수행하세요."
  echo "공통 순서: 발급처에서 새 자격 증명 생성 → APIM 반영 → API 테스트 → 기존 자격 증명 폐기"
  echo "APIM 값만 변경하면 발급처의 기존 자격 증명이 무효화되지 않습니다."
  echo "실제 실행 시 비밀 값을 명령 인수·셸 기록·로그에 노출하지 않도록 보호하세요."

  # {base}: https://management.azure.com/subscriptions/{subscriptionId}/resourceGroups/{rg}/providers/Microsoft.ApiManagement/service/{apimName}
  echo ""
  echo "1. 대상·사용처 확인 (실제 조회)"
  echo "   APIM 구독, Backend, 인증 공급자, Logger, Global·API 정책의 이름 목록을 조회합니다."
  while IFS=$'\t' read -r subscription resource_id name; do
    echo ""
    echo "   [APIM: ${name} / 구독: ${subscription}]"
    echo "   namedValues (기존 조회 결과):"
    jq -r --arg id "$resource_id" '
      .apim[] | select(.id == $id) | .namedValues |
      if .status != "COMPLETE" then "   기존 Named Values 조회 실패"
      elif (.items | length) == 0 then "   없음"
      else .items[] | "   - \(.name)" end
    ' "${work_dir}/reports.jsonl"
    for path in subscriptions backends authorizationServers openidConnectProviders \
      identityProviders authorizationProviders loggers policies apis; do
      read_rotation_metadata "$subscription" "https://management.azure.com${resource_id}" "$path"
    done
  done < <(jq -r '.subscription.id as $subscription | .apim[] |
    [$subscription, .id, .name] | @tsv' "${work_dir}/reports.jsonl")
  echo ""
  echo "   이름 목록 조회만으로 자격 증명 존재·유출·회전 완료를 판정하지 않습니다."
  echo "   Product·Operation 정책과 정책 본문의 직접 작성 자격 증명은 별도로 확인하세요."
  echo "   비밀 값 조회가 필요한 경우에만 승인된 보안 환경에서 확인하고, 임시 출력은 안전하게 폐기합니다."
  # az rest --method post --url "{base}/subscriptions/{sid}/listSecrets?api-version=2024-05-01"
  # az apim nv show-secret --resource-group "{rg}" --service-name "{apimName}" --named-value-id "{namedValueId}"

  echo ""
  echo "2. APIM 구독 키"
  echo "   호출자를 Secondary로 전환 → Primary 재발급 → 새 Primary로 전환·테스트 → Secondary 재발급"
  # az rest --method post --url "{base}/subscriptions/{sid}/regeneratePrimaryKey?api-version=2024-05-01"
  # az rest --method post --url "{base}/subscriptions/{sid}/regenerateSecondaryKey?api-version=2024-05-01"

  echo ""
  echo "3. Named Values"
  echo "   Key Vault 참조: 발급처에서 교체 → Key Vault 저장 → 버전 고정 참조 갱신 → APIM 새로 고침·테스트 → 기존 자격 증명 폐기"
  # az rest --method post --url "{base}/namedValues/{namedValueId}/refreshSecret?api-version=2024-05-01"
  echo "   직접 저장: 발급처에서 교체 → APIM 값 갱신·테스트 → 기존 자격 증명 폐기; Key Vault 참조 전환도 검토합니다."
  # az apim nv update --resource-group "{rg}" --service-name "{apimName}" --named-value-id "{namedValueId}" --value "{newValue}"

  echo ""
  echo "4. Backend 자격 증명"
  echo "   Backend에서 새 키·인증서를 준비 → APIM 헤더·쿼리·인증서 설정 갱신 → 테스트 → 기존 자격 증명 폐기"
  echo "   아래 PATCH 예시는 자격 증명이 하나인 Backend용입니다. 현재 ETag와 나머지 설정을 보존해야 합니다."
  # az rest --method patch --url "{base}/backends/{backendId}?api-version=2024-05-01" --headers "If-Match={etag}" --body '{"properties":{"credentials":{"header":{"{headerName}":["{newKey}"]}}}}'

  echo ""
  echo "5. OAuth 2.0·OpenID Connect·인증 공급자"
  echo "   발급처에서 새 Client Secret 추가 → APIM 갱신 → 사용 중인 Developer Portal 재게시·테스트 → 기존 Secret 삭제"
  echo "   Microsoft Entra ID 예시는 --append로 기존 자격 증명을 유지한 채 새 자격 증명을 추가합니다."
  # az ad app credential reset --id "{appId}" --append --display-name "apim-rotation"
  # az ad app credential delete --id "{appId}" --key-id "{oldKeyId}"

  echo ""
  echo "6. Logger 연결 문자열"
  echo "   Event Hubs: Logger를 Secondary 연결 문자열로 전환 → 로그 수신 확인 → Namespace 규칙의 Primary 키 재발급"
  # az eventhubs namespace authorization-rule keys renew --resource-group "{rg}" --namespace-name "{namespace}" --name "{ruleName}" --key PrimaryKey
  echo "   Application Insights 등 다른 Logger는 발급처와 인증 방식에 맞춰 별도 검토합니다."

  echo ""
  echo "7. 정책에 직접 작성한 자격 증명"
  echo "   Global·Product·API·Operation 정책 확인 → 발급처에서 교체 → Key Vault Named Value 참조로 변경·테스트 → 기존 자격 증명 폐기"
  echo "   Global·API 정책 이름은 1단계에서 조회합니다. 비밀 값이 포함될 수 있는 정책 원문은 출력하지 않습니다."

  echo ""
  echo "8. Legacy Direct Management API 키"
  echo "   사용하는 경우에만 각 키의 호출자를 먼저 전환한 뒤 해당 키를 재발급합니다."
  # az rest --method post --url "{base}/tenant/access/regeneratePrimaryKey?api-version=2024-05-01"
  # az rest --method post --url "{base}/tenant/access/regenerateSecondaryKey?api-version=2024-05-01"

  echo ""
  echo "9. 최종 검증"
  echo "   새 자격 증명으로 정상 호출·Gateway 설정 동기화·로그 수신을 확인하고, 기존 자격 증명이 거절되는지 확인합니다."
  echo "   이 스크립트는 위 작업의 실행 여부나 회전 완료를 판정하지 않습니다."
  echo "공식 가이드: https://techcommunity.microsoft.com/blog/integrationsonazureblog/rotating-credentials-in-azure-api-management/4575478"
}

service_query='{nextLink:nextLink, value:value[].{id:id, name:name, location:location, sku:sku.name, virtualNetworkType:properties.virtualNetworkType, publicNetworkAccess:properties.publicNetworkAccess, privateEndpointCount:length(properties.privateEndpointConnections || `[]`)}}'
advisory_query='{nextLink:nextLink, value:value[].{targetResourceId:properties.targetResourceId, infoResourceIds:properties.info[?starts_with(to_string(value), `/`)].value}}'
named_query='{nextLink:nextLink, value:value[].{name:name, secret:properties.secret, keyVaultSecretIdentifier:properties.keyVault.secretIdentifier}}'
exit_code=0
: >"${work_dir}/reports.jsonl"
while IFS= read -r subscription; do
  sub_id="$(jq -r '.id' <<<"$subscription")"
  if [[ "$json_output" == true ]]; then
    echo "Checking Azure subscription $sub_id..." >&2
  fi
  base="https://management.azure.com/subscriptions/${sub_id}"
  errors='[]'
  advisory_status="COMPLETE"
  advisory_error=""
  inventory_status="COMPLETE"
  inventory_error=""
  services='[]'
  advisory='[]'
  if [[ "$(jq -r '.state' <<<"$subscription")" != "Enabled" ]]; then
    inventory_status="UNKNOWN"
    advisory_status="UNKNOWN"
    errors='["SUBSCRIPTION_NOT_ENABLED"]'
    echo "Subscription $sub_id is not enabled; checks skipped." >&2
  else
    if ! services="$(pages "$sub_id" \
      "${base}/providers/Microsoft.ApiManagement/service?api-version=2024-05-01" \
      GET "$service_query")"; then
      inventory_status="UNKNOWN"
      inventory_error="$(<"${work_dir}/query-error.txt")"
      services='[]'
      errors="$(jq -c '. + ["APIM_INVENTORY_QUERY_FAILED"]' <<<"$errors")"
    elif ! jq -e --arg prefix "${base#https://management.azure.com}/resourceGroups/" \
      'all(.[]; (.id | type == "string" and
        (ascii_downcase | startswith($prefix | ascii_downcase)) and
        test("/providers/Microsoft.ApiManagement/service/[^/]+$"; "i")))' \
      <<<"$services" >/dev/null; then
      inventory_status="UNKNOWN"
      services='[]'
      errors="$(jq -c '. + ["INVALID_APIM_INVENTORY"]' <<<"$errors")"
      echo "Invalid APIM resource IDs in subscription $sub_id." >&2
    fi
    if ! advisory="$(pages "$sub_id" \
      "${base}/providers/Microsoft.ResourceHealth/events/${tracking_id}/listSecurityAdvisoryImpactedResources?api-version=2026-07-01" \
      POST "$advisory_query")"; then
      advisory_status="UNKNOWN"
      advisory_error="$(<"${work_dir}/query-error.txt")"
      advisory='[]'
      errors="$(jq -c '. + ["ADVISORY_QUERY_FAILED"]' <<<"$errors")"
    elif ! jq -e 'all(.[]; type == "object" and
      (.targetResourceId == null or (.targetResourceId | type == "string")) and
      (.infoResourceIds == null or (.infoResourceIds |
        type == "array" and all(.[]; type == "string"))))' <<<"$advisory" >/dev/null; then
      advisory_status="UNKNOWN"
      advisory='[]'
      errors="$(jq -c '. + ["INVALID_ADVISORY_RESPONSE"]' <<<"$errors")"
      echo "Invalid advisory records in subscription $sub_id." >&2
    fi
  fi

  # Security advisories can encode resource IDs in properties.info instead of targetResourceId.
  advisory="$(jq -c '[.[] | {
    resourceIds: ([.targetResourceId, (.infoResourceIds // [])[]] |
      map(select(type == "string") | select(test("^/subscriptions/[^/]+/"; "i")) |
        ascii_downcase) | unique)
  }]' <<<"$advisory")"
  unmapped="$(jq '[.[] | select(.resourceIds | length == 0)] | length' <<<"$advisory")"
  : >"${work_dir}/resources.jsonl"
  while IFS= read -r service; do
    resource_id="$(jq -r '.id' <<<"$service")"
    named_status="COMPLETE"
    if ! named_values="$(pages "$sub_id" \
      "https://management.azure.com${resource_id}/namedValues?api-version=2024-05-01" \
      GET "$named_query")"; then
      named_status="UNKNOWN"
      named_values='[]'
      errors="$(jq -c --arg id "$resource_id" '. + ["NAMED_VALUES_QUERY_FAILED: " + $id]' <<<"$errors")"
    elif ! jq -e 'all(.[]; type == "object" and
      (.name | type == "string") and (.secret | type == "boolean") and
      (.keyVaultSecretIdentifier == null or
        (.keyVaultSecretIdentifier | type == "string")))' <<<"$named_values" >/dev/null; then
      named_status="UNKNOWN"
      named_values='[]'
      errors="$(jq -c --arg id "$resource_id" '. + ["INVALID_NAMED_VALUES_RESPONSE: " + $id]' <<<"$errors")"
      echo "Invalid Named Values metadata for $resource_id." >&2
    fi
    jq -cn --argjson service "$service" --argjson advisory "$advisory" \
      --arg status "$advisory_status" --argjson unmapped "$unmapped" \
      --arg advisoryError "$advisory_error" \
      --arg namedStatus "$named_status" --argjson namedValues "$named_values" '
      ($service.id | ascii_downcase) as $id |
      ([$advisory[] | select(.resourceIds | index($id))] | length) as $matches |
      $service + {
        resourceGroup: ($service.id | split("/")[4]),
        advisory: {
          status: (if $status == "UNKNOWN" then "UNKNOWN"
            elif $matches > 0 then "LISTED"
            elif $unmapped > 0 then "UNKNOWN_RESOURCE_MAPPING"
            else "NOT_LISTED_IN_RETURNED_RECORDS" end),
          error: (if $advisoryError == "" then null else $advisoryError end),
          matchingRecordCount: (if $status == "UNKNOWN" then null else $matches end)
        },
        namedValues: {
          status: $namedStatus,
          items: (if $namedStatus == "UNKNOWN" then null else
            [$namedValues[] | {
              name, secret, keyVaultReferenced: ((.keyVaultSecretIdentifier // "") != ""),
              directSecret: (.secret == true and ((.keyVaultSecretIdentifier // "") == ""))
            }] end)
        }
      }' >>"${work_dir}/resources.jsonl"
  done < <(jq -c '.[]' <<<"$services")
  if [[ "$unmapped" -gt 0 ]]; then
    errors="$(jq -c '. + ["ADVISORY_RESOURCE_MAPPING_INCOMPLETE"]' <<<"$errors")"
    echo "Some advisory records have no recognizable resource ID in subscription $sub_id." >&2
  fi
  if [[ "$(jq 'length' <<<"$errors")" -gt 0 ]]; then
    exit_code=2
  fi
  jq -s --argjson subscription "$subscription" --arg inventory "$inventory_status" \
    --arg advisoryStatus "$advisory_status" --argjson advisory "$advisory" \
    --arg advisoryError "$advisory_error" --arg inventoryError "$inventory_error" \
    --argjson unmapped "$unmapped" --argjson errors "$errors" '
    {
      subscription: $subscription,
      inventoryStatus: $inventory,
      inventoryError: (if $inventoryError == "" then null else $inventoryError end),
      apimCount: (if $inventory == "UNKNOWN" then null else length end),
      advisory: {
        status: $advisoryStatus,
        error: (if $advisoryError == "" then null else $advisoryError end),
        totalReturned: (if $advisoryStatus == "UNKNOWN" then null else ($advisory | length) end),
        unmappedRecordCount: (if $advisoryStatus == "UNKNOWN" then null else $unmapped end)
      },
      apim: ., errors: $errors
    }' "${work_dir}/resources.jsonl" >>"${work_dir}/reports.jsonl"
done < <(jq -c '.[]' "${work_dir}/subscriptions.json")

if [[ "$json_output" == true ]]; then
  jq -s --arg trackingId "$tracking_id" --arg checkedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --argjson exitCode "$exit_code" '{
    trackingId: $trackingId, checkedAt: $checkedAt,
    status: (if $exitCode == 0 then "COMPLETE" else "INCOMPLETE" end),
    subscriptions: .,
    warnings: [
      "NOT_LISTED is not proof of no exposure. Confirm advisory visibility and scope in Azure Service Health.",
      "Current network settings and resource inventory do not establish historical incident impact.",
      "Named Values metadata is not a complete credential inventory. No secret values are requested or printed.",
      "Only subscriptions accessible in the Azure CLI account cache are checked; --all selects enabled subscriptions.",
      "No Azure configuration changes or credential rotations are performed."
    ]
  }' "${work_dir}/reports.jsonl"
else
  jq -rs --arg trackingId "$tracking_id" '
    def table:
      map(map(gsub("\r"; "\\r") | gsub("\n"; "\\n"))) |
      . as $rows |
      [range(0; ($rows[0] | length)) as $column |
        [$rows[] | .[$column] | length] | max] as $widths |
      ($rows[0], ($widths | map("-" * .)), $rows[1:][]) |
      to_entries |
      map(.key as $column |
        .value + (" " * ($widths[$column] - (.value | length)))) |
      join("  ") | sub(" +$"; "");
    "공지: \($trackingId)",
    (.[] |
      .subscription.id as $subscriptionId |
      "\n[구독: \(.subscription.name)]",
      (if .inventoryStatus == "UNKNOWN" then
        (.inventoryError // "APIM 목록 확인 불가")
      elif (.apim | length) == 0 then
        "APIM 없음",
        (if .advisory.status == "UNKNOWN" then
          (.advisory.error // "영향 목록 확인 불가") else empty end)
      else
        ([["Name", "ResourceGroup", "SubscriptionId", "Location", "SKU", "Advisory"]] +
          [.apim[] | [
            (.name // (.id | split("/") | last)),
            .resourceGroup, $subscriptionId, (.location // "-"), (.sku // "-"),
            (.advisory.error // (if .advisory.status == "NOT_LISTED_IN_RETURNED_RECORDS" then "NOT_LISTED"
            elif .advisory.status == "UNKNOWN_RESOURCE_MAPPING" then "UNKNOWN"
            else .advisory.status end))
          ]] | table)
      end),
      (if any(.apim[]; .namedValues.status == "UNKNOWN") then
        "추가 구성 점검 불완전 (오류 로그 확인)"
      else empty end)
    )
  ' "${work_dir}/reports.jsonl"
  print_rotation_flow
fi
exit "$exit_code"
