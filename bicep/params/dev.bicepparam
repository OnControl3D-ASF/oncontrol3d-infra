// dev: smallest footprint that runs the whole platform (2 nodes: auth, clinical, imaging, frontend, Orthanc, Traefik) within the Azure for Students budget.
// Region comes from the resource group: brazilsouth. Azure for Students only allows 5 regions;
// PostgreSQL is restricted in eastus/southcentralus, Flex Consumption is missing in chilecentral and
// canadacentral only offers ARM64 (Bpsv2) sizes with quota. Standard_D2s_v4 (x86, 2 vCPU, 8 GB)
// is enabled for the subscription with quota (DSv4 = 4 vCPU). See docs/iac.md.
// Secrets come from environment variables (GitHub environment "dev" secrets in CI).
using '../main.bicep'

param environmentName = 'dev'

param deployAks = true
param aksTier = 'Free'
param aksNodeVmSize = 'Standard_D2s_v4'
param aksOsDiskSizeGB = 32
param aksNodeCount = 2
param enableContainerInsights = false

param acrSku = 'Basic'
param postgresSkuName = 'Standard_B1ms'
param postgresSkuTier = 'Burstable'
param postgresStorageGB = 32
param postgresBackupRetentionDays = 7
param postgresHighAvailability = false

param serviceBusSku = 'Basic'
param keyVaultPurgeProtection = false
param logRetentionDays = 30
param logDailyQuotaGb = 1

param postgresAdministratorPassword = readEnvironmentVariable('DB_ADMIN_PASSWORD', '')
param jwtSecret = readEnvironmentVariable('JWT_SECRET', '')
param authInternalToken = readEnvironmentVariable('AUTH_INTERNAL_TOKEN', '')
param seedUserPassword = readEnvironmentVariable('SEED_USER_PASSWORD', '')
