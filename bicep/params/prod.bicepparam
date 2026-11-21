// prod: SLA-backed control plane, 2 nodes, Container Insights, longer backups and purge protection.
// 2 x D2s_v4 = 4 vCPU = the whole DSv4 quota of the student subscription.
// Secrets come from environment variables (GitHub environment "prod" secrets in CI).
using '../main.bicep'

param environmentName = 'prod'

param deployAks = true
param aksTier = 'Standard'
param aksNodeVmSize = 'Standard_D2s_v4'
param aksOsDiskSizeGB = 64
param aksNodeCount = 2
param enableContainerInsights = true

param acrSku = 'Standard'
param postgresSkuName = 'Standard_B2s'
param postgresSkuTier = 'Burstable'
param postgresStorageGB = 64
param postgresBackupRetentionDays = 14
param postgresHighAvailability = false

param serviceBusSku = 'Basic'
param keyVaultPurgeProtection = true
param logRetentionDays = 90
param logDailyQuotaGb = 5

param postgresAdministratorPassword = readEnvironmentVariable('DB_ADMIN_PASSWORD', '')
param jwtSecret = readEnvironmentVariable('JWT_SECRET', '')
param authInternalToken = readEnvironmentVariable('AUTH_INTERNAL_TOKEN', '')
param seedUserPassword = readEnvironmentVariable('SEED_USER_PASSWORD', '')
