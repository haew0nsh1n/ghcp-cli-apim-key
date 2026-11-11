targetScope = 'resourceGroup'

@description('Azure region for all resources.')
param location string = resourceGroup().location

@description('Lowercase prefix used to create globally unique resource names.')
@minLength(3)
@maxLength(20)
param resourcePrefix string

@description('APIM subscription identifier selected by the CLI. Create the subscription separately; Bicep does not create subscriptions or keys.')
param apimSubscriptionId string = 'copilot-cli'
param apimPublisherEmail string
param apimPublisherName string

@description('Classic APIM tier supporting VNet injection and self-hosted gateways.')
@allowed([
  'Developer'
  'Premium'
])
param apimSkuName string = 'Developer'

param openAiModelName string = 'gpt-5-mini'
param openAiModelVersion string = '2025-08-07'
param openAiDeploymentName string = 'gpt-5-mini'
param openAiDeploymentSkuName string = 'GlobalStandard'
param openAiDeploymentCapacity string = '10'

param tokensPerMinute string = '10000'

param tokenQuota string = '1000000'

@allowed([
  'Hourly'
  'Daily'
  'Weekly'
  'Monthly'
  'Yearly'
])
param tokenQuotaPeriod string = 'Monthly'

var uniqueSuffix = uniqueString(subscription().id, resourceGroup().id, resourcePrefix)
var apimName = '${resourcePrefix}-apim-${uniqueSuffix}'
var openAiName = take('${resourcePrefix}-aoai-${uniqueSuffix}', 64)
var workspaceName = '${resourcePrefix}-law-${uniqueSuffix}'
var appInsightsName = '${resourcePrefix}-appi-${uniqueSuffix}'

module monitoring 'modules/monitoring.bicep' = {
  name: 'monitoring'
  params: {
    location: location
    workspaceName: workspaceName
    appInsightsName: appInsightsName
  }
}

module openai 'modules/openai.bicep' = {
  name: 'openai'
  params: {
    location: location
    accountName: openAiName
    deploymentName: openAiDeploymentName
    modelName: openAiModelName
    modelVersion: openAiModelVersion
    deploymentSkuName: openAiDeploymentSkuName
    deploymentCapacity: int(openAiDeploymentCapacity)
  }
}

module apim 'modules/apim.bicep' = {
  name: 'apim'
  params: {
    location: location
    serviceName: apimName
    publisherEmail: apimPublisherEmail
    publisherName: apimPublisherName
    skuName: apimSkuName
    openAiEndpoint: openai.outputs.endpoint
    openAiAccountName: openai.outputs.accountName
    openAiDeploymentName: openAiDeploymentName
    appInsightsId: monitoring.outputs.appInsightsId
    appInsightsConnectionString: monitoring.outputs.appInsightsConnectionString
    tokensPerMinute: int(tokensPerMinute)
    tokenQuota: int(tokenQuota)
    tokenQuotaPeriod: tokenQuotaPeriod
  }
}

module workbook 'modules/workbook.bicep' = {
  name: 'workbook'
  params: {
    location: location
    apimId: apim.outputs.serviceId
    workspaceId: monitoring.outputs.workspaceId
    workbookName: guid(resourceGroup().id, apim.outputs.serviceId, 'user-usage-workbook')
  }
}

output APIM_NAME string = apim.outputs.serviceName
output APIM_GATEWAY_URL string = apim.outputs.gatewayUrl
output APIM_SUBSCRIPTION_ID string = apimSubscriptionId
output OPENAI_ACCOUNT_NAME string = openAiName
output OPENAI_DEPLOYMENT_NAME string = openAiDeploymentName
output APPLICATION_INSIGHTS_NAME string = appInsightsName
output LOG_ANALYTICS_WORKSPACE_NAME string = workspaceName
output APIM_USER_USAGE_WORKBOOK_NAME string = workbook.outputs.workbookName
