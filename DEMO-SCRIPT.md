# SRE Performance Demo - Complete Demo Script

## 🎯 Demo Overview

This demo demonstrates Azure SRE Agent's capability to detect and automatically remediate performance issues caused by CPU-intensive operations in a .NET application. The demo showcases a complete incident response lifecycle similar to the [DeadlockDemoDotNet](https://github.com/BandaruDheeraj/DeadlockDemoDotNet) repository.

## 🏗️ Architecture

```
┌─────────────────┐ ┌─────────────────┐ ┌─────────────────┐
│ .NET App        │ │ App Service     │ │ Application     │
│ (CPU-Intensive) │───▶│ (Slots)        │───▶│ Insights       │
└─────────────────┘ └─────────────────┘ └─────────────────┘
        │                     │                     │
        │                     │                     │
        ▼                     ▼                     ▼
┌─────────────────┐ ┌─────────────────┐ ┌─────────────────┐
│ Performance     │ │ Azure Monitor   │ │ SRE Agent       │
│ Monitoring      │ │ Alerts          │ │ Remediation     │
└─────────────────┘ └─────────────────┘ └─────────────────┘
```

## 🚀 Quick Start

### Prerequisites

- Azure subscription with contributor access
- Azure CLI installed and logged in
- .NET 9.0 SDK
- PowerShell 7.0+
- GitHub account (for issue/PR creation)

### 1. Run Full Demo Sequence

```powershell
cd scripts
.\demo-full-sequence.ps1 -ResourceGroupName "sre-perf-demo-rg" -Location "East US"
```

### 2. Manual Step-by-Step

```powershell
# Step 1: Deploy infrastructure
.\1-deploy-infrastructure.ps1 -ResourceGroupName "sre-perf-demo-rg" -Location "East US"

# Step 2: Deploy healthy app
.\2-deploy-healthy-app.ps1

# Step 3: Deploy CPU-intensive version to staging
.\3-deploy-cpu-intensive-to-staging.ps1

# Step 4: Swap to production (deploy CPU-intensive version)
.\4-swap-to-production.ps1

# Step 5: Generate load to trigger degradation
.\5-generate-load.ps1 -DurationMinutes 10

# Step 6: Monitor SRE Agent remediation
.\6-monitor-sre-agent.ps1 -MonitorMinutes 10
```

## 📊 Demo Timeline

| Time | Phase | Description |
|------|-------|-------------|
| 0-2 min | Deploy | Infrastructure and healthy app deployment |
| 2-4 min | Setup | CPU-intensive version deployed to staging |
| 4-5 min | Deploy | Slot swap deploys CPU-intensive to production |
| 5-10 min | Load | Performance degrades under load |
| 10-15 min | Alert | Azure Monitor alerts fire |
| 15-20 min | Remediation | SRE Agent swaps back to healthy version |

## 🔍 What to Watch

### Azure Portal Tabs

1. **App Service Overview**: Monitor slot status and deployments
2. **Application Insights Live Metrics**: Real-time performance data
3. **Azure Monitor Alerts**: Alert firing and remediation
4. **Log Analytics**: Custom telemetry and CPU-intensive events

### Key Metrics

- **Response Time**: Baseline ~50ms → Degraded >2000ms
- **CPU Usage**: Healthy <20% → Degraded >80%
- **Memory Usage**: Stable → Increasing due to CPU-intensive operations
- **Health Status**: Healthy → Degraded → Unhealthy

## 🧪 CPU-Intensive Pattern

### The Problem

```csharp
// CPU-intensive operations that cause high CPU usage
for (int i = 0; i < 1000000; i++)
{
    // Expensive mathematical operations
    var result = Math.Sqrt(i) * Math.Pow(i, 2) + Math.Sin(i) * Math.Cos(i);
    
    // String operations that consume CPU
    var hash = $"product_{i}_{result}".GetHashCode();
    
    // More CPU work
    if (i % 10000 == 0)
    {
        Thread.Sleep(1); // Brief pause to allow other threads
    }
}
```

### The Fix

```csharp
// Optimized operations with proper resource management
// + Efficient algorithms
// + Proper async/await patterns
// + Resource cleanup
```

## 🔧 Configuration

### Application Settings

```json
{
  "PerformanceSettings": {
    "EnableSlowEndpoints": false,
    "EnableCpuIntensiveEndpoints": false,
    "ResponseTimeThresholdMs": 1000,
    "CpuThresholdPercentage": 80,
    "MemoryThresholdMB": 100
  }
}
```

### Azure Alerts

- **Performance Alert**: Response time > 1000ms for 5 minutes
- **Critical Performance Alert**: Response time > 2000ms for 5 minutes
- **CPU Alert**: CPU usage > 80% for 3 minutes
- **Memory Alert**: Memory usage > 85% for 3 minutes
- **Health Check Alert**: Health check failures

## 📈 API Endpoints

### Fast Endpoints (No CPU-Intensive Operations)

- `GET /api/products` - Product listing (10-50ms)
- `GET /api/products/{id}` - Single product (5-25ms)
- `GET /api/products/search?query={query}` - Search (20-100ms)
- `GET /health` - Health check with metrics

### CPU-Intensive Endpoints (When Enabled)

- `GET /api/cpuintensive` - CPU-intensive product listing (2000-5000ms)
- `GET /api/cpuintensive/{id}` - CPU-intensive single product (1000-3000ms)
- `GET /api/cpuintensive/search?query={query}` - CPU-intensive search (1500-3000ms)
- `GET /api/cpuintensive/cpu-stress` - CPU stress test (30+ seconds)
- `GET /api/cpuintensive/memory-cpu-leak` - Memory and CPU leak simulation

### Monitoring Endpoints

- `GET /health` - Health check with performance data
- `GET /api/featureflag/performance-mode` - Check current mode
- `GET /api/featureflag/metrics` - Get performance metrics
- `POST /api/featureflag/enable-cpu-intensive-mode` - Enable CPU-intensive mode
- `POST /api/featureflag/disable-cpu-intensive-mode` - Disable CPU-intensive mode

## 🚨 SRE Agent Integration

### Alert Remediation Instructions

```json
{
  "remediation_type": "slot_swap",
  "steps": [
    "1. Verify staging slot health",
    "2. Compare production vs staging metrics",
    "3. Execute slot swap if staging is healthier",
    "4. Monitor production for 5 minutes",
    "5. Create incident report"
  ]
}
```

### Expected SRE Agent Actions

1. **Detection**: Azure Monitor alert fires
2. **Analysis**: Compare staging vs production health
3. **Remediation**: Swap staging → production
4. **Verification**: Monitor post-swap metrics
5. **Reporting**: Create incident documentation

## 🔧 Troubleshooting

### Common Issues

1. **Health Check Failures**
   - Verify Application Insights connection
   - Check endpoint accessibility
   - Review memory thresholds

2. **Performance Test Failures**
   - Confirm response time thresholds
   - Check network connectivity
   - Review Application Insights data

3. **Deployment Issues**
   - Ensure Azure CLI is logged in
   - Verify resource group permissions
   - Check Bicep template syntax

### Debug Commands

```bash
# Check application logs
az webapp log tail --name sre-perf-demo-app --resource-group sre-perf-demo-rg

# Check deployment status
az webapp deployment list --name sre-perf-demo-app --resource-group sre-perf-demo-rg

# Manual health check
curl https://sre-perf-demo-app.azurewebsites.net/health

# Check metrics
curl https://sre-perf-demo-app.azurewebsites.net/api/featureflag/metrics
```

## 📚 Learning Objectives

After completing this demo, you will understand:

1. **CPU-Intensive Operations**: How inefficient algorithms cause high CPU usage
2. **Performance Monitoring**: Implementing health checks with custom metrics
3. **Azure Monitor Alerts**: Configuring alerts with remediation instructions
4. **SRE Agent Integration**: Automated incident response workflows
5. **Slot-Based Deployments**: Blue-green deployment patterns
6. **Incident Response**: Complete lifecycle from detection to fix

## 🎯 Next Steps

- Integrate with Azure Monitor for advanced alerting
- Add custom performance counters and dashboards
- Implement distributed tracing with Application Insights
- Set up automated performance regression testing
- Configure SRE runbooks for incident response
- Implement chaos engineering scenarios

## 📁 File Structure

```
PerfDemo/
├── SREPerfDemo/                    # .NET 9.0 Web API
│   ├── Controllers/                # API endpoints
│   │   ├── ProductsController.cs  # Fast endpoints
│   │   ├── SlowProductsController.cs # Slow endpoints
│   │   ├── CpuIntensiveController.cs # CPU-intensive endpoints
│   │   └── FeatureFlagController.cs # Feature flag management
│   ├── PerformanceHealthCheck.cs  # Custom health monitoring
│   ├── PerformanceMiddleware.cs   # Request tracking and metrics
│   ├── PerformanceSettings.cs     # Configuration model
│   └── Program.cs                 # Application configuration
├── infrastructure/                # Azure infrastructure as code
│   └── main.bicep                # App Service, slots, monitoring
├── scripts/                      # Demo automation scripts
│   ├── 1-deploy-infrastructure.ps1
│   ├── 2-deploy-healthy-app.ps1
│   ├── 3-deploy-cpu-intensive-to-staging.ps1
│   ├── 4-swap-to-production.ps1
│   ├── 5-generate-load.ps1
│   ├── 6-monitor-sre-agent.ps1
│   └── demo-full-sequence.ps1
├── .github/workflows/             # GitHub Actions deployment
└── README.md                     # This file
```

## 🎬 Demo Script

### Part 1: Show Healthy Production (2 minutes)

1. **Access production endpoints**:
   ```bash
   curl https://sre-perf-demo-app.azurewebsites.net/health
   curl https://sre-perf-demo-app.azurewebsites.net/api/products
   ```

2. **Show fast response times**: 10-100ms

3. **Show health check**: Returns "Healthy" status

4. **Show Application Insights**: Metrics look good

### Part 2: Show CPU-Intensive Staging (2 minutes)

1. **Access staging CPU-intensive endpoints**:
   ```bash
   curl https://sre-perf-demo-app-staging.azurewebsites.net/api/cpuintensive
   curl https://sre-perf-demo-app-staging.azurewebsites.net/health
   ```

2. **Show slow response times**: 2-5 seconds

3. **Make several requests** to trigger performance degradation:
   ```bash
   for i in {1..10}; do
     curl https://sre-perf-demo-app-staging.azurewebsites.net/api/cpuintensive/cpu-stress
   done
   ```

4. **Show health check degradation**: Health endpoint shows "Unhealthy"

5. **Show Application Insights alerts**: Performance alerts firing

### Part 3: Demonstrate Your Azure SRE Tool (10 minutes)

Now demonstrate how your Azure tool:
1. **Detects** the performance issue in staging
2. **Analyzes** the root cause (CPU-intensive operations, high response times)
3. **Recommends** or **automatically fixes** the issue
4. **Validates** the fix worked

### Part 4: Verify Fix (2 minutes)

After your tool fixes the issue, verify:
```bash
# Check health improved
curl https://sre-perf-demo-app-staging.azurewebsites.net/health

# Check response times improved
curl -w "@time.txt" https://sre-perf-demo-app-staging.azurewebsites.net/api/products
```

---

**Note**: This is a demo application for educational purposes. In production environments, ensure proper security practices, monitoring, and testing procedures are in place.
