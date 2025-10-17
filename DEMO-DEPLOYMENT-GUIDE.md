# SRE Performance Demo - Deployment Guide

## Overview
This demo has two versions of the application ready to deploy:
- **Healthy Version**: Fast endpoints (`/api/products`) - 10-100ms response times
- **Unhealthy Version**: Slow endpoints (`/api/slowproducts`) - 2-5 second response times

## Demo Scenario
Deploy the healthy version to one slot and the unhealthy version to another slot, then demonstrate how your Azure tool can detect and fix the unhealthy deployment.

---

## Prerequisites

1. **Azure CLI** installed and logged in:
   ```bash
   az login
   ```

2. **.NET 9.0 SDK** installed

3. **PowerShell** (for deployment script)

---

## Quick Deployment Guide

### Step 1: Deploy Infrastructure

Run the deployment script to create the Azure resources:

```powershell
./deploy.ps1 -ResourceGroupName "sre-perf-demo-rg" -Location "eastus"
```

This creates:
- App Service Plan
- App Service with staging and production slots
- Application Insights
- Performance alerts

### Step 2: Deploy Healthy Version to Production Slot

The deployment script already deploys to production by default. After running the script above, the **healthy version** will be in production.

**Production URL**: `https://sre-perf-demo-app.azurewebsites.net`

**Healthy Endpoints**:
- `GET /api/products` (10-50ms)
- `GET /api/products/{id}` (5-25ms)
- `GET /api/products/search?query=test` (20-100ms)
- `GET /health` (shows "Healthy")

### Step 3: Deploy Unhealthy Version to Staging Slot

To create the unhealthy version, you need to modify the startup configuration to route to slow endpoints.

**Option A: Manual Deployment with Environment Variable**

1. Build the application:
   ```powershell
   cd SREPerfDemo
   dotnet publish --configuration Release --output ./publish
   Compress-Archive -Path "./publish/*" -DestinationPath "./deploy.zip" -Force
   ```

2. Deploy to staging slot:
   ```bash
   az webapp deployment source config-zip \
     --resource-group sre-perf-demo-rg \
     --name sre-perf-demo-app \
     --slot staging \
     --src ./deploy.zip
   ```

3. Configure staging to use slow endpoints:
   ```bash
   az webapp config appsettings set \
     --resource-group sre-perf-demo-rg \
     --name sre-perf-demo-app \
     --slot staging \
     --settings PerformanceSettings__EnableSlowEndpoints=true
   ```

**Staging URL**: `https://sre-perf-demo-app-staging.azurewebsites.net`

**Unhealthy Endpoints** (use these in staging):
- `GET /api/slowproducts` (2-5 seconds)
- `GET /api/slowproducts/{id}` (1-3 seconds with N+1 queries)
- `GET /api/slowproducts/search?query=test` (1.5-3 seconds)
- `GET /api/slowproducts/memory-leak` (causes memory issues)
- `GET /health` (will show "Unhealthy" after some requests)

---

## Demo Workflow

### Part 1: Show Healthy Production (2 minutes)

1. **Access production endpoints**:
   ```bash
   curl https://sre-perf-demo-app.azurewebsites.net/health
   curl https://sre-perf-demo-app.azurewebsites.net/api/products
   ```

2. **Show fast response times**: 10-100ms

3. **Show health check**: Returns "Healthy" status

4. **Show Application Insights**: Metrics look good

### Part 2: Show Unhealthy Staging (2 minutes)

1. **Access staging slow endpoints**:
   ```bash
   curl https://sre-perf-demo-app-staging.azurewebsites.net/api/slowproducts
   curl https://sre-perf-demo-app-staging.azurewebsites.net/health
   ```

2. **Show slow response times**: 2-5 seconds

3. **Make several requests** to trigger performance degradation:
   ```bash
   for i in {1..10}; do
     curl https://sre-perf-demo-app-staging.azurewebsites.net/api/slowproducts
   done
   ```

4. **Show health check degradation**: Health endpoint shows "Unhealthy"

5. **Show Application Insights alerts**: Performance alerts firing

### Part 3: Demonstrate Your Azure SRE Tool (10 minutes)

Now demonstrate how your Azure tool:
1. **Detects** the performance issue in staging
2. **Analyzes** the root cause (slow endpoints, high response times)
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

## Monitoring Endpoints

These endpoints help during your demo:

1. **Health Check**:
   ```bash
   GET /health
   ```
   Returns detailed health status with performance metrics

2. **Current Metrics**:
   ```bash
   GET /api/featureflag/metrics
   ```
   Returns memory usage, GC stats

3. **Performance Mode**:
   ```bash
   GET /api/featureflag/performance-mode
   ```
   Shows if slow endpoints are enabled

---

## Key Differences Between Versions

| Aspect | Healthy Version | Unhealthy Version |
|--------|----------------|-------------------|
| **Route** | `/api/products` | `/api/slowproducts` |
| **Response Time** | 10-100ms | 2,000-5,000ms |
| **Database Queries** | Optimized, indexed | N+1 queries, full scans |
| **Processing** | Efficient | Unnecessary sorting, loops |
| **Memory** | Stable | Memory leak simulation |
| **Health Status** | "Healthy" | "Unhealthy" after load |

---

## Application Insights Queries

Use these queries to show performance differences:

```kusto
// Average response time by endpoint
requests
| where timestamp > ago(1h)
| summarize avg(duration), max(duration), percentile(duration, 95) by name
| order by avg_duration desc

// Slow requests (>1 second)
requests
| where timestamp > ago(1h)
| where duration > 1000
| project timestamp, name, duration, resultCode
| order by timestamp desc

// Health check results
requests
| where name contains "health"
| project timestamp, name, duration, resultCode, customDimensions
| order by timestamp desc
```

---

## Troubleshooting

### If staging is not unhealthy:
Make multiple requests to slow endpoints:
```bash
for i in {1..20}; do
  curl https://sre-perf-demo-app-staging.azurewebsites.net/api/slowproducts
done
```

### If you need to reset:
Restart the slot:
```bash
az webapp restart \
  --resource-group sre-perf-demo-rg \
  --name sre-perf-demo-app \
  --slot staging
```

### To swap slots manually (if needed):
```bash
az webapp deployment slot swap \
  --resource-group sre-perf-demo-rg \
  --name sre-perf-demo-app \
  --slot staging \
  --target-slot production
```

---

## Cleanup

When done with the demo:

```bash
az group delete --name sre-perf-demo-rg --yes --no-wait
```

---

## Architecture Summary

```
┌─────────────────────────────────────────────────────┐
│             App Service (sre-perf-demo-app)         │
├─────────────────────────────────────────────────────┤
│                                                     │
│  Production Slot                Staging Slot        │
│  ┌──────────────────┐          ┌──────────────────┐│
│  │ HEALTHY          │          │ UNHEALTHY        ││
│  │                  │          │                  ││
│  │ /api/products    │          │ /api/slowproducts││
│  │ 10-100ms         │          │ 2-5 seconds      ││
│  │                  │          │                  ││
│  │ Status: Healthy  │          │ Status: Unhealthy││
│  └──────────────────┘          └──────────────────┘│
│            │                            │           │
│            └────────────┬───────────────┘           │
│                         │                           │
│                         ▼                           │
│              Application Insights                   │
│              - Performance Metrics                  │
│              - Health Monitoring                    │
│              - Alerts                               │
└─────────────────────────────────────────────────────┘
```

---

## Ready to Demo!

Your application is now ready with:
- ✅ Builds successfully
- ✅ Healthy endpoints in production
- ✅ Unhealthy endpoints available for staging
- ✅ Health checks configured
- ✅ Application Insights monitoring
- ✅ Performance alerts configured

Deploy both versions to different slots and demonstrate your Azure SRE tool fixing the performance issues!
