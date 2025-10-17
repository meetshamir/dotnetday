# SRE Performance Demo Application

This demo application demonstrates automated performance monitoring, detection of performance regressions, and automatic rollback capabilities using Azure App Service, Application Insights, and Azure DevOps/GitHub Actions.

## 🎯 Demo Scenario

The application simulates a real-world scenario where:
1. **Good Performance Version**: Fast API endpoints with proper optimization
2. **Performance Regression**: Slow endpoints that cause latency issues
3. **Automatic Detection**: Performance monitoring detects the regression
4. **Automatic Rollback**: System automatically rolls back to the previous healthy version

## 🏗️ Architecture

```
┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐
│   GitHub/Azure  │    │   App Service   │    │ Application     │
│   DevOps        │    │   (Staging +    │    │ Insights        │
│   Pipeline      │───▶│   Production)   │───▶│ Monitoring      │
└─────────────────┘    └─────────────────┘    └─────────────────┘
        │                       │                       │
        │                       │                       │
        ▼                       ▼                       ▼
┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐
│ Performance     │    │ Health Checks   │    │ Alerts &        │
│ Tests           │    │ /health         │    │ Notifications   │
└─────────────────┘    └─────────────────┘    └─────────────────┘
```

## 🚀 Quick Start

### Prerequisites

- Azure CLI installed and logged in
- .NET 9.0 SDK installed
- PowerShell (for deployment script)

### 1. Deploy the Application

```powershell
# Clone and navigate to the demo
cd PerfDemo

# Run the deployment script
./deploy.ps1 -ResourceGroupName "sre-perf-demo-rg" -Location "East US"
```

### 2. Verify Deployment

```bash
# Check health endpoint
curl https://your-app-name.azurewebsites.net/health

# Test good performance endpoints
curl https://your-app-name.azurewebsites.net/api/products
curl https://your-app-name.azurewebsites.net/api/products/1
curl https://your-app-name.azurewebsites.net/api/products/search?query=test
```

## 📊 API Endpoints

### Good Performance Endpoints (Fast)
- `GET /api/products` - List products (10-50ms response time)
- `GET /api/products/{id}` - Get single product (5-25ms response time)
- `GET /api/products/search?query={query}` - Search products (20-100ms response time)

### Poor Performance Endpoints (Slow - for demo)
- `GET /api/slowproducts` - Slow product listing (2-5 second response time)
- `GET /api/slowproducts/{id}` - Slow product lookup (multiple database calls)
- `GET /api/slowproducts/search?query={query}` - Inefficient search (1.5-3 second response time)
- `GET /api/slowproducts/memory-leak` - Simulates memory leak

### Monitoring Endpoints
- `GET /health` - Health check with performance data
- `GET /api/featureflag/performance-mode` - Get current performance mode
- `GET /api/featureflag/metrics` - Get application metrics
- `POST /api/featureflag/enable-slow-mode` - Enable slow mode (for demo)
- `POST /api/featureflag/disable-slow-mode` - Disable slow mode

## 🧪 Demo Scenarios

### Scenario 1: Normal Deployment

1. Deploy the application with good performance
2. Performance tests pass (< 1000ms average response time)
3. Application deploys to production successfully
4. Monitoring shows healthy metrics

### Scenario 2: Performance Regression Detection

1. Enable slow mode via feature flag or configuration
2. Deploy the application with poor performance endpoints
3. Performance tests detect regression (> 1000ms average response time)
4. Deployment is blocked before reaching production
5. Application remains on previous healthy version

### Scenario 3: Production Performance Issue & Rollback

1. Deploy application that passes initial tests
2. Performance degradation occurs after deployment
3. Application Insights alerts fire
4. Health checks fail
5. Automatic rollback is triggered
6. Previous version is restored

## 🔧 Performance Monitoring Features

### Built-in Health Checks
- **Performance Health Check**: Tracks response times (average, max, 95th percentile)
- **Memory Health Check**: Monitors memory usage and GC pressure
- **Custom Health Check**: Includes performance data in response

### Application Insights Integration
- Response time tracking
- Custom performance metrics
- Memory usage monitoring
- Error rate tracking
- Dependency tracking

### Performance Thresholds
- **Healthy**: Average response time < 500ms
- **Degraded**: Average response time 500ms - 1000ms
- **Unhealthy**: Average response time > 1000ms
- **Memory Warning**: Memory usage > 100MB

## 🚨 Alert Configuration

The application includes pre-configured alerts for:

1. **Response Time Alert**: Triggers when average response time > 1000ms
2. **CPU Usage Alert**: Triggers when CPU usage > 80%
3. **Memory Usage Alert**: Triggers when memory usage > 85%
4. **Health Check Alert**: Triggers when health checks fail

## 🔄 Deployment Pipeline Features

### Azure Pipelines (azure-pipelines.yml)
- Build and test validation
- Deploy to staging slot
- Performance validation on staging
- Blue-green deployment with slot swapping
- Automatic rollback on failure
- Continuous monitoring setup

### GitHub Actions (.github/workflows/deploy.yml)
- Similar pipeline with GitHub Actions
- Performance testing with configurable thresholds
- Manual slow mode trigger for demos
- Comprehensive health checking

## 🛠️ Configuration

### Application Settings

```json
{
  "ApplicationInsights": {
    "ConnectionString": "InstrumentationKey=your-key-here"
  },
  "PerformanceSettings": {
    "EnableSlowEndpoints": false,
    "ResponseTimeThresholdMs": 1000
  }
}
```

### Environment Variables
- `APPLICATIONINSIGHTS_CONNECTION_STRING`: Application Insights connection string
- `PerformanceSettings__EnableSlowEndpoints`: Enable/disable slow endpoints
- `PerformanceSettings__ResponseTimeThresholdMs`: Response time threshold for alerts

## 📈 Monitoring Dashboard

Once deployed, you can monitor the application through:

1. **Azure Portal**: Application Insights dashboard
2. **Health Endpoint**: `/health` - JSON response with current status
3. **Metrics Endpoint**: `/api/featureflag/metrics` - Current application metrics
4. **Application Insights Live Metrics**: Real-time performance data

## 🎭 Demo Script

### Part 1: Show Good Performance (5 minutes)
1. Show healthy application endpoints
2. Demonstrate fast response times
3. Show health check returning "Healthy"
4. Show Application Insights metrics

### Part 2: Simulate Performance Regression (10 minutes)
1. Trigger slow mode: `POST /api/featureflag/enable-slow-mode`
2. Show slow endpoint responses
3. Demonstrate health check detecting issues
4. Show Application Insights alerts firing
5. Show how deployment would be blocked

### Part 3: Show Rollback Process (5 minutes)
1. Explain how production rollback would work
2. Show slot swapping capabilities
3. Demonstrate recovery to healthy state
4. Show monitoring confirming recovery

## 🔧 Troubleshooting

### Common Issues

1. **Health Check Failures**
   - Check Application Insights connection
   - Verify endpoint accessibility
   - Check memory thresholds

2. **Performance Test Failures**
   - Verify response time thresholds
   - Check network connectivity
   - Review Application Insights data

3. **Deployment Issues**
   - Ensure Azure CLI is logged in
   - Verify resource group permissions
   - Check Bicep template syntax

### Debug Commands

```bash
# Check application logs
az webapp log tail --name your-app-name --resource-group your-rg

# Check deployment status
az webapp deployment list --name your-app-name --resource-group your-rg

# Manual health check
curl -v https://your-app-name.azurewebsites.net/health
```

## 📚 Learning Objectives

By the end of this demo, attendees will understand:

1. How to implement performance monitoring in .NET applications
2. How to set up automated performance testing in CI/CD pipelines
3. How to configure Application Insights for performance tracking
4. How to implement health checks with performance data
5. How to set up automatic rollback mechanisms
6. How to configure alerts for performance regressions
7. How to use Azure App Service deployment slots for blue-green deployments

## 🎯 Next Steps

- Integrate with Azure Monitor for advanced alerting
- Add custom performance counters
- Implement distributed tracing with Application Insights
- Set up automated performance regression testing
- Configure SRE runbooks for incident response
- Implement chaos engineering scenarios

---

**Note**: This is a demo application. In production environments, ensure proper security practices, monitoring, and testing procedures are in place.