param location string
param serviceName string
param publisherEmail string
param publisherName string
@description('Classic APIM tier supporting VNet injection and self-hosted gateways.')
@allowed([
  'Developer'
  'Premium'
])
param skuName string
param openAiEndpoint string
param openAiAccountName string
param openAiDeploymentName string
param appInsightsId string
param appInsightsConnectionString string
@minValue(1)
param tokensPerMinute int
@minValue(1)
param tokenQuota int
param tokenQuotaPeriod string

var policyTemplate = loadTextContent('../../apim/policies/openai-policy.xml')
var policyWithDeployment = replace(policyTemplate, '{{OPENAI_DEPLOYMENT_NAME}}', openAiDeploymentName)
var policyWithRate = replace(policyWithDeployment, '{{TOKENS_PER_MINUTE}}', string(tokensPerMinute))
var policyWithQuota = replace(policyWithRate, '{{TOKEN_QUOTA}}', string(tokenQuota))
var policyXml = replace(policyWithQuota, '{{TOKEN_QUOTA_PERIOD}}', tokenQuotaPeriod)

resource openAi 'Microsoft.CognitiveServices/accounts@2024-10-01' existing = {
  name: openAiAccountName
}

resource apim 'Microsoft.ApiManagement/service@2024-05-01' = {
  name: serviceName
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  sku: {
    name: skuName
    capacity: 1
  }
  properties: {
    publisherEmail: publisherEmail
    publisherName: publisherName
    publicNetworkAccess: 'Enabled'
    virtualNetworkType: 'None'
  }
}

resource logger 'Microsoft.ApiManagement/service/loggers@2024-05-01' = {
  name: 'application-insights'
  parent: apim
  properties: {
    loggerType: 'applicationInsights'
    description: 'Application Insights logger for the self-hosted gateway'
    resourceId: appInsightsId
    credentials: {
      connectionString: appInsightsConnectionString
    }
    isBuffered: true
  }
}

resource backendKey 'Microsoft.ApiManagement/service/namedValues@2024-05-01' = {
  name: 'openai-backend-key'
  parent: apim
  properties: {
    displayName: 'openai-backend-key'
    secret: true
    value: openAi.listKeys().key1
  }
}

resource api 'Microsoft.ApiManagement/service/apis@2024-05-01' = {
  name: 'self-hosted-openai'
  parent: apim
  properties: {
    displayName: 'Self-hosted OpenAI proxy'
    description: 'Self-hosted ingress with direct Azure OpenAI API-key authentication.'
    path: 'self-hosted/openai'
    protocols: [
      'https'
    ]
    serviceUrl: '${openAiEndpoint}openai/v1'
    subscriptionRequired: true
    subscriptionKeyParameterNames: {
      header: 'Ocp-Apim-Subscription-Key'
      query: 'subscription-key'
    }
    type: 'http'
  }
}

resource product 'Microsoft.ApiManagement/service/products@2024-05-01' = {
  name: 'copilot-cli'
  parent: apim
  properties: {
    displayName: 'Copilot CLI'
    description: 'Subscription-key access to the self-hosted OpenAI API.'
    subscriptionRequired: true
    approvalRequired: false
    state: 'published'
  }
}

resource productApi 'Microsoft.ApiManagement/service/products/apis@2024-05-01' = {
  name: api.name
  parent: product
}

resource chatCompletions 'Microsoft.ApiManagement/service/apis/operations@2024-05-01' = {
  name: 'chat-completions'
  parent: api
  properties: {
    displayName: 'Chat completions'
    method: 'POST'
    urlTemplate: '/chat/completions'
    description: 'Calls the configured Azure OpenAI chat completions deployment.'
    templateParameters: []
    responses: [
      {
        statusCode: 200
        description: 'Successful Azure OpenAI response.'
      }
    ]
  }
}

resource apiPolicy 'Microsoft.ApiManagement/service/apis/policies@2024-05-01' = {
  name: 'policy'
  parent: api
  properties: {
    format: 'rawxml'
    value: policyXml
  }
  dependsOn: [
    backendKey
  ]
}

resource diagnostic 'Microsoft.ApiManagement/service/apis/diagnostics@2024-05-01' = {
  name: 'applicationinsights'
  parent: api
  properties: {
    loggerId: logger.id
    alwaysLog: 'allErrors'
    httpCorrelationProtocol: 'W3C'
    logClientIp: false
    metrics: true
    verbosity: 'information'
    sampling: {
      samplingType: 'fixed'
      percentage: 100
    }
    frontend: {
      request: {
        body: {
          bytes: 0
        }
        headers: []
      }
      response: {
        body: {
          bytes: 0
        }
        headers: []
      }
    }
    backend: {
      request: {
        body: {
          bytes: 0
        }
        headers: []
      }
      response: {
        body: {
          bytes: 0
        }
        headers: []
      }
    }
  }
}

output serviceName string = apim.name
output serviceId string = apim.id
output gatewayUrl string = apim.properties.gatewayUrl
