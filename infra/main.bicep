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

@secure()
@maxLength(4096)
@description('Supply the current PII sidecar key for migration, or a new key for initial deployment or scheduled rotation. Empty reuses the existing Vault secret.')
param piiFilterKey string = ''

var uniqueSuffix = uniqueString(subscription().id, resourceGroup().id, resourcePrefix)
var apimName = '${resourcePrefix}-apim-${uniqueSuffix}'
var openAiName = take('${resourcePrefix}-aoai-${uniqueSuffix}', 64)
var workspaceName = '${resourcePrefix}-law-${uniqueSuffix}'
var appInsightsName = '${resourcePrefix}-appi-${uniqueSuffix}'
var acrName = '${replace(resourcePrefix, '-', '')}acr${uniqueSuffix}'
var vaultName = 'kv-${uniqueSuffix}'

module registry 'modules/registry.bicep' = {
  name: 'registry'
  params: {
    location: location
    registryName: acrName
    identityName: '${resourcePrefix}-pii-pull-${uniqueSuffix}'
  }
}

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

module vault 'modules/key-vault.bicep' = {
  name: 'key-vault'
  params: {
    location: location
    vaultName: vaultName
    openAiAccountName: openai.outputs.accountName
    piiFilterKey: piiFilterKey
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
    vaultName: vault.outputs.name
    openAiSecretUri: vault.outputs.openAiSecretUri
    piiSecretUri: vault.outputs.piiSecretUri
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
output KEY_VAULT_NAME string = vaultName
output APPLICATION_INSIGHTS_NAME string = appInsightsName
output LOG_ANALYTICS_WORKSPACE_NAME string = workspaceName
output APIM_USER_USAGE_WORKBOOK_NAME string = workbook.outputs.workbookName
output ACR_NAME string = registry.outputs.registryName
output ACR_LOGIN_SERVER string = registry.outputs.loginServer
output ACR_PULL_IDENTITY_ID string = registry.outputs.pullIdentityId
