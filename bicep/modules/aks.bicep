// AKS cluster: managed identity, OIDC issuer + workload identity (pods get Azure
// identities without secrets) and the Key Vault Secrets Store CSI driver.

@description('Azure region.')
param location string

@description('Resource name prefix, e.g. oc3d-dev.')
param namePrefix string

@description('Kubernetes version (empty = AKS default).')
param kubernetesVersion string = ''

@allowed([
  'Free'
  'Standard'
])
@description('Control plane tier. Free has no SLA and no control-plane cost.')
param tier string = 'Free'

@description('System node pool VM size.')
param nodeVmSize string

@minValue(1)
@maxValue(10)
param nodeCount int = 1

@description('Node OS disk size in GiB (32 GiB = P4 premium disk, about half the price of 64 GiB).')
@minValue(30)
param osDiskSizeGB int = 32

@description('Log Analytics workspace for Container Insights (empty = disabled, saves ingestion cost).')
param logAnalyticsWorkspaceId string = ''

param tags object = {}

var monitoringEnabled = !empty(logAnalyticsWorkspaceId)

resource cluster 'Microsoft.ContainerService/managedClusters@2025-10-01' = {
  name: 'aks-${namePrefix}'
  location: location
  tags: tags
  sku: {
    name: 'Base'
    tier: tier
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    kubernetesVersion: empty(kubernetesVersion) ? null : kubernetesVersion
    dnsPrefix: 'aks-${namePrefix}'
    enableRBAC: true
    disableLocalAccounts: false
    agentPoolProfiles: [
      {
        name: 'system'
        mode: 'System'
        count: nodeCount
        vmSize: nodeVmSize
        osType: 'Linux'
        osSKU: 'AzureLinux'
        osDiskSizeGB: osDiskSizeGB
        type: 'VirtualMachineScaleSets'
      }
    ]
    networkProfile: {
      networkPlugin: 'azure'
      networkPluginMode: 'overlay'
      loadBalancerSku: 'standard'
    }
    oidcIssuerProfile: {
      enabled: true
    }
    securityProfile: {
      workloadIdentity: {
        enabled: true
      }
    }
    addonProfiles: {
      azureKeyvaultSecretsProvider: {
        enabled: true
        config: {
          enableSecretRotation: 'true'
        }
      }
      omsagent: {
        enabled: monitoringEnabled
        config: monitoringEnabled ? {
          logAnalyticsWorkspaceResourceID: logAnalyticsWorkspaceId
        } : null
      }
    }
  }
}

output name string = cluster.name
output oidcIssuerUrl string = cluster.properties.oidcIssuerProfile.issuerURL
output kubeletPrincipalId string = cluster.properties.identityProfile.kubeletidentity.objectId
