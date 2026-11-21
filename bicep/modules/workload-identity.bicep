// User-assigned identity for a Kubernetes service account (AKS workload identity).
// Pods using the service account get Azure AD tokens without any stored secret.

@description('Azure region.')
param location string

@description('Identity name.')
param name string

@description('AKS OIDC issuer URL.')
param oidcIssuerUrl string

@description('Kubernetes namespaces of the service account (one federated credential each).')
param serviceAccountNamespaces array

@description('Kubernetes service account name.')
param serviceAccountName string

param tags object = {}

resource identity 'Microsoft.ManagedIdentity/userAssignedIdentities@2024-11-30' = {
  name: name
  location: location
  tags: tags
}

// ARM rejects concurrent federated credential writes on the same identity: one at a time.
@batchSize(1)
resource federation 'Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials@2024-11-30' = [for ns in serviceAccountNamespaces: {
  parent: identity
  name: 'aks-${ns}-${serviceAccountName}'
  properties: {
    issuer: oidcIssuerUrl
    subject: 'system:serviceaccount:${ns}:${serviceAccountName}'
    audiences: [
      'api://AzureADTokenExchange'
    ]
  }
}]

output principalId string = identity.properties.principalId
output clientId string = identity.properties.clientId
