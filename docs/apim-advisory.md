---
title: APIM 보안 공지와 구독별 점검
description: MZK9-GH0 추적 ID를 기준으로 Azure 구독별 APIM 영향 목록과 자격 증명 메타데이터 점검
ms.date: 2026-11-22
---

## 대상 이슈와 확인 상태

[점검 스크립트](../scripts/check_apim_advisory.sh)는 Azure Service Health 추적 ID `MZK9-GH0`를 기본값으로 사용합니다.
다른 공지를 점검하려면 `--tracking-id`로 바꾸세요.

2026-11-22 기준으로 이번 조사에서는 해당 ID의 공식 공지 원문을 공개 자료에서 확인하지 못했습니다.
발생 시각, 원인, 영향 SKU·지역, 유출 여부, Microsoft의 조치 완료 여부는 미확인입니다.
다른 APIM CVE나 장애와 동일한 사건이라고 단정하지 않습니다.
구독에 로그인한 뒤 Azure Portal의 Service Health > Security advisories 또는 Health history에서
추적 ID를 찾아 Summary, Issue Updates, Impacted Resources를 확인해야 합니다.

Microsoft의 [보안 공지 안내](https://learn.microsoft.com/en-us/azure/service-health/security-advisories-elevated-access)에 따르면
보안 공지는 플랫폼 취약점, 보안 사고, 개인정보 침해 등을 안내하며 일반 서비스 장애 공지와 구분됩니다.
영향 리소스 정보는 민감한 정보로 취급하므로 Reader만으로는 조회할 수 없을 수 있습니다.
Owner, Contributor 또는 필요한 보안 공지 권한을 포함한 사용자 지정 역할을 확인하세요.
이 점검을 위해 쓰기 권한을 부여하거나 권한을 자동으로 올리지는 않습니다.

## 구독별 읽기 전용 점검

[셸 스크립트](../scripts/check_apim_advisory.sh)는 Bash, Azure CLI, jq가 필요합니다.
여기서 구독은 Azure 구독이며, Gateway 호출용 APIM Product 구독과 다릅니다.
Azure Public Cloud의 `management.azure.com`을 대상으로 합니다.

```bash
az login

# 현재 Azure CLI 구독
bash scripts/check_apim_advisory.sh

# 특정 Azure 구독, 이름 또는 ID 지정
bash scripts/check_apim_advisory.sh --subscription "<subscription-id>"

# 여러 구독
bash scripts/check_apim_advisory.sh \
  --subscription "<subscription-id-1>" \
  --subscription "<subscription-id-2>"

# 로그인 계정의 캐시에 있는 모든 Enabled 구독
bash scripts/check_apim_advisory.sh --all

# 상세 JSON 보고서 저장
umask 077
bash scripts/check_apim_advisory.sh --all --json > apim-advisory-report.json

# 다른 보안 공지
bash scripts/check_apim_advisory.sh --all --tracking-id "<tracking-id>"
```

스크립트는 `az account set`을 실행하지 않으며 현재 기본 구독을 변경하지 않습니다.
다른 테넌트의 구독이 캐시에 없으면 해당 테넌트로 로그인한 뒤 별도로 실행하세요.
접근할 수 없는 구독까지 전체 조직을 점검한 것으로 해석하지 않습니다.
보고서에는 구독명·리소스 ID·구성 메타데이터가 포함되므로 접근을 제한하고 저장소에 커밋하지 마세요.

점검 범위는 다음과 같습니다.

- 구독별 APIM 목록, SKU, 지역, VNet 유형, 공개 네트워크 설정, Private Endpoint 연결 수
- 공식 [구독별 영향 리소스 조회 API](https://learn.microsoft.com/en-us/rest/api/resourcehealth/security-advisory-impacted-resources/list-by-subscription-id-and-event-id?view=rest-resourcehealth-2026-07-01)의 전체 페이지
- 영향 레코드의 `targetResourceId` 또는 `properties.info`의 리소스 ID와 APIM ID의 대소문자 무시 완전 일치
- APIM Named Values의 이름, 비밀 플래그, Key Vault 참조 여부, 직접 저장한 비밀 여부

영향 목록 API는 조회 작업이지만 HTTP `POST`를 사용합니다.
나머지 리소스 조회는 `GET`이며 배포, 키 조회·재발급, 정책 수정, 권한 변경은 실행하지 않습니다.
Named Values의 `value`는 출력 대상에서 제외하며 `listSecrets`·`listValue`는 호출하지 않습니다.
비밀 플래그는 현재 저장 방식에 대한 정보이며 실제 유출의 증거가 아닙니다.

## 결과 해석

기본 출력은 구독별 APIM 테이블입니다.
이름, 리소스 그룹, 구독 ID, 지역, SKU, 영향 목록 포함 상태를 표시합니다.
테이블에는 실제 조회 결과와 필요한 오류 안내만 표시하며, 고정 상태 범례는 출력하지 않습니다.
상태의 의미는 아래 설명을 참고하세요.
API 조회가 실패하면 `Advisory` 열에 Azure CLI가 출력한 원본 오류를 표시합니다.
예를 들어 `ERROR: Not Found({"code":"TrackingIdNotFound"})`를 `UNKNOWN`으로 바꾸지 않습니다.
표의 행을 유지하기 위해 원본 오류의 줄바꿈만 `\n`·`\r`로 표시하며 오류 코드·본문은 요약하지 않습니다.
원본 API 오류가 없는 형식 검증 실패나 리소스 ID 대조 불완전은 `UNKNOWN`으로 표시합니다.
APIM이 하나도 없으면 `APIM 없음`, APIM 목록 API 조회가 실패하면 해당 원본 오류를 표시합니다.

```text
공지: MZK9-GH0

[구독: 운영 구독]
Name             ResourceGroup  SubscriptionId  Location      SKU        Advisory
---------------  -------------  --------------  ------------  ---------  ----------
production-apim  production-rg  example-sub     koreacentral  Standard   LISTED
internal-apim    internal-rg    example-sub     koreacentral  Developer  NOT_LISTED
```

이미지의 공식 가이드에서 제시한 인스턴스 목록 항목에 SKU와 영향 상태를 추가한 형태입니다.
Azure Resource Graph 확장 설치나 단일 페이지 조회 대신 기존 구독별 ARM 전체 페이지 조회를 유지합니다.
표의 `NOT_LISTED`는 JSON의 `NOT_LISTED_IN_RETURNED_RECORDS`를 줄인 표시이며,
`UNKNOWN_RESOURCE_MAPPING`도 표에서는 `UNKNOWN`으로 표시합니다.

`--json`을 지정하면 기존 상세 보고서를 출력합니다.
JSON은 `trackingId`, `checkedAt`, `status`, `subscriptions`, `warnings`를 포함합니다.
조회 오류는 표준 오류로 나오며, JSON 모드에서는 진행 메시지도 표준 오류로 나옵니다.
각 구독은 `inventoryStatus`, `apimCount`, `advisory`, `apim`, `errors`를 포함합니다.
각 APIM의 `advisory.status`로 영향 목록 대조 결과를 확인하세요.
JSON의 실패 상태는 기존 `UNKNOWN`을 유지하며, 원본 오류는 구독과 APIM의 `advisory.error`에 보존합니다.
APIM 목록 API 오류는 구독의 `inventoryError`에 보존합니다.
원본 오류에 구독·리소스 정보가 포함될 수 있으므로 JSON과 터미널 출력 모두 접근을 제한하세요.

| 상태                              | 의미                                                    |
|-----------------------------------|---------------------------------------------------------|
| `LISTED`                          | 반환된 영향 레코드에서 해당 APIM ID가 확인됨               |
| `NOT_LISTED_IN_RETURNED_RECORDS`    | 조회한 전체 페이지에 해당 ID가 없음. 안전 판정이 아님       |
| `UNKNOWN_RESOURCE_MAPPING`        | ID를 식별할 수 없는 영향 레코드가 있어 대조 결과가 불완전함 |
| `UNKNOWN`                         | 권한 부족, 공지 미조회, API 오류 등으로 확인하지 못함       |

조회 실패 시 빈 목록을 안전한 결과로 표시하지 않습니다.
실패한 구독·APIM은 오류를 남기고 나머지 점검을 계속합니다.
APIM 목록 조회 실패 시 `apimCount`는 `null`이며, 정상 조회에서 0일 때만 리소스가 없다는 뜻입니다.
영향 목록 조회 실패 시 반환 건수와 일치 건수도 `null`입니다.
일부 페이지 조회가 실패하면 그 조회 전체를 `UNKNOWN`으로 처리합니다.

종료 코드는 `0`이면 조회 완료, `1`이면 입력·로그인·준비 단계 실패,
`2`이면 조회 또는 리소스 대조가 불완전하다는 뜻입니다.
`LISTED`가 있어도 조회가 완료되면 `0`입니다. 종료 코드를 보안 적합 판정으로 사용하지 마세요.

## 운영 대응

일반 실행에서는 조회 결과 뒤에 `키 회전 작업 흐름 (조회만 실행: 재발급·갱신·삭제는 실행하지 않음)`을 출력합니다.
[Microsoft의 자격 증명 회전 가이드](https://techcommunity.microsoft.com/blog/integrationsonazureblog/rotating-credentials-in-azure-api-management/4575478)에 따라
사용처 확인, 구독 키, Named Values, Backend, 인증 공급자, Logger, 정책,
Legacy Direct Management API 키와 최종 검증 순서를 `echo`로 설명합니다.
1단계는 APIM 구독, Backend, OAuth·OIDC·로그인 공급자·Credential manager, Logger,
Global·API 정책과 API 이름을 실제로 조회합니다. Named Values는 앞서 조회한 결과를 재사용합니다.
각 조회의 전체 페이지를 확인하고, 실패 시 원본 오류를 표시하며 나머지 조회를 계속합니다.
추가 조회가 실패하면 종료 코드는 `2`입니다.
리소스 이름만 출력하며 비밀 값·Backend 인증 값·Logger 연결 문자열·정책 본문은 출력하지 않습니다.
Product·Operation 정책과 본문에 직접 작성한 자격 증명은 별도 수동 점검 대상입니다.

2~9단계는 실행되지 않는 회전 설명입니다.
관련 변경 CLI 예시는 [스크립트](../scripts/check_apim_advisory.sh)의 `print_rotation_flow`에 주석으로 유지합니다.
실제 비밀을 반환하는 `listSecrets`·`show-secret`도 주석으로 유지합니다.
비밀 값 조회, 키 재발급, 값 갱신, 기존 자격 증명 삭제 명령은 실행하지 않습니다.
예시의 `{base}`, `{sid}`, `{newValue}` 등은 미설정 자리 표시자이며,
일괄 주석 해제용이 아니라 승인된 별도 작업을 검토하기 위한 참고입니다.
실제로 수행할 때는 발급처와 클라이언트 전환, ETag, 비밀 값 보호와 비운영 환경 테스트를 먼저 확인하세요.
`--json`은 이 추가 메타데이터 조회와 텍스트 설명을 수행하지 않으며 기존 JSON 점검 형식을 유지합니다.

1. 공지 원문에서 영향 기간, 영향 서비스·리소스, 고객에게 요구된 조치와 기한을 기록합니다.
2. `LISTED` 리소스와 `UNKNOWN` 구독을 우선 확인하고 Portal 결과와 대조합니다.
3. 현재 설정과 사고 당시 설정을 구분합니다. Private Endpoint, VNet, Self-hosted Gateway 사용만으로
   관리 영역의 사고 영향이 없다고 결론 내리지 않습니다.
4. 자격 증명 노출이 공지에서 확인되면 Microsoft가 지정한 범위를 기준으로 회전 순서를 계획합니다.
   이 샘플의 백엔드 OpenAI 키, PII 필터 키, APIM 구독 키, Gateway 구성 토큰 외에도
   Identity Provider·OpenID Connect·인증서 등 별도 자격 증명을 확인합니다.
5. 승인된 절차로 교체한 뒤 Gateway 설정 동기화, 정상 호출, 기존 키 거절과 오류 로그를 검증합니다.
   이 스크립트는 회전이나 실제 모델 호출을 수행하지 않습니다.
6. 공지의 영향 기간에 해당하는 Activity Log, APIM 진단 로그, 백엔드 접근 로그와
   자격 증명 사용 기록을 조사합니다. 로그 부재를 침해 부재로 해석하지 않습니다.

## 로컬 검증

Azure에 접속하지 않는 모의 Azure CLI 테스트와 Bash 문법 검사를 실행할 수 있습니다.

```bash
bash -n scripts/check_apim_advisory.sh
node --test scripts/tests/apim-advisory.test.cjs
```
