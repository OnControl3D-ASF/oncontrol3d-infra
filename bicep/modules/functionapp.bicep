// Azure Function App (Flex Consumption, Java 21) + its Storage account.
// Identity-based everywhere: no storage keys, no Service Bus connection strings.

@description('Azure region.')
param location string

@description('Resource name prefix, e.g. oc3d-dev.')
param namePrefix string

@description('Globally unique storage account name (3-24 lowercase alphanumerics).')
@minLength(3)
@maxLength(24)
param storageAccountName string

@description('Application Insights connection string (telemetry).')
param appInsightsConnectionString string

@description('Service Bus FQDN, e.g. sb-x.servicebus.windows.net (trigger connection).')
param serviceBusFullyQualifiedNamespace string

@description('Queue with severe/critical toxicity alerts.')
param alertQueueName string

@minValue(40)
@maxValue(1000)
param maximumInstanceCount int = 40

@allowed([
  2048
  4096
])
param instanceMemoryMB int = 2048

param tags object = {}

var deploymentContainerName = 'app-package'
var storageRoles = [
  'b7e6dc6d-f1e8-4753-8033-0f276bb0955b' // Storage Blob Data Owner (package + host state)
  '974c5e8b-45b9-4653-ba55-5f855dd0fb88' // Storage Queue Data Contributor
  '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3' // Storage Table Data Contributor
]

resource storage 'Microsoft.Storage/storageAccounts@2025-06-01' = {
  name: storageAccountName
  location: location
  tags: tags
  kind: 'StorageV2'
  sku: {
    name: 'Standard_LRS'
  }
  properties: {
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    supportsHttpsTrafficOnly: true
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2025-06-01' = {
  parent: storage
  name: 'default'
}

resource deploymentContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2025-06-01' = {
  parent: blobService
  name: deploymentContainerName
}

resource plan 'Microsoft.Web/serverfarms@2025-03-01' = {
  name: 'asp-${namePrefix}-func'
  location: location
  tags: tags
  kind: 'functionapp'
  sku: {
    tier: 'FlexConsumption'
    name: 'FC1'
  }
  properties: {
    reserved: true
  }
}

resource functionApp 'Microsoft.Web/sites@2025-03-01' = {
  name: 'func-${namePrefix}-alerts'
  location: location
  tags: union(tags, {
    'azd-service-name': 'toxicity-alerts'
  })
  kind: 'functionapp,linux'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: plan.id
    httpsOnly: true
    siteConfig: {
      minTlsVersion: '1.2'
      ftpsState: 'Disabled'
      appSettings: [
        {
          name: 'AzureWebJobsStorage__accountName'
          value: storage.name
        }
        {
          name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
          value: appInsightsConnectionString
        }
        {
          name: 'ServiceBusConnection__fullyQualifiedNamespace'
          value: serviceBusFullyQualifiedNamespace
        }
        {
          name: 'ALERT_QUEUE_NAME'
          value: alertQueueName
        }
      ]
    }
    functionAppConfig: {
      deployment: {
        storage: {
          type: 'blobContainer'
          value: '${storage.properties.primaryEndpoints.blob}${deploymentContainerName}'
          authentication: {
            type: 'SystemAssignedIdentity'
          }
        }
      }
      scaleAndConcurrency: {
        maximumInstanceCount: maximumInstanceCount
        instanceMemoryMB: instanceMemoryMB
      }
      runtime: {
        name: 'java'
        version: '21'
      }
    }
  }
  dependsOn: [
    deploymentContainer
  ]
}

resource storageRoleAssignments 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for roleId in storageRoles: {
  name: guid(storage.id, functionApp.id, roleId)
  scope: storage
  properties: {
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleId)
  }
}]

output name string = functionApp.name
output principalId string = functionApp.identity.principalId
output storageAccountName string = storage.name
