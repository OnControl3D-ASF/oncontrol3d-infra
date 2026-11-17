// dev: smallest footprint that runs the whole platform within the Azure for Students budget.
// Secrets come from environment variables (GitHub environment "dev" secrets in CI).
using '../main.bicep'

param environmentName = 'dev'

param deployAks = true
param aksTier = 'Free'
param aksNodeVmSize = 'Standard_D2as_v5'
param aksNodeCount = 1
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
