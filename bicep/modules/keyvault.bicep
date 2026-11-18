// Key Vault (RBAC authorization) holding the backend secrets.
// Secrets are written through ARM, so CI needs no data-plane permissions.

@description('Azure region.')
param location string

@description('Globally unique vault name (3-24 chars).')
@minLength(3)
@maxLength(24)
param name string

@description('Purge protection cannot be disabled once enabled: on for prod, off for dev.')
param enablePurgeProtection bool = false

@secure()
@description('PostgreSQL password for the Clinical Service (DB_PASSWORD).')
param dbPassword string

@secure()
@description('JWT signing key for the Clinical Service (JWT_SECRET, >= 32 bytes).')
param jwtSecret string

@description('Principal IDs granted "Key Vault Secrets User" (read secrets).')
param secretReaderPrincipalIds array = []

param tags object = {}

var secretsUserRoleId = '4633458b-17de-408a-b874-0445c86b69e6' // Key Vault Secrets User

resource vault 'Microsoft.KeyVault/vaults@2025-05-01' = {
  name: name
  location: location
  tags: tags
  properties: {
    tenantId: subscription().tenantId
    sku: {
      family: 'A'
      name: 'standard'
    }
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
    enablePurgeProtection: enablePurgeProtection ? true : null
    publicNetworkAccess: 'Enabled'
  }
}

resource dbPasswordSecret 'Microsoft.KeyVault/vaults/secrets@2025-05-01' = {
  parent: vault
  name: 'db-password'
  properties: {
    value: dbPassword
    contentType: 'PostgreSQL password (DB_PASSWORD)'
  }
}

resource jwtSecretSecret 'Microsoft.KeyVault/vaults/secrets@2025-05-01' = {
  parent: vault
  name: 'jwt-secret'
  properties: {
    value: jwtSecret
    contentType: 'JWT signing key (JWT_SECRET)'
  }
}

resource readers 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for principalId in secretReaderPrincipalIds: {
  name: guid(vault.id, principalId, secretsUserRoleId)
  scope: vault
  properties: {
    principalId: principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', secretsUserRoleId)
  }
}]

output name string = vault.name
output uri string = vault.properties.vaultUri
