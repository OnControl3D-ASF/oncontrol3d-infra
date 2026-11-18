// Azure Container Registry for the backend images.
// Admin user disabled: pulls use managed identities (AcrPull), pushes use the CI identity.

@description('Azure region.')
param location string

@description('Globally unique registry name (alphanumeric, 5-50 chars).')
@minLength(5)
@maxLength(50)
param name string

@allowed([
  'Basic'
  'Standard'
  'Premium'
])
param sku string = 'Basic'

@description('Principal IDs granted AcrPull (e.g. the AKS kubelet identity).')
param pullPrincipalIds array = []

param tags object = {}

var acrPullRoleId = '7f951dda-4ed3-4680-a7ca-43fe172d538d'

resource registry 'Microsoft.ContainerRegistry/registries@2025-04-01' = {
  name: name
  location: location
  tags: tags
  sku: {
    name: sku
  }
  properties: {
    adminUserEnabled: false
    publicNetworkAccess: 'Enabled'
  }
}

resource acrPull 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for principalId in pullPrincipalIds: {
  name: guid(registry.id, principalId, acrPullRoleId)
  scope: registry
  properties: {
    principalId: principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', acrPullRoleId)
  }
}]

output name string = registry.name
output id string = registry.id
output loginServer string = registry.properties.loginServer
