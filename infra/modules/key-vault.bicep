param location string
param vaultName string
param openAiAccountName string
@secure()
param piiFilterKey string

resource openAi 'Microsoft.CognitiveServices/accounts@2024-10-01' existing = {
  name: openAiAccountName
}

resource vault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: vaultName
  location: location
  properties: {
    sku: {
      family: 'A'
      name: 'standard'
    }
    tenantId: tenant().tenantId
    enableRbacAuthorization: true
    enabledForTemplateDeployment: true
    enablePurgeProtection: true
    publicNetworkAccess: 'Enabled'
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: 'Deny'
    }
  }
}

resource openAiKey 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: vault
  name: 'openai-backend-key'
  properties: {
    value: openAi.listKeys().key1
  }
}

resource piiKey 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = if (!empty(piiFilterKey)) {
  parent: vault
  name: 'pii-filter-key'
  properties: {
    value: piiFilterKey
  }
}

resource existingPiiKey 'Microsoft.KeyVault/vaults/secrets@2023-07-01' existing = {
  parent: vault
  name: 'pii-filter-key'
}

output name string = vault.name
output openAiSecretUri string = openAiKey.properties.secretUri
output piiSecretUri string = existingPiiKey.properties.secretUriWithVersion
