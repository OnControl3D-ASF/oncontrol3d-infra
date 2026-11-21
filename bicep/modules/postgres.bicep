// Azure Database for PostgreSQL - Flexible Server (same major version as local/tests: 16).

@description('Azure region.')
param location string

@description('Globally unique server name.')
param name string

@description('Administrator login.')
param administratorLogin string

@secure()
@description('Administrator password (from a CI secret, also stored in Key Vault).')
param administratorPassword string

@description('Database created for the Clinical Service.')
param databaseName string = 'OnControlSem'

@description('Extra databases on the same server (e.g. auth service, prod namespace). Free on a flexible server.')
param additionalDatabases array = []

@description('Compute SKU, e.g. Standard_B1ms (Burstable).')
param skuName string = 'Standard_B1ms'

@allowed([
  'Burstable'
  'GeneralPurpose'
  'MemoryOptimized'
])
param skuTier string = 'Burstable'

@minValue(32)
param storageSizeGB int = 32

@minValue(7)
@maxValue(35)
param backupRetentionDays int = 7

@description('Zone-redundant high availability (doubles the compute cost).')
param highAvailability bool = false

param tags object = {}

resource server 'Microsoft.DBforPostgreSQL/flexibleServers@2025-08-01' = {
  name: name
  location: location
  tags: tags
  sku: {
    name: skuName
    tier: skuTier
  }
  properties: {
    version: '16'
    administratorLogin: administratorLogin
    administratorLoginPassword: administratorPassword
    storage: {
      storageSizeGB: storageSizeGB
    }
    backup: {
      backupRetentionDays: backupRetentionDays
      geoRedundantBackup: 'Disabled'
    }
    highAvailability: {
      mode: highAvailability ? 'ZoneRedundant' : 'Disabled'
    }
    network: {
      publicNetworkAccess: 'Enabled'
    }
  }
}

resource database 'Microsoft.DBforPostgreSQL/flexibleServers/databases@2025-08-01' = {
  parent: server
  name: databaseName
  properties: {
    charset: 'UTF8'
    collation: 'en_US.utf8'
  }
}

// ARM rejects concurrent database writes on one server: create them one at a time.
@batchSize(1)
resource extraDatabases 'Microsoft.DBforPostgreSQL/flexibleServers/databases@2025-08-01' = [for dbName in additionalDatabases: {
  parent: server
  name: dbName
  properties: {
    charset: 'UTF8'
    collation: 'en_US.utf8'
  }
  dependsOn: [
    database
  ]
}]

// 0.0.0.0 - 0.0.0.0 = "allow Azure services" (AKS egress). TLS is enforced by default
// (require_secure_transport=on). Private networking is the production follow-up
// documented in docs/iac.md.
resource allowAzure 'Microsoft.DBforPostgreSQL/flexibleServers/firewallRules@2025-08-01' = {
  parent: server
  name: 'AllowAzureServices'
  properties: {
    startIpAddress: '0.0.0.0'
    endIpAddress: '0.0.0.0'
  }
}

output name string = server.name
output fqdn string = server.properties.fullyQualifiedDomainName
output databaseName string = database.name
output jdbcUrl string = 'jdbc:postgresql://${server.properties.fullyQualifiedDomainName}:5432/${database.name}?sslmode=require'
