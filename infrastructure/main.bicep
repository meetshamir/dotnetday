@description('Name of the App Service')
param appServiceName string = 'sre-perf-demo-app'

@description('Location for all resources')
param location string = resourceGroup().location

@description('App Service Plan SKU')
@allowed([
  'F1'
  'B1'
  'B2'
  'S1'
  'S2'
  'P1v2'
])
param appServicePlanSku string = 'S1'

@description('Application Insights Workspace name')
param workspaceName string = 'sre-perf-demo-workspace'

@description('Cosmos DB account name')
param cosmosDbAccountName string = '${appServiceName}-cosmos'

@description('Cosmos DB throughput (RU/s) - low for throttling demo')
@minValue(400)
@maxValue(10000)
param cosmosDbThroughput int = 400

// App Service Plan
resource appServicePlan 'Microsoft.Web/serverfarms@2023-01-01' = {
  name: '${appServiceName}-plan'
  location: location
  sku: {
    name: appServicePlanSku
  }
  properties: {
    reserved: false
  }
}

// Log Analytics Workspace
resource logAnalyticsWorkspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: workspaceName
  location: location
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
  }
}

// Application Insights
resource applicationInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: '${appServiceName}-ai'
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logAnalyticsWorkspace.id
  }
}

// Cosmos DB Account
resource cosmosDbAccount 'Microsoft.DocumentDB/databaseAccounts@2024-05-15' = {
  name: cosmosDbAccountName
  location: location
  kind: 'GlobalDocumentDB'
  properties: {
    databaseAccountOfferType: 'Standard'
    consistencyPolicy: {
      defaultConsistencyLevel: 'Session'
    }
    locations: [
      {
        locationName: location
        failoverPriority: 0
        isZoneRedundant: false
      }
    ]
    enableFreeTier: false
    disableLocalAuth: true  // Required by MS policy - use Entra ID auth
  }
}

// Cosmos DB Database
resource cosmosDbDatabase 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases@2024-05-15' = {
  parent: cosmosDbAccount
  name: 'ProductsDb'
  properties: {
    resource: {
      id: 'ProductsDb'
    }
  }
}

// Cosmos DB Container with low throughput for throttling demo
resource cosmosDbContainer 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers@2024-05-15' = {
  parent: cosmosDbDatabase
  name: 'Products'
  properties: {
    resource: {
      id: 'Products'
      partitionKey: {
        paths: ['/category']
        kind: 'Hash'
      }
      indexingPolicy: {
        indexingMode: 'consistent'
        automatic: true
        includedPaths: [
          {
            path: '/*'
          }
        ]
      }
    }
    options: {
      throughput: cosmosDbThroughput
    }
  }
}

// App Service
resource appService 'Microsoft.Web/sites@2023-01-01' = {
  name: appServiceName
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: appServicePlan.id
    httpsOnly: true
    siteConfig: {
      netFrameworkVersion: 'v9.0'
      ftpsState: 'Disabled'
      minTlsVersion: '1.2'
      alwaysOn: true
      appSettings: [
        {
          name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
          value: applicationInsights.properties.ConnectionString
        }
        {
          name: 'ApplicationInsightsAgent_EXTENSION_VERSION'
          value: '~3'
        }
        {
          name: 'PerformanceSettings__EnableSlowEndpoints'
          value: 'false'
        }
        {
          name: 'PerformanceSettings__EnableCpuIntensiveEndpoints'
          value: 'false'
        }
        {
          name: 'PerformanceSettings__ResponseTimeThresholdMs'
          value: '1000'
        }
        {
          name: 'PerformanceSettings__CpuThresholdPercentage'
          value: '80'
        }
        {
          name: 'PerformanceSettings__MemoryThresholdMB'
          value: '100'
        }
        {
          name: 'CosmosDb__Endpoint'
          value: cosmosDbAccount.properties.documentEndpoint
        }
        {
          name: 'CosmosDb__UseEntraAuth'
          value: 'true'
        }
        {
          name: 'CosmosDb__DatabaseName'
          value: 'ProductsDb'
        }
        {
          name: 'CosmosDb__ContainerName'
          value: 'Products'
        }
      ]
      healthCheckPath: '/health'
    }
  }
}

// Role assignment for App Service to access Cosmos DB
resource cosmosDbRoleAssignment 'Microsoft.DocumentDB/databaseAccounts/sqlRoleAssignments@2024-05-15' = {
  name: guid(cosmosDbAccount.id, appService.id, 'cosmos-data-contributor')
  parent: cosmosDbAccount
  properties: {
    principalId: appService.identity.principalId
    roleDefinitionId: '${cosmosDbAccount.id}/sqlRoleDefinitions/00000000-0000-0000-0000-000000000002' // Cosmos DB Built-in Data Contributor
    scope: cosmosDbAccount.id
  }
}

// Staging Slot
resource stagingSlot 'Microsoft.Web/sites/slots@2023-01-01' = {
  parent: appService
  name: 'staging'
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: appServicePlan.id
    siteConfig: {
      netFrameworkVersion: 'v9.0'
      alwaysOn: true
      appSettings: [
        {
          name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
          value: applicationInsights.properties.ConnectionString
        }
        {
          name: 'ApplicationInsightsAgent_EXTENSION_VERSION'
          value: '~3'
        }
        {
          name: 'PerformanceSettings__EnableSlowEndpoints'
          value: 'false'
        }
        {
          name: 'PerformanceSettings__EnableCpuIntensiveEndpoints'
          value: 'false'
        }
        {
          name: 'PerformanceSettings__ResponseTimeThresholdMs'
          value: '1000'
        }
        {
          name: 'PerformanceSettings__CpuThresholdPercentage'
          value: '80'
        }
        {
          name: 'PerformanceSettings__MemoryThresholdMB'
          value: '100'
        }
        {
          name: 'CosmosDb__Endpoint'
          value: cosmosDbAccount.properties.documentEndpoint
        }
        {
          name: 'CosmosDb__UseEntraAuth'
          value: 'true'
        }
        {
          name: 'CosmosDb__DatabaseName'
          value: 'ProductsDb'
        }
        {
          name: 'CosmosDb__ContainerName'
          value: 'Products'
        }
      ]
      healthCheckPath: '/health'
    }
  }
}

// Role assignment for Staging Slot to access Cosmos DB
resource cosmosDbRoleAssignmentStaging 'Microsoft.DocumentDB/databaseAccounts/sqlRoleAssignments@2024-05-15' = {
  name: guid(cosmosDbAccount.id, stagingSlot.id, 'cosmos-data-contributor-staging')
  parent: cosmosDbAccount
  properties: {
    principalId: stagingSlot.identity.principalId
    roleDefinitionId: '${cosmosDbAccount.id}/sqlRoleDefinitions/00000000-0000-0000-0000-000000000002' // Cosmos DB Built-in Data Contributor
    scope: cosmosDbAccount.id
  }
}

// Action Group for Alerts (optional - for email/SMS notifications)
resource alertActionGroup 'Microsoft.Insights/actionGroups@2023-01-01' = {
  name: '${appServiceName}-alert-action-group'
  location: 'global'
  properties: {
    groupShortName: 'SREPerfAG'
    enabled: true
    emailReceivers: []
    smsReceivers: []
    webhookReceivers: []
  }
}

// Performance Alert Rules
resource responseTimeAlert 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: '${appServiceName}-response-time-alert'
  location: 'global'
  properties: {
    description: 'Alert when average response time exceeds 1000ms threshold - indicates performance degradation. REMEDIATION: Perform deployment slot swap to restore healthy version from staging slot.'
    severity: 2
    enabled: true
    autoMitigate: false
    scopes: [
      appService.id
    ]
    evaluationFrequency: 'PT1M'
    windowSize: 'PT5M'
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          name: 'ResponseTime'
          metricName: 'HttpResponseTime'
          operator: 'GreaterThan'
          threshold: 1
          timeAggregation: 'Average'
          criterionType: 'StaticThresholdCriterion'
        }
      ]
    }
    actions: [
      {
        actionGroupId: alertActionGroup.id
      }
    ]
  }
}

// Critical Performance Alert - High Response Time
resource criticalResponseTimeAlert 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: '${appServiceName}-critical-response-time-alert'
  location: 'global'
  properties: {
    description: 'CRITICAL: Average response time exceeds 2000ms - severe performance degradation. REMEDIATION: Immediately perform deployment slot swap to restore healthy version from staging slot.'
    severity: 1
    enabled: true
    autoMitigate: false
    scopes: [
      appService.id
    ]
    evaluationFrequency: 'PT1M'
    windowSize: 'PT5M'
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          name: 'CriticalResponseTime'
          metricName: 'HttpResponseTime'
          operator: 'GreaterThan'
          threshold: 2
          timeAggregation: 'Average'
          criterionType: 'StaticThresholdCriterion'
        }
      ]
    }
    actions: [
      {
        actionGroupId: alertActionGroup.id
      }
    ]
  }
}

// Application Insights-based Performance Alert
resource appInsightsPerformanceAlert 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: '${appServiceName}-app-insights-perf-alert'
  location: 'global'
  properties: {
    description: 'Alert on Application Insights server response time degradation (>1000ms average). REMEDIATION: Perform deployment slot swap to restore healthy version from staging slot.'
    severity: 2
    enabled: true
    autoMitigate: false
    scopes: [
      applicationInsights.id
    ]
    evaluationFrequency: 'PT1M'
    windowSize: 'PT5M'
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          name: 'ServerResponseTime'
          metricNamespace: 'Microsoft.Insights/components'
          metricName: 'requests/duration'
          operator: 'GreaterThan'
          threshold: 1000
          timeAggregation: 'Average'
          criterionType: 'StaticThresholdCriterion'
        }
      ]
    }
    actions: [
      {
        actionGroupId: alertActionGroup.id
      }
    ]
  }
}

resource cpuAlert 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: '${appServiceName}-cpu-alert'
  location: 'global'
  properties: {
    description: 'Alert when CPU usage is high (>60 seconds total CPU time in 5 minutes). REMEDIATION: Investigate CPU-intensive operations and consider deployment slot swap if degradation persists.'
    severity: 2
    enabled: true
    autoMitigate: false
    scopes: [
      appService.id
    ]
    evaluationFrequency: 'PT1M'
    windowSize: 'PT5M'
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          name: 'CpuTime'
          metricName: 'CpuTime'
          operator: 'GreaterThan'
          threshold: 60
          timeAggregation: 'Total'
          criterionType: 'StaticThresholdCriterion'
        }
      ]
    }
    actions: []
  }
}

resource memoryAlert 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: '${appServiceName}-memory-alert'
  location: 'global'
  properties: {
    description: 'Alert when memory usage is high (>1GB working set). REMEDIATION: Investigate memory leaks and consider deployment slot swap if degradation persists.'
    severity: 2
    enabled: true
    autoMitigate: false
    scopes: [
      appService.id
    ]
    evaluationFrequency: 'PT1M'
    windowSize: 'PT5M'
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          name: 'MemoryWorkingSet'
          metricName: 'MemoryWorkingSet'
          operator: 'GreaterThan'
          threshold: 1000000000
          timeAggregation: 'Average'
          criterionType: 'StaticThresholdCriterion'
        }
      ]
    }
    actions: []
  }
}

// Smart Detection - Failure Anomalies Alert
resource failureAnomaliesAlert 'Microsoft.AlertsManagement/smartDetectorAlertRules@2021-04-01' = {
  name: '${appServiceName}-failure-anomalies'
  location: 'global'
  properties: {
    description: 'Smart Detection: Failure Anomalies detects unusual increases in failed request rate. REMEDIATION: Perform deployment slot swap to restore healthy version from staging slot.'
    state: 'Enabled'
    severity: 'Sev3'
    frequency: 'PT1M'
    detector: {
      id: 'FailureAnomaliesDetector'
    }
    scope: [
      applicationInsights.id
    ]
    actionGroups: {
      groupIds: [
        alertActionGroup.id
      ]
    }
  }
}

// Cosmos DB Throttling Alert
resource cosmosDbThrottlingAlert 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: '${cosmosDbAccountName}-throttling-alert'
  location: 'global'
  properties: {
    description: 'Alert when Cosmos DB is experiencing throttling (429 errors). REMEDIATION: Increase provisioned throughput (RU/s) or optimize queries to reduce RU consumption.'
    severity: 1
    enabled: true
    autoMitigate: false
    scopes: [
      cosmosDbAccount.id
    ]
    evaluationFrequency: 'PT1M'
    windowSize: 'PT5M'
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          name: 'TotalRequestsThrottled'
          metricName: 'TotalRequests'
          operator: 'GreaterThan'
          threshold: 0
          timeAggregation: 'Count'
          criterionType: 'StaticThresholdCriterion'
          dimensions: [
            {
              name: 'StatusCode'
              operator: 'Include'
              values: ['429']
            }
          ]
        }
      ]
    }
    actions: [
      {
        actionGroupId: alertActionGroup.id
      }
    ]
  }
}

// Cosmos DB High RU Consumption Alert
resource cosmosDbRuAlert 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: '${cosmosDbAccountName}-ru-consumption-alert'
  location: 'global'
  properties: {
    description: 'Alert when Cosmos DB RU consumption is approaching limit (>80%). REMEDIATION: Increase provisioned throughput or optimize query patterns.'
    severity: 2
    enabled: true
    autoMitigate: false
    scopes: [
      cosmosDbAccount.id
    ]
    evaluationFrequency: 'PT1M'
    windowSize: 'PT5M'
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          name: 'NormalizedRUConsumption'
          metricName: 'NormalizedRUConsumption'
          operator: 'GreaterThan'
          threshold: 80
          timeAggregation: 'Maximum'
          criterionType: 'StaticThresholdCriterion'
        }
      ]
    }
    actions: [
      {
        actionGroupId: alertActionGroup.id
      }
    ]
  }
}

// Output values
output appServiceName string = appService.name
output appServiceUrl string = 'https://${appService.properties.defaultHostName}'
output stagingUrl string = 'https://${replace(appService.properties.defaultHostName, '.azurewebsites.net', '-staging.azurewebsites.net')}'
output applicationInsightsConnectionString string = applicationInsights.properties.ConnectionString
output applicationInsightsInstrumentationKey string = applicationInsights.properties.InstrumentationKey
output cosmosDbEndpoint string = cosmosDbAccount.properties.documentEndpoint
output cosmosDbAccountName string = cosmosDbAccount.name