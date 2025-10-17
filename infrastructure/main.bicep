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

// App Service
resource appService 'Microsoft.Web/sites@2023-01-01' = {
  name: appServiceName
  location: location
  properties: {
    serverFarmId: appServicePlan.id
    httpsOnly: true
    siteConfig: {
      netFrameworkVersion: 'v9.0'
      ftpsState: 'Disabled'
      minTlsVersion: '1.2'
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
      ]
      healthCheckPath: '/health'
    }
  }
}

// Staging Slot
resource stagingSlot 'Microsoft.Web/sites/slots@2023-01-01' = {
  parent: appService
  name: 'staging'
  location: location
  properties: {
    serverFarmId: appServicePlan.id
    siteConfig: {
      netFrameworkVersion: 'v9.0'
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
      ]
      healthCheckPath: '/health'
    }
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
    description: 'Alert when average response time exceeds 1000ms threshold - indicates performance degradation'
    severity: 2
    enabled: true
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

// Critical Performance Alert - High Response Time
resource criticalResponseTimeAlert 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: '${appServiceName}-critical-response-time-alert'
  location: 'global'
  properties: {
    description: 'CRITICAL: Average response time exceeds 2000ms - severe performance degradation'
    severity: 1
    enabled: true
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
          threshold: 2000
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
    description: 'Alert on Application Insights server response time degradation'
    severity: 2
    enabled: true
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
    description: 'Alert when CPU usage is high'
    severity: 2
    enabled: true
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
    description: 'Alert when memory usage is high'
    severity: 2
    enabled: true
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

// Output values
output appServiceName string = appService.name
output appServiceUrl string = 'https://${appService.properties.defaultHostName}'
output stagingUrl string = 'https://${replace(appService.properties.defaultHostName, '.azurewebsites.net', '-staging.azurewebsites.net')}'
output applicationInsightsConnectionString string = applicationInsights.properties.ConnectionString
output applicationInsightsInstrumentationKey string = applicationInsights.properties.InstrumentationKey