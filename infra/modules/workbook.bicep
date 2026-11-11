param location string
param apimId string
param workspaceId string
param workbookName string

var requestCountBySubscriptionQuery = '''
AppTraces
| where TimeGenerated > ago(7d)
| where Properties.EventName == "RequestStarted"
| extend
    SubscriptionId = tostring(Properties.SubscriptionId),
    Api = tostring(Properties.Api),
    Model = tostring(Properties.Model)
| summarize RequestCount = dcount(tostring(Properties.RequestId)) by SubscriptionId, Api, Model
| order by RequestCount desc
'''

var tokenUsageBySubscriptionQuery = '''
AppTraces
| where TimeGenerated > ago(7d)
| where Properties.EventName == "LlmUsage"
| extend
    SubscriptionId = tostring(Properties.SubscriptionId),
    RequestId = tostring(Properties.RequestId),
    IsExact = tobool(Properties.IsExact),
    PromptTokens = tolong(Properties.PromptTokens),
    CompletionTokens = tolong(Properties.CompletionTokens),
    TotalTokens = tolong(Properties.TotalTokens)
| summarize
    RequestCount = dcount(RequestId),
    ExactRequestCount = dcountif(RequestId, IsExact),
    EstimatedRequestCount = dcountif(RequestId, not(IsExact)),
    PromptTokens = sum(PromptTokens),
    CompletionTokens = sum(CompletionTokens),
    TotalTokens = sum(TotalTokens),
    LastSeen = max(TimeGenerated)
    by SubscriptionId
| extend AverageTokensPerRequest = round(todouble(TotalTokens) / RequestCount, 1)
| project
    SubscriptionId,
    RequestCount,
    ExactRequestCount,
    EstimatedRequestCount,
    PromptTokens,
    CompletionTokens,
    TotalTokens,
    AverageTokensPerRequest,
    LastSeen
| order by TotalTokens desc
'''

var dailyTokenUsageQuery = '''
AppTraces
| where TimeGenerated > ago(30d)
| where Properties.EventName == "LlmUsage"
| extend
    SubscriptionId = tostring(Properties.SubscriptionId),
    PromptTokens = tolong(Properties.PromptTokens),
    CompletionTokens = tolong(Properties.CompletionTokens),
    TotalTokens = tolong(Properties.TotalTokens)
| summarize
    PromptTokens = sum(PromptTokens),
    CompletionTokens = sum(CompletionTokens),
    TotalTokens = sum(TotalTokens)
    by bin(TimeGenerated, 1d), SubscriptionId
| order by TimeGenerated asc
'''

var highestConsumersQuery = '''
AppTraces
| where TimeGenerated > ago(30d)
| where Properties.EventName == "LlmUsage"
| extend
    SubscriptionId = tostring(Properties.SubscriptionId),
    TotalTokens = tolong(Properties.TotalTokens)
| summarize TotalTokens = sum(TotalTokens), Requests = count() by SubscriptionId
| top 20 by TotalTokens desc
'''

var errorsBySubscriptionQuery = '''
union
(
    AppTraces
    | where TimeGenerated > ago(7d)
    | where Properties.EventName == "LlmUsage"
    | extend StatusCode = toint(Properties.StatusCode)
    | where StatusCode >= 400
    | project
        TimeGenerated,
        SubscriptionId = tostring(Properties.SubscriptionId),
        RequestId = tostring(Properties.RequestId),
        Api = tostring(Properties.Api),
        Model = tostring(Properties.Model),
        StatusCode,
        ErrorReason = ""
),
(
    AppTraces
    | where TimeGenerated > ago(7d)
    | where Properties.EventName == "ApiError"
    | project
        TimeGenerated,
        SubscriptionId = tostring(Properties.SubscriptionId),
        RequestId = tostring(Properties.RequestId),
        Api = tostring(Properties.Api),
        Model = tostring(Properties.Model),
        StatusCode = toint(0),
        ErrorReason = tostring(Properties.ErrorReason)
)
| summarize
    ErrorCount = dcount(RequestId),
    LastError = max(TimeGenerated)
    by SubscriptionId, Api, Model, StatusCode, ErrorReason
| order by ErrorCount desc
'''

var nativeTokenMetricsQuery = '''
AppMetrics
| where TimeGenerated > ago(1d)
| extend Dimensions = tostring(Properties)
| summarize Samples = count(), Total = sum(Sum) by Name, Dimensions
| order by Samples desc
'''

var autoTableSize = 4
var compactQueryStyle = {
  margin: '0 0 8px'
  padding: '8px'
  showBorder: true
}

var workbookData = {
  version: 'Notebook/1.0'
  items: [
    {
      type: 1
      name: 'overview'
      content: {
        json: '''
# APIM 구독별 Azure OpenAI 사용량

최근 7일 요청·토큰 상세와 최근 30일 사용 추이를 구독별로 확인합니다.

> 스트리밍 총 토큰은 추정치입니다. 로그 전송 누락이 발생할 수 있으므로 과금용 원장으로 사용하지 마세요.
        '''
      }
      styleSettings: {
        margin: '0 0 8px'
        padding: '0'
      }
    }
    {
      type: 3
      name: 'request-count-by-subscription'
      content: {
        version: 'KqlItem/1.0'
        title: '구독·API·모델별 요청 시작 수 - 최근 7일'
        query: requestCountBySubscriptionQuery
        size: autoTableSize
        timeContext: {
          durationMs: 604800000
        }
        queryType: 0
        resourceType: 'microsoft.operationalinsights/workspaces'
        crossComponentResources: [
          workspaceId
        ]
        visualization: 'table'
      }
      styleSettings: compactQueryStyle
    }
    {
      type: 3
      name: 'token-usage-by-user'
      content: {
        version: 'KqlItem/1.0'
        title: '구독별 토큰 상세(정확/추정 포함) - 최근 7일'
        query: tokenUsageBySubscriptionQuery
        size: autoTableSize
        timeContext: {
          durationMs: 604800000
        }
        queryType: 0
        resourceType: 'microsoft.operationalinsights/workspaces'
        crossComponentResources: [
          workspaceId
        ]
        visualization: 'table'
      }
      styleSettings: compactQueryStyle
    }
    {
      type: 3
      name: 'daily-token-usage'
      content: {
        version: 'KqlItem/1.0'
        title: '구독별 일일 토큰 사용량 - 최근 30일'
        query: '${dailyTokenUsageQuery}\n| project TimeGenerated, SubscriptionId, TotalTokens'
        size: 0
        timeContext: {
          durationMs: 2592000000
        }
        queryType: 0
        resourceType: 'microsoft.operationalinsights/workspaces'
        crossComponentResources: [
          workspaceId
        ]
        visualization: 'timechart'
        chartSettings: {
          xAxis: 'TimeGenerated'
          yAxis: [
            'TotalTokens'
          ]
          group: 'SubscriptionId'
          showLegend: true
          showMetrics: false
        }
      }
      customWidth: '60'
      styleSettings: compactQueryStyle
    }
    {
      type: 3
      name: 'highest-token-consumers'
      content: {
        version: 'KqlItem/1.0'
        title: '토큰 사용량 상위 구독 - 최근 30일'
        query: highestConsumersQuery
        size: 0
        timeContext: {
          durationMs: 2592000000
        }
        queryType: 0
        resourceType: 'microsoft.operationalinsights/workspaces'
        crossComponentResources: [
          workspaceId
        ]
        visualization: 'barchart'
        chartSettings: {
          xAxis: 'SubscriptionId'
          yAxis: [
            'TotalTokens'
          ]
          showLegend: false
          showMetrics: false
        }
      }
      customWidth: '40'
      styleSettings: compactQueryStyle
    }
    {
      type: 3
      name: 'daily-token-details'
      content: {
        version: 'KqlItem/1.0'
        title: '구독별 일일 토큰 상세(입력·출력은 비스트리밍) - 최근 30일'
        query: '${dailyTokenUsageQuery}\n| order by TimeGenerated desc, TotalTokens desc'
        size: autoTableSize
        timeContext: {
          durationMs: 2592000000
        }
        queryType: 0
        resourceType: 'microsoft.operationalinsights/workspaces'
        crossComponentResources: [
          workspaceId
        ]
        visualization: 'table'
      }
      styleSettings: compactQueryStyle
    }
    {
      type: 3
      name: 'errors-by-user'
      content: {
        version: 'KqlItem/1.0'
        title: '구독별 API 오류 - 최근 7일'
        query: errorsBySubscriptionQuery
        size: autoTableSize
        timeContext: {
          durationMs: 604800000
        }
        queryType: 0
        resourceType: 'microsoft.operationalinsights/workspaces'
        crossComponentResources: [
          workspaceId
        ]
        visualization: 'table'
      }
      styleSettings: compactQueryStyle
    }
    {
      type: 1
      name: 'native-token-metrics-overview'
      content: {
        json: '''
## 데이터 해석 및 메트릭 진단

- 공유 키는 개인 사용자를 식별하지 못합니다. 프롬프트, 응답 본문 및 구독 키는 수집하지 않습니다.
- 요청 시작 건수는 RequestStarted, 토큰 상세의 요청 수는 LlmUsage 기준이므로 서로 다를 수 있습니다.
- 입력·출력 토큰 상세는 비스트리밍 응답에서만 정확합니다. 스트리밍의 입력·출력 토큰이 0이어도 실제 사용량이 없다는 의미는 아닙니다.

AppMetrics의 이름은 제공자와 모델 응답에 따라 달라질 수 있습니다.
Samples는 요청 수가 아닌 메트릭 레코드 수이며, Total은 각 메트릭의 집계값입니다. 위의 trace 기반 토큰 사용량과 합산하지 마세요.
        '''
      }
      styleSettings: {
        margin: '8px 0 0'
        padding: '0'
      }
    }
    {
      type: 3
      name: 'native-token-metrics'
      content: {
        version: 'KqlItem/1.0'
        title: '네이티브 LLM 메트릭 탐색(진단용) - 최근 1일'
        query: nativeTokenMetricsQuery
        size: autoTableSize
        timeContext: {
          durationMs: 86400000
        }
        queryType: 0
        resourceType: 'microsoft.operationalinsights/workspaces'
        crossComponentResources: [
          workspaceId
        ]
        visualization: 'table'
      }
      styleSettings: compactQueryStyle
    }
  ]
  fallbackResourceIds: [
    workspaceId
  ]
  '$schema': 'https://github.com/Microsoft/Application-Insights-Workbooks/blob/master/schema/workbook.json'
}

resource apim 'Microsoft.ApiManagement/service@2024-05-01' existing = {
  name: last(split(apimId, '/'))
}

resource apimDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'send-to-log-analytics'
  scope: apim
  properties: {
    workspaceId: workspaceId
    logAnalyticsDestinationType: 'Dedicated'
    logs: [
      {
        category: 'GatewayLogs'
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
  }
}

resource workbook 'Microsoft.Insights/workbooks@2023-06-01' = {
  name: workbookName
  location: location
  kind: 'shared'
  properties: {
    displayName: 'APIM 구독별 Azure OpenAI 사용량'
    serializedData: string(workbookData)
    version: 'Notebook/1.0'
    sourceId: apimId
    category: 'workbook'
    description: 'APIM을 통해 호출된 Azure OpenAI의 구독별 요청 및 토큰 사용량'
  }
}

output workbookId string = workbook.id
output workbookName string = workbook.name
