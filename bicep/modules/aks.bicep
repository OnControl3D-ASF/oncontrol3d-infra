// AKS cluster: managed identity, OIDC issuer + workload identity (pods get Azure
// identities without secrets), the Key Vault Secrets Store CSI driver and
// Microsoft Entra ID authentication with Azure RBAC for Kubernetes: no local
// accounts, so every kubectl call (people and CI) is an audited Entra identity
// and can be granted per role instead of sharing a cluster-admin certificate.

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
    disableLocalAccounts: true
    aadProfile: {
      managed: true
      enableAzureRBAC: true
      tenantID: subscription().tenantId
    }
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
        // Student quota = 4 vCPU = exactly 2 x D2s_v4: no surge node is possible, upgrade one node at a time.
        upgradeSettings: {
          maxSurge: '0'
          maxUnavailable: '1'
        }
      }
    ]
    networkProfile: {
      networkPlugin: 'azure'
      networkPluginMode: 'overlay'
      // Cilium dataplane + policy engine (NetworkPolicy enforcement). Set at cluster creation:
      // it cannot be reverted to the default dataplane without recreating the cluster.
      networkDataplane: 'cilium'
      networkPolicy: 'cilium'
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
