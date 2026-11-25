// OnControl3D - Azure infrastructure (resource group scope).
//
//   ACR ──AcrPull──▶ AKS kubelet         Key Vault ◀──Secrets User── clinical + auth workload identities
//   AKS (OIDC + workload identity) ──▶ clinical identity ──Data Sender──▶ Service Bus queue
//   Function App (Flex, Java 21) ◀──Data Receiver── Service Bus queue      PostgreSQL Flexible 16
//   Log Analytics + Application Insights (telemetry for AKS and the Function)
//
// Deploy:   az deployment group create -g <rg> -f bicep/main.bicep -p bicep/params/<env>.bicepparam
// Secrets:  DB_ADMIN_PASSWORD, JWT_SECRET, AUTH_INTERNAL_TOKEN and SEED_USER_PASSWORD are read from environment variables by the
//           .bicepparam files (GitHub environment secrets in CI). They never live in the repo.

targetScope = 'resourceGroup'

@allowed([
  'dev'
  'prod'
])
param environmentName string

@description('Short project name used in resource names.')
@maxLength(8)
param projectName string = 'oc3d'

param location string = resourceGroup().location

// --- AKS ---------------------------------------------------------------------
@description('Deploy AKS + ACR + workload identity. false keeps the data/messaging layer only (saves budget).')
param deployAks bool = true

@allowed([
  'Free'
  'Standard'
])
param aksTier string = 'Free'
param aksNodeVmSize string = 'Standard_D2s_v4'
param aksOsDiskSizeGB int = 32
param aksNodeCount int = 1
param enableContainerInsights bool = false

@description('Kubernetes namespaces whose service accounts get a federated credential (dev + optional prod namespace).')
param appNamespaces array = [
  'oncontrol'
  'oncontrol-prod'
]
param clinicalServiceAccount string = 'clinical'
param authServiceAccount string = 'auth'

@description('Extra databases created on the PostgreSQL server (auth service dev/prod, clinical prod namespace).')
param additionalDatabases array = [
  'oncontrol_auth'
  'oncontrol_prod'
  'oncontrol_auth_prod'
]

// --- Data / messaging / secrets -------------------------------------------------
param acrSku string = 'Basic'
param postgresSkuName string = 'Standard_B1ms'
param postgresSkuTier string = 'Burstable'
param postgresStorageGB int = 32
param postgresBackupRetentionDays int = 7
param postgresHighAvailability bool = false
param postgresAdministratorLogin string = 'oncontroladmin'

@secure()
@minLength(16)
@description('PostgreSQL administrator password (env DB_ADMIN_PASSWORD in CI).')
param postgresAdministratorPassword string

@secure()
@minLength(32)
@description('JWT signing key for the Clinical Service, >= 32 bytes (env JWT_SECRET in CI).')
param jwtSecret string

@secure()
@minLength(32)
@description('Shared secret for the auth internal API (X-Internal-Token), >= 32 bytes (env AUTH_INTERNAL_TOKEN in CI).')
param authInternalToken string

@secure()
@minLength(16)
@maxLength(72)
@description('Password of the seeded demo accounts, 16-72 bytes (bcrypt limit) (env SEED_USER_PASSWORD in CI).')
param seedUserPassword string

param serviceBusSku string = 'Basic'
param keyVaultPurgeProtection bool = false
param logRetentionDays int = 30
param logDailyQuotaGb int = 1

@description('E-mail addresses for the ops action group (alerts). Empty: alerts only show in Azure Monitor.')
param alertEmails array = []

var namePrefix = '${projectName}-${environmentName}'
var compactPrefix = replace(namePrefix, '-', '')
var suffix = take(uniqueString(resourceGroup().id), 6)
var tags = {
  project: 'OnControl3D'
  environment: environmentName
  'managed-by': 'bicep'
}

var serviceBusName = 'sb-${namePrefix}-${suffix}'
var serviceBusFqdn = '${serviceBusName}.servicebus.windows.net'

module monitoring 'modules/monitoring.bicep' = {
  name: 'monitoring'
  params: {
    location: location
    namePrefix: namePrefix
    retentionInDays: logRetentionDays
    dailyQuotaGb: logDailyQuotaGb
    tags: tags
  }
}

// SLO alerts + operations workbook (report 4.3). They query Container Insights data, so they only make sense
// when the cluster sends it.
module observability 'modules/observability.bicep' = if (deployAks && enableContainerInsights) {
  name: 'observability'
  params: {
    location: location
    namePrefix: namePrefix
    workspaceId: monitoring.outputs.workspaceId
    alertEmails: alertEmails
    tags: tags
  }
}

module aks 'modules/aks.bicep' = if (deployAks) {
  name: 'aks'
  params: {
    location: location
    namePrefix: namePrefix
    tier: aksTier
    nodeVmSize: aksNodeVmSize
    nodeCount: aksNodeCount
    osDiskSizeGB: aksOsDiskSizeGB
    logAnalyticsWorkspaceId: enableContainerInsights ? monitoring.outputs.workspaceId : ''
    tags: tags
  }
}

module acr 'modules/acr.bicep' = if (deployAks) {
  name: 'acr'
  params: {
    location: location
    name: 'acr${compactPrefix}${suffix}'
    sku: acrSku
    pullPrincipalIds: deployAks ? [aks!.outputs.kubeletPrincipalId] : []
    tags: tags
  }
}

module clinicalIdentity 'modules/workload-identity.bicep' = if (deployAks) {
  name: 'clinical-identity'
  params: {
    location: location
    name: 'id-${namePrefix}-clinical'
    oidcIssuerUrl: deployAks ? aks!.outputs.oidcIssuerUrl : ''
    serviceAccountNamespaces: appNamespaces
    serviceAccountName: clinicalServiceAccount
    tags: tags
  }
}

module authIdentity 'modules/workload-identity.bicep' = if (deployAks) {
  name: 'auth-identity'
  params: {
    location: location
    name: 'id-${namePrefix}-auth'
    oidcIssuerUrl: deployAks ? aks!.outputs.oidcIssuerUrl : ''
    serviceAccountNamespaces: appNamespaces
    serviceAccountName: authServiceAccount
    tags: tags
  }
}

module postgres 'modules/postgres.bicep' = {
  name: 'postgres'
  params: {
    location: location
    name: 'psql-${namePrefix}-${suffix}'
    administratorLogin: postgresAdministratorLogin
    administratorPassword: postgresAdministratorPassword
    additionalDatabases: additionalDatabases
    skuName: postgresSkuName
    skuTier: postgresSkuTier
    storageSizeGB: postgresStorageGB
    backupRetentionDays: postgresBackupRetentionDays
    highAvailability: postgresHighAvailability
    tags: tags
  }
}

module keyVault 'modules/keyvault.bicep' = {
  name: 'keyvault'
  params: {
    location: location
    name: 'kv-${namePrefix}-${suffix}'
    enablePurgeProtection: keyVaultPurgeProtection
    dbPassword: postgresAdministratorPassword
    jwtSecret: jwtSecret
    authInternalToken: authInternalToken
    seedUserPassword: seedUserPassword
    secretReaderPrincipalIds: deployAks ? [clinicalIdentity!.outputs.principalId, authIdentity!.outputs.principalId] : []
    tags: tags
  }
}

module functionApp 'modules/functionapp.bicep' = {
  name: 'function-app'
  params: {
    location: location
    namePrefix: namePrefix
    storageAccountName: 'st${compactPrefix}${suffix}'
    appInsightsConnectionString: monitoring.outputs.appInsightsConnectionString
    serviceBusFullyQualifiedNamespace: serviceBusFqdn
    alertQueueName: 'toxicity-alerts'
    tags: tags
  }
}

module serviceBus 'modules/servicebus.bicep' = {
  name: 'servicebus'
  params: {
    location: location
    name: serviceBusName
    sku: serviceBusSku
    alertQueueName: 'toxicity-alerts'
    senderPrincipalIds: deployAks ? [clinicalIdentity!.outputs.principalId] : []
    receiverPrincipalIds: [functionApp.outputs.principalId]
    tags: tags
  }
}

output acrLoginServer string = deployAks ? acr!.outputs.loginServer : ''
output aksName string = deployAks ? aks!.outputs.name : ''
output clinicalWorkloadIdentityClientId string = deployAks ? clinicalIdentity!.outputs.clientId : ''
output authWorkloadIdentityClientId string = deployAks ? authIdentity!.outputs.clientId : ''
output keyVaultName string = keyVault.outputs.name
output keyVaultUri string = keyVault.outputs.uri
output postgresFqdn string = postgres.outputs.fqdn
output postgresJdbcUrl string = postgres.outputs.jdbcUrl
output postgresAdministratorLogin string = postgresAdministratorLogin
output serviceBusNamespace string = serviceBus.outputs.fullyQualifiedNamespace
output alertQueueName string = serviceBus.outputs.alertQueueName
output functionAppName string = functionApp.outputs.name
output appInsightsName string = monitoring.outputs.appInsightsName
