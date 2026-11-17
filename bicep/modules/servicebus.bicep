// Service Bus namespace + queue for severe/critical toxicity alerts (HU11, Block 6).
// Access is identity-based (RBAC); local SAS auth is disabled.

@description('Azure region.')
param location string

@description('Globally unique namespace name.')
param name string

@allowed([
  'Basic'
  'Standard'
])
@description('Basic supports queues (enough for HU11); Standard adds topics.')
param sku string = 'Basic'

@description('Queue consumed by the toxicity alert function.')
param alertQueueName string = 'toxicity-alerts'

@description('Principal IDs allowed to SEND alerts (Clinical Service workload identity).')
param senderPrincipalIds array = []

@description('Principal IDs allowed to RECEIVE alerts (Function App identity).')
param receiverPrincipalIds array = []

param tags object = {}

var senderRoleId = '69a216fc-b8fb-44d8-bc22-1f3c2cd27a39' // Azure Service Bus Data Sender
var receiverRoleId = '4f6d3b9b-027b-4f4c-9142-0e5a2a2247e0' // Azure Service Bus Data Receiver

resource namespace 'Microsoft.ServiceBus/namespaces@2026-01-01' = {
  name: name
  location: location
  tags: tags
  sku: {
    name: sku
    tier: sku
  }
  properties: {
    disableLocalAuth: true
    minimumTlsVersion: '1.2'
  }
}

resource alertQueue 'Microsoft.ServiceBus/namespaces/queues@2026-01-01' = {
  parent: namespace
  name: alertQueueName
  properties: {
    maxDeliveryCount: 5
    lockDuration: 'PT1M'
    defaultMessageTimeToLive: 'P1D'
    deadLetteringOnMessageExpiration: true
  }
}

resource senders 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for principalId in senderPrincipalIds: {
  name: guid(alertQueue.id, principalId, senderRoleId)
  scope: alertQueue
  properties: {
    principalId: principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', senderRoleId)
  }
}]

resource receivers 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for principalId in receiverPrincipalIds: {
  name: guid(alertQueue.id, principalId, receiverRoleId)
  scope: alertQueue
  properties: {
    principalId: principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', receiverRoleId)
  }
}]

output name string = namespace.name
output fullyQualifiedNamespace string = '${namespace.name}.servicebus.windows.net'
output alertQueueName string = alertQueue.name
