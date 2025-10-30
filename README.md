# SRE Performance Demo - Consolidated Guide

> **Last Updated**: This guide reflects the current codebase with recent fixes:
> - ✅ Alert thresholds corrected (HttpResponseTime uses seconds, not milliseconds)
> - ✅ Smart Detection (Failure Anomalies) alert configured
> - ✅ Error-spike endpoint added (85% error rate for testing)
> - ✅ Always On enabled, auto-resolve disabled on all alerts
> - ✅ Script 5 job handling fixed (`-Wait` and `-Force` flags added)
> - ✅ All scripts use text markers instead of emojis for PowerShell compatibility
> - ✅ CPU and Memory metrics use correct names (`CpuTime`, `MemoryWorkingSet`)
> - ✅ Build artifacts added to .gitignore

## Table of Contents
1. [Overview](#overview)
2. [Application Architecture](#application-architecture)
3. [Azure Infrastructure](#azure-infrastructure)
4. [Monitoring & Alerts](#monitoring--alerts)
5. [Demo Flow](#demo-flow)
6. [API Endpoints](#api-endpoints)
7. [Scripts Reference](#scripts-reference)
8. [Troubleshooting](#troubleshooting)

---

## Overview

This demo showcases Site Reliability Engineering (SRE) practices for detecting and responding to performance degradation in Azure App Service. It simulates a real-world scenario where CPU-intensive code is accidentally deployed to production, triggers alerts, and demonstrates automated remediation.

### Key Concepts Demonstrated
- **Performance Monitoring**: Application Insights telemetry and custom health checks
- **Azure Monitor Alerts**: Automated alerting based on performance metrics
- **Deployment Slots**: Blue-green deployment pattern with staging/production slots
- **Automated Remediation**: Slot swap to restore service health
- **Incident Response**: Complete lifecycle from detection to resolution

### Prerequisites
- Azure subscription with Contributor access
- Azure CLI installed and logged in (`az login`)
- .NET 9.0 SDK
- PowerShell 7.0+
- 30 minutes for complete demo

---

## Application Architecture

### Technology Stack
- **Framework**: ASP.NET Core 9.0 Web API
- **Language**: C# .NET 9.0
- **Hosting**: Azure App Service (Windows)
- **Monitoring**: Application Insights + Azure Monitor
- **Deployment**: Azure CLI + Bicep IaC

### Application Components

```
SREPerfDemo (ASP.NET Core Web API)
│
├── Controllers/
│   ├── ProductsController.cs          # Fast/healthy endpoints (10-100ms)
│   ├── CpuIntensiveController.cs      # CPU-intensive endpoints (2000-5000ms)
│   ├── SlowProductsController.cs      # Legacy slow endpoints
│   └── FeatureFlagController.cs       # Performance mode control
│
├── PerformanceHealthCheck.cs          # Custom health check monitoring
├── PerformanceMiddleware.cs           # Request tracking & metrics
├── PerformanceSettings.cs             # Configuration model
└── Program.cs                         # App configuration & startup
```

### Key Application Features

#### 1. **PerformanceMiddleware** (Request Tracking)
- Tracks every HTTP request response time
- Records metrics to PerformanceHealthCheck
- Sends telemetry to Application Insights
- Adds `X-Response-Time-Ms` header to responses

#### 2. **PerformanceHealthCheck** (Custom Health Monitoring)
- Maintains rolling window of last 100 response times
- Evaluates health based on:
  - **Healthy**: Average < 1000ms AND P95 < 2000ms
  - **Degraded**: P95 > 2000ms (but average < 1000ms)
  - **Unhealthy**: Average > 1000ms
- Returns detailed metrics: avg, max, p95, sample count

#### 3. **Fast Endpoints** (`/api/products`)
- In-memory data simulation
- Minimal processing
- Response times: 10-100ms
- **This is the healthy version**

#### 4. **CPU-Intensive Endpoints** (`/api/cpuintensive`)
- Simulates inefficient algorithms
- Heavy mathematical computations:
  ```csharp
  for (int i = 0; i < 1000000; i++)
  {
      var result = Math.Sqrt(i) * Math.Pow(i, 2) + Math.Sin(i) * Math.Cos(i);
      var hash = $"product_{i}_{result}".GetHashCode();
  }
  ```
- Response times: 2000-15000ms (2-15 seconds)
- **This is the degraded version**

#### 5. **Feature Flag Controller**
- Runtime performance mode switching
- Endpoints:
  - `GET /api/featureflag/performance-mode` - Check current mode
  - `POST /api/featureflag/enable-cpu-intensive-mode` - Enable degradation
  - `POST /api/featureflag/disable-cpu-intensive-mode` - Restore performance
  - `GET /api/featureflag/metrics` - Get performance stats

---

## Azure Infrastructure

### Resource Topology

```
Azure Resource Group (sre-perf-demo-rg)
│
├── App Service Plan (S1 SKU)
│   └── Supports deployment slots
│
├── App Service (sre-perf-demo-app-XXXX)
│   ├── Production Slot
│   │   └── Initially: Healthy version
│   │
│   └── Staging Slot
│       └── CPU-intensive version deployed here
│
├── Application Insights (sre-perf-demo-app-XXXX-ai)
│   ├── Request telemetry
│   ├── Performance metrics
│   └── Custom health check data
│
├── Log Analytics Workspace (sre-perf-demo-workspace)
│   └── 30-day retention
│
├── Action Group (sre-perf-demo-app-XXXX-alert-action-group)
│   └── Notification target for alerts
│
└── Metric Alerts (5 total)
    ├── Response Time Alert (>1 second)
    ├── Critical Response Time Alert (>2 seconds)
    ├── App Insights Performance Alert (>1 second)
    ├── CPU Alert (>60 seconds total CPU time)
    └── Memory Alert (>1GB working set)
```

### Infrastructure as Code (Bicep)

**File**: `infrastructure/main.bicep`

Key resources deployed:
1. **App Service Plan**: S1 SKU (required for deployment slots)
2. **App Service**: With production + staging slots
3. **Application Insights**: Connected to Log Analytics
4. **Log Analytics Workspace**: Centralized logging
5. **Alert Rules**: 5 metric alerts
6. **Action Group**: Alert notification handler

### App Service Configuration

**App Settings (Both Slots)**:
```json
{
  "APPLICATIONINSIGHTS_CONNECTION_STRING": "[from Application Insights]",
  "ApplicationInsightsAgent_EXTENSION_VERSION": "~3",
  "PerformanceSettings__EnableSlowEndpoints": "false",
  "PerformanceSettings__EnableCpuIntensiveEndpoints": "false",
  "PerformanceSettings__ResponseTimeThresholdMs": "1000",
  "PerformanceSettings__CpuThresholdPercentage": "80",
  "PerformanceSettings__MemoryThresholdMB": "100"
}
```

---

## Monitoring & Alerts

### Alert Configuration

#### 1. Response Time Alert (Warning - Severity 2)
- **Metric**: `HttpResponseTime` (App Service metric)
- **Threshold**: > 1 second (average)
- **Unit**: Seconds
- **Window**: 5 minutes
- **Evaluation Frequency**: Every 1 minute
- **Action**: Triggers Action Group

#### 2. Critical Response Time Alert (Critical - Severity 1)
- **Metric**: `HttpResponseTime` (App Service metric)
- **Threshold**: > 2 seconds (average)
- **Unit**: Seconds
- **Window**: 5 minutes
- **Evaluation Frequency**: Every 1 minute
- **Action**: Triggers Action Group

#### 3. Application Insights Performance Alert (Warning - Severity 2)
- **Metric**: `requests/duration` (Application Insights metric)
- **Threshold**: > 1000 milliseconds (average)
- **Unit**: Milliseconds
- **Window**: 5 minutes
- **Evaluation Frequency**: Every 1 minute
- **Action**: Triggers Action Group

#### 4. CPU Alert (Warning - Severity 2)
- **Metric**: `CpuTime` (App Service metric)
- **Threshold**: > 60 seconds (total)
- **Unit**: Seconds
- **Window**: 5 minutes
- **Evaluation Frequency**: Every 1 minute
- **Action**: None (monitoring only)

#### 5. Memory Alert (Warning - Severity 2)
- **Metric**: `MemoryWorkingSet` (App Service metric)
- **Threshold**: > 1GB (1,000,000,000 bytes)
- **Unit**: Bytes
- **Window**: 5 minutes
- **Evaluation Frequency**: Every 1 minute
- **Action**: None (monitoring only)

### Alert Flow

```
1. Performance Degradation
   └─> HttpResponseTime metric increases (3-15 seconds)
       └─> Azure Monitor evaluates every 1 minute
           └─> After 5 minutes of sustained high response times
               └─> Alert fires (both Response Time alerts)
                   └─> Action Group receives notification
                       └─> SRE Agent can trigger remediation
```

### Where Alerts Go

**Action Group** (`sre-perf-demo-app-XXXX-alert-action-group`):
- **Short Name**: `SREPerfAG`
- **Enabled**: Yes
- **Actions**: Currently empty (can be configured for):
  - Email notifications
  - SMS notifications
  - Webhook to SRE Agent
  - Logic Apps
  - Azure Functions
  - Automation Runbooks

**To add email notifications**:
```powershell
az monitor action-group update \
  --name sre-perf-demo-app-XXXX-alert-action-group \
  --resource-group sre-perf-demo-rg \
  --add-email name=admin email=admin@example.com
```

### Viewing Fired Alerts

**Azure Portal**:
1. Navigate to Resource Group → `sre-perf-demo-rg`
2. Click "Alerts" in left menu
3. View "Fired" alerts tab
4. Filter by severity or resource

**Azure CLI**:
```powershell
# List all alerts in resource group
az monitor metrics alert list \
  --resource-group sre-perf-demo-rg \
  --output table

# View alert history
az monitor activity-log list \
  --resource-group sre-perf-demo-rg \
  --query "[?contains(eventName.value, 'Alert')]"
```

### Application Insights Views

**Live Metrics** (Real-time):
- Navigate to Application Insights → Live Metrics
- View real-time request rates, response times, failures
- See server performance (CPU, memory)

**Performance** (Historical):
- Navigate to Application Insights → Performance
- View slowest operations
- Drill into individual requests
- See dependency calls

**Metrics Explorer**:
- Navigate to Application Insights → Metrics
- Chart metrics: `requests/duration`, `requests/count`, `requests/failed`
- Compare production vs staging

---

## Demo Flow

### Complete Demo Timeline (30 minutes)

```
┌─────────────────────────────────────────────────────────────────────┐
│ Time    │ Phase        │ Action                    │ Expected Result │
├─────────────────────────────────────────────────────────────────────┤
│ 0-5 min │ Setup        │ Run script 1              │ Infrastructure  │
│         │              │ (Deploy infrastructure)   │ deployed        │
├─────────────────────────────────────────────────────────────────────┤
│ 5-8 min │ Baseline     │ Run script 2              │ Healthy prod    │
│         │              │ (Deploy healthy app)      │ (~100ms avg)    │
├─────────────────────────────────────────────────────────────────────┤
│ 8-11min │ Staging      │ Run script 3              │ CPU-intensive   │
│         │              │ (Deploy to staging)       │ in staging only │
├─────────────────────────────────────────────────────────────────────┤
│ 11-13   │ Bad Deploy   │ Run script 4              │ Prod degraded   │
│  min    │              │ (Swap to production)      │ (~3-15s avg)    │
├─────────────────────────────────────────────────────────────────────┤
│ 13-18   │ Load Test    │ Run script 5              │ Sustained high  │
│  min    │              │ (Generate load, 5 min)    │ response times  │
├─────────────────────────────────────────────────────────────────────┤
│ 18-20   │ Alert        │ Wait for alerts           │ Alerts fire     │
│  min    │              │                           │ (5 min window)  │
├─────────────────────────────────────────────────────────────────────┤
│ 20-25   │ Remediation  │ SRE Agent detects         │ Automatic swap  │
│  min    │              │ & remediates              │ back to healthy │
├─────────────────────────────────────────────────────────────────────┤
│ 25-30   │ Verification │ Run script 6              │ Production      │
│  min    │              │ (Monitor recovery)        │ healthy again   │
└─────────────────────────────────────────────────────────────────────┘
```

### Step-by-Step Demo Instructions

#### Step 1: Deploy Infrastructure (5 minutes)

**Run**:
```powershell
cd scripts
.\1-deploy-infrastructure.ps1
```

**What it does**:
- Creates resource group
- Deploys Bicep template
- Creates App Service with slots
- Sets up Application Insights
- Configures 5 alert rules
- Saves configuration to `demo-config.json`

**Expected Output**:
```
Production URL: https://sre-perf-demo-app-XXXX.azurewebsites.net
Staging URL: https://sre-perf-demo-app-XXXX-staging.azurewebsites.net
```

**Verify**:
- Resource group exists in Azure Portal
- App Service created with staging slot
- Application Insights connected
- 5 alert rules visible

---

#### Step 2: Deploy Healthy Application (3 minutes)

**Run**:
```powershell
.\2-deploy-healthy-app.ps1
```

**What it does**:
- Builds .NET application
- Publishes to ZIP package
- Deploys to **production slot only**
- Runs health checks
- Tests fast endpoints

**Expected Output**:
```
Health Status: Healthy
Average Response Time: ~50-100ms
Fast requests (<500ms): 9/9
```

**Verify**:
```powershell
# Test production endpoint
curl https://sre-perf-demo-app-XXXX.azurewebsites.net/health

# Expected response:
{
  "status": "Healthy",
  "checks": [
    {
      "name": "performance",
      "status": "Healthy",
      "description": "Performance is good. Avg: 75.23ms, P95: 95.67ms"
    }
  ]
}
```

---

#### Step 3: Deploy CPU-Intensive to Staging (3 minutes)

**Run**:
```powershell
.\3-deploy-cpu-intensive-to-staging.ps1
```

**What it does**:
- Builds same application
- Deploys to **staging slot only**
- Enables CPU-intensive endpoints via app settings
- Runs performance tests on staging
- Production remains unaffected

**Expected Output**:
```
Health Status: Degraded or Unhealthy
Average Response Time: ~2000-5000ms
Slow requests (>1000ms): 6/6
```

**Verify**:
```powershell
# Test staging endpoint (will be SLOW)
curl https://sre-perf-demo-app-XXXX-staging.azurewebsites.net/api/cpuintensive

# Check health (will show Unhealthy)
curl https://sre-perf-demo-app-XXXX-staging.azurewebsites.net/health
```

**At this point**:
- Production: Healthy, fast ✅
- Staging: Degraded, slow ⚠️

---

#### Step 4: Swap to Production (2 minutes)

**Run**:
```powershell
.\4-swap-to-production.ps1
```

**What it does**:
- Performs Azure slot swap
- CPU-intensive code → Production
- Healthy code → Staging
- Runs immediate performance tests

**Expected Output**:
```
[WARNING] BAD DEPLOYMENT IN PRODUCTION!
Average Response Time: ~3000-4000ms
Slow requests (>1000ms): 4/4
```

**Verify**:
```powershell
# Test production (now SLOW)
curl https://sre-perf-demo-app-XXXX.azurewebsites.net/api/cpuintensive

# Check health
curl https://sre-perf-demo-app-XXXX.azurewebsites.net/health
```

**At this point**:
- Production: Degraded, slow ⚠️ **BAD DEPLOYMENT**
- Staging: Healthy, fast ✅

---

#### Step 5: Generate Load (5 minutes)

**Run**:
```powershell
.\5-generate-load.ps1 -DurationMinutes 5
```

**What it does**:
- Spawns 5 concurrent users
- Each user makes random requests to CPU-intensive endpoints
- Runs for 5 minutes continuous load
- Collects detailed statistics

**Expected Output**:
```
Duration: 5 minutes
Total Requests: 83
Success Rate: 50.6%
Average Response Time: 9799.88ms (9.8 seconds)
95th Percentile: 26130ms (26 seconds)
Slow Requests: 38/42 successful requests

[WARNING] PERFORMANCE DEGRADED DETECTED
Azure Monitor alerts should fire within 5 minutes
```

**During this step**:
- Application Insights Live Metrics shows high response times
- CPU usage spikes
- Request duration metrics exceed thresholds

**Monitor in Azure Portal**:
1. Open Application Insights → Live Metrics
2. Watch response times go red (>1000ms)
3. See request rate and failure rate

---

#### Step 6: Wait for Alerts (2-5 minutes)

**What happens**:
- Azure Monitor evaluates metrics every 1 minute
- Needs 5 minutes of sustained high response times
- After 5-minute window: Alerts fire

**Check alert status**:
```powershell
# List all alerts
az monitor metrics alert list \
  --resource-group sre-perf-demo-rg \
  --output table

# Check if alerts are firing
az monitor activity-log list \
  --resource-group sre-perf-demo-rg \
  --query "[?contains(eventName.value, 'Alert')]"
```

**In Azure Portal**:
1. Navigate to Resource Group → Alerts
2. View "Fired" tab
3. Should see:
   - Response Time Alert (Severity 2)
   - Critical Response Time Alert (Severity 1)
   - Possibly App Insights Performance Alert

**Expected Alerts**:
- ✅ Response Time Alert: Average > 1 second
- ✅ Critical Response Time Alert: Average > 2 seconds
- ⚠️ CPU Alert: May or may not fire depending on load
- ❌ Memory Alert: Unlikely to fire (not memory-intensive)

---

#### Step 7: SRE Agent Remediation (5 minutes)

**This is where your SRE Agent would intervene!**

**Manual remediation (if no SRE Agent)**:
```powershell
# Swap back to healthy version
az webapp deployment slot swap \
  --resource-group sre-perf-demo-rg \
  --name sre-perf-demo-app-XXXX \
  --slot staging \
  --target-slot production
```

**What the SRE Agent should do**:
1. **Detect**: Alert fires → SRE Agent receives notification
2. **Analyze**:
   - Check current production metrics (degraded)
   - Check staging metrics (healthy)
   - Identify root cause: High CPU, slow responses
3. **Remediate**:
   - Execute slot swap: staging → production
   - Healthy version returns to production
4. **Verify**:
   - Monitor for 5 minutes
   - Confirm response times < 1000ms
   - Confirm alerts resolve
5. **Report**:
   - Create incident report
   - Document timeline and actions taken

---

#### Step 8: Verify Recovery (5 minutes)

**Run**:
```powershell
.\6-monitor-sre-agent.ps1 -MonitorMinutes 5
```

**OR manually verify**:
```powershell
# Check production health (should be Healthy)
curl https://sre-perf-demo-app-XXXX.azurewebsites.net/health

# Test fast endpoint
curl https://sre-perf-demo-app-XXXX.azurewebsites.net/api/products

# Generate test load
for ($i=1; $i -le 10; $i++) {
  curl https://sre-perf-demo-app-XXXX.azurewebsites.net/api/products
}
```

**Expected Results**:
- Health status: Healthy ✅
- Average response time: <100ms
- Alerts resolved within 5 minutes
- Application Insights shows recovery

---

## API Endpoints

### Health & Monitoring Endpoints

#### GET `/health`
**Purpose**: Health check with performance metrics

**Response**:
```json
{
  "status": "Healthy",
  "checks": [
    {
      "name": "performance",
      "status": "Healthy",
      "description": "Performance is good. Avg: 75.23ms, P95: 95.67ms",
      "data": {
        "avgResponseTimeMs": 75.23,
        "maxResponseTimeMs": 150.45,
        "p95ResponseTimeMs": 95.67,
        "sampleCount": 100
      }
    },
    {
      "name": "memory",
      "status": "Healthy",
      "description": "Memory usage: 45MB"
    }
  ],
  "totalDuration": 5.23
}
```

**Health States**:
- **Healthy**: Avg < 1000ms AND P95 < 2000ms
- **Degraded**: P95 > 2000ms (but avg < 1000ms)
- **Unhealthy**: Avg > 1000ms

---

### Fast/Healthy Endpoints (Production Default)

#### GET `/api/products`
**Purpose**: List all products (fast version)
**Response Time**: 10-50ms
**Response**:
```json
[
  { "id": 1, "name": "Product 1", "price": 19.99, "stock": 100 },
  { "id": 2, "name": "Product 2", "price": 29.99, "stock": 50 }
]
```

#### GET `/api/products/{id}`
**Purpose**: Get single product
**Response Time**: 5-25ms
**Response**:
```json
{ "id": 1, "name": "Product 1", "price": 19.99, "stock": 100 }
```

#### GET `/api/products/search?query={query}`
**Purpose**: Search products
**Response Time**: 20-100ms
**Response**:
```json
[
  { "id": 1, "name": "Product 1", "price": 19.99, "stock": 100 }
]
```

---

### CPU-Intensive Endpoints (Staging / Bad Deployment)

#### GET `/api/cpuintensive`
**Purpose**: List products with CPU-intensive operations
**Response Time**: 2000-5000ms (2-5 seconds)
**Simulation**: 1,000,000 iterations of Math.Sqrt, Math.Pow, Math.Sin, Math.Cos

#### GET `/api/cpuintensive/{id}`
**Purpose**: Get single product (CPU-intensive)
**Response Time**: 1000-3000ms (1-3 seconds)
**Simulation**: 500,000 iterations

#### GET `/api/cpuintensive/search?query={query}`
**Purpose**: Search with CPU-intensive operations
**Response Time**: 1500-3000ms (1.5-3 seconds)

#### GET `/api/cpuintensive/cpu-stress`
**Purpose**: Extreme CPU stress test
**Response Time**: 30+ seconds
**Simulation**: 5,000,000 iterations

#### GET `/api/cpuintensive/memory-cpu-leak`
**Purpose**: Memory and CPU leak simulation
**Response Time**: 20-30 seconds
**Side Effects**: Allocates memory, high CPU, simulates leak

---

### Feature Flag Management

#### GET `/api/featureflag/performance-mode`
**Purpose**: Check current performance mode
**Response**:
```json
{
  "cpuIntensiveEnabled": false,
  "slowEndpointsEnabled": false
}
```

#### POST `/api/featureflag/enable-cpu-intensive-mode`
**Purpose**: Enable CPU-intensive endpoints (degradation)
**Response**:
```json
{ "message": "CPU-intensive mode enabled" }
```

#### POST `/api/featureflag/disable-cpu-intensive-mode`
**Purpose**: Disable CPU-intensive endpoints (restore performance)
**Response**:
```json
{ "message": "CPU-intensive mode disabled" }
```

#### GET `/api/featureflag/metrics`
**Purpose**: Get detailed performance metrics
**Response**:
```json
{
  "avgResponseTimeMs": 75.23,
  "maxResponseTimeMs": 150.45,
  "p95ResponseTimeMs": 95.67,
  "requestCount": 100,
  "cpuIntensiveEnabled": false,
  "slowEndpointsEnabled": false
}
```

---

## Scripts Reference

### Script 1: `1-deploy-infrastructure.ps1`

**Purpose**: Deploy all Azure infrastructure

**Parameters**:
- `ResourceGroupName` (optional): Default `sre-perf-demo-rg`
- `AppServiceName` (optional): Auto-generated if not provided
- `Location` (optional): Default `eastus`

**Usage**:
```powershell
.\1-deploy-infrastructure.ps1 -Location "westus2"
```

**Creates**:
- Resource group
- App Service Plan (S1 SKU)
- App Service (with staging slot)
- Application Insights
- Log Analytics Workspace
- 5 metric alert rules
- 1 action group

**Duration**: ~3-5 minutes

---

### Script 2: `2-deploy-healthy-app.ps1`

**Purpose**: Deploy healthy/fast application to production

**Parameters**:
- `ResourceGroupName` (optional): Uses config from script 1
- `AppServiceName` (optional): Uses config from script 1

**Usage**:
```powershell
.\2-deploy-healthy-app.ps1
```

**Actions**:
- Builds .NET application
- Creates deployment ZIP
- Deploys to production slot
- Runs health checks
- Tests fast endpoints

**Duration**: ~2-3 minutes

---

### Script 3: `3-deploy-cpu-intensive-to-staging.ps1`

**Purpose**: Deploy CPU-intensive version to staging only

**Parameters**:
- `ResourceGroupName` (optional)
- `AppServiceName` (optional)

**Usage**:
```powershell
.\3-deploy-cpu-intensive-to-staging.ps1
```

**Actions**:
- Builds application
- Deploys to staging slot only
- Enables CPU-intensive mode via app settings
- Runs performance tests
- Production remains unaffected

**Duration**: ~2-3 minutes

---

### Script 4: `4-swap-to-production.ps1`

**Purpose**: Swap staging to production (simulate bad deployment)

**Parameters**:
- `ResourceGroupName` (optional)
- `AppServiceName` (optional)

**Usage**:
```powershell
.\4-swap-to-production.ps1
```

**Actions**:
- Performs slot swap
- CPU-intensive → Production
- Healthy → Staging
- Runs immediate tests

**Duration**: ~1-2 minutes

---

### Script 5: `5-generate-load.ps1`

**Purpose**: Generate sustained load to trigger alerts

**Parameters**:
- `ResourceGroupName` (optional)
- `AppServiceName` (optional)
- `DurationMinutes` (optional): Default 10 minutes
- `ConcurrentUsers` (optional): Default 5 users

**Usage**:
```powershell
.\5-generate-load.ps1 -DurationMinutes 5 -ConcurrentUsers 10
```

**Actions**:
- Spawns concurrent PowerShell jobs (users)
- Each user makes random requests
- Targets CPU-intensive endpoints
- Collects statistics
- Reports results

**Duration**: Configurable (5-10 minutes recommended)

---

### Script 6: `6-monitor-sre-agent.ps1`

**Purpose**: Monitor SRE Agent remediation and recovery

**Parameters**:
- `ResourceGroupName` (optional)
- `AppServiceName` (optional)
- `MonitorMinutes` (optional): Default 10 minutes

**Usage**:
```powershell
.\6-monitor-sre-agent.ps1 -MonitorMinutes 5
```

**Actions**:
- Monitors health endpoint
- Checks alert status
- Tracks response times
- Reports recovery progress

**Duration**: Configurable

---

## Troubleshooting

### Common Issues

#### 1. Alerts Not Firing

**Symptoms**:
- No alerts visible in Azure Portal
- Alert rules exist but never trigger

**Causes & Solutions**:

**Issue**: Not enough sustained load
- **Solution**: Run script 5 for at least 5 minutes with sufficient concurrent users
- Alerts require 5-minute window of degraded metrics

**Issue**: Incorrect metric thresholds ⚠️ **COMMON ISSUE - FIXED IN CURRENT VERSION**
- **Root Cause**: The Azure Monitor metric `HttpResponseTime` is measured in **seconds**, but it was initially configured with thresholds of 1000 and 2000 (thinking they were milliseconds). This meant alerts would only fire for response times > 1000 seconds (16+ minutes)!
- **Solution (Already Applied)**: The Bicep template has been corrected to use:
  - HttpResponseTime: > **1 second** (not 1000)
  - Critical HttpResponseTime: > **2 seconds** (not 2000)
  - requests/duration (Application Insights): > 1000 milliseconds (this one was correct - App Insights uses milliseconds)
- **Verify** your deployment has correct thresholds:
  ```powershell
  az monitor metrics alert show \
    --name sre-perf-demo-app-XXXX-response-time-alert \
    --resource-group sre-perf-demo-rg \
    --query "criteria.allOf[0].threshold"
  # Should return: 1 (not 1000)
  ```

**Issue**: Alert rules not enabled
- **Solution**:
  ```powershell
  az monitor metrics alert update \
    --name sre-perf-demo-app-XXXX-response-time-alert \
    --resource-group sre-perf-demo-rg \
    --enabled true
  ```

**Issue**: Metrics not being collected
- **Solution**:
  - Verify Application Insights connection string
  - Check app is sending telemetry
  - View Application Insights → Metrics

**Debugging**:
```powershell
# Check if metrics are being collected
az monitor metrics list \
  --resource-group sre-perf-demo-rg \
  --resource-type "Microsoft.Web/sites" \
  --resource sre-perf-demo-app-XXXX \
  --metric HttpResponseTime

# Check alert evaluation history
az monitor activity-log list \
  --resource-group sre-perf-demo-rg \
  --query "[?contains(eventName.value, 'Alert')]"
```

---

#### 2. Health Endpoint Shows Healthy (But Should Be Unhealthy)

**Symptoms**:
- `/health` returns "Healthy" even after deploying CPU-intensive code

**Causes & Solutions**:

**Issue**: No requests made yet
- **Solution**: The health check tracks last 100 requests. Make some requests:
  ```powershell
  for ($i=1; $i -le 10; $i++) {
    curl https://sre-perf-demo-app-XXXX.azurewebsites.net/api/cpuintensive
  }
  ```

**Issue**: Fast endpoints being called
- **Solution**: Ensure you're hitting `/api/cpuintensive` endpoints, not `/api/products`

**Issue**: CPU-intensive mode not enabled
- **Solution**: Check if enabled:
  ```powershell
  curl https://sre-perf-demo-app-XXXX.azurewebsites.net/api/featureflag/performance-mode
  ```
- Enable if needed:
  ```powershell
  curl -X POST https://sre-perf-demo-app-XXXX.azurewebsites.net/api/featureflag/enable-cpu-intensive-mode
  ```

---

#### 3. Deployment Fails

**Symptoms**:
- Scripts fail with errors
- Resources not created

**Common Errors**:

**Error**: `App Service name already exists`
- **Cause**: Name must be globally unique
- **Solution**: Use custom name:
  ```powershell
  .\1-deploy-infrastructure.ps1 -AppServiceName "my-unique-name-12345"
  ```

**Error**: `Bicep deployment failed - Invalid metric name` ⚠️ **FIXED IN CURRENT VERSION**
- **Cause**: Bicep template used incorrect metric names that don't exist in Azure Monitor
- **Solution (Already Applied)**: Corrected metric names:
  - ✅ Use `CpuTime` (not `CpuPercentage`) - measures total CPU seconds
  - ✅ Use `MemoryWorkingSet` (not `MemoryPercentage`) - measures bytes
  - ✅ Use `HttpResponseTime` (not `AverageResponseTime`) - measures seconds
- All deployments now use correct metric names

**Error**: PowerShell script parsing errors with emoji characters ⚠️ **FIXED IN CURRENT VERSION**
- **Cause**: Emoji Unicode characters in PowerShell scripts caused encoding issues
- **Solution (Already Applied)**: All scripts now use text markers:
  - `[SUCCESS]` instead of ✅
  - `[INFO]` instead of ℹ️
  - `[WARNING]` instead of ⚠️
  - `[ERROR]` instead of ❌
  - `[STEP]` instead of 🚀/🔥
- See scripts 1-6 for updated output formatting

**Error**: `Insufficient permissions`
- **Cause**: Need Contributor role
- **Solution**: Request permissions or use different subscription

**Error**: `.NET SDK not found`
- **Cause**: .NET 9.0 not installed
- **Solution**: Install from https://dotnet.microsoft.com/download

---

#### 4. Slow Performance in BOTH Slots

**Symptoms**:
- Both production and staging are slow

**Cause**: Slot swap confusion

**Solution**: Check which version is where:
```powershell
# Check production
curl https://sre-perf-demo-app-XXXX.azurewebsites.net/api/featureflag/performance-mode

# Check staging
curl https://sre-perf-demo-app-XXXX-staging.azurewebsites.net/api/featureflag/performance-mode
```

If both show `cpuIntensiveEnabled: true`, swap back:
```powershell
.\4-swap-to-production.ps1  # Swaps staging → production
```

---

#### 5. Load Generation Script Fails

**Symptoms**:
- Script 5 errors out
- Jobs fail to complete

**Common Errors**:

**Error**: `Remove-Job: Job cannot be removed` ⚠️ **FIXED IN CURRENT VERSION**
- **Cause**: PowerShell jobs weren't fully completed before attempting removal
- **Solution (Already Applied)**: Script updated with proper job handling:
  ```powershell
  # OLD (caused errors):
  $result = Receive-Job -Job $task
  Remove-Job -Job $task

  # NEW (current version):
  $result = Receive-Job -Job $task -Wait  # Wait for completion
  Remove-Job -Job $task -Force            # Force removal
  ```
- This fix is in `scripts/5-generate-load.ps1` line 189-190

**Error**: `Connection timeout`
- **Cause**: App not responding
- **Solution**:
  - Restart app service
  - Check Application Insights logs
  - Increase timeout in script

**Error**: `No requests succeed`
- **Cause**: App crashed or overwhelmed
- **Solution**:
  - Reduce concurrent users: `-ConcurrentUsers 2`
  - Check app service logs
  - Restart app service

---

### Debugging Commands

#### Check App Service Status
```powershell
# View app status
az webapp show \
  --name sre-perf-demo-app-XXXX \
  --resource-group sre-perf-demo-rg \
  --query "{Name:name, State:state, DefaultHostName:defaultHostName}"

# View deployment history
az webapp deployment list \
  --name sre-perf-demo-app-XXXX \
  --resource-group sre-perf-demo-rg \
  --output table
```

#### Check Application Insights
```powershell
# Get connection string
az monitor app-insights component show \
  --app sre-perf-demo-app-XXXX-ai \
  --resource-group sre-perf-demo-rg \
  --query "connectionString"
```

#### View Logs
```powershell
# Stream application logs
az webapp log tail \
  --name sre-perf-demo-app-XXXX \
  --resource-group sre-perf-demo-rg

# Download logs
az webapp log download \
  --name sre-perf-demo-app-XXXX \
  --resource-group sre-perf-demo-rg \
  --log-file logs.zip
```

#### Test Endpoints Manually
```powershell
# Test health
curl https://sre-perf-demo-app-XXXX.azurewebsites.net/health

# Test fast endpoint
Measure-Command {
  curl https://sre-perf-demo-app-XXXX.azurewebsites.net/api/products
}

# Test CPU-intensive endpoint
Measure-Command {
  curl https://sre-perf-demo-app-XXXX.azurewebsites.net/api/cpuintensive
}
```

---

## Cleanup

### Delete All Resources

**Complete cleanup**:
```powershell
az group delete \
  --name sre-perf-demo-rg \
  --yes \
  --no-wait
```

**Delete specific app service only** (keep infrastructure):
```powershell
az webapp delete \
  --name sre-perf-demo-app-XXXX \
  --resource-group sre-perf-demo-rg
```

---

## Learning Resources

### Azure Documentation
- [Azure Monitor Alerts](https://learn.microsoft.com/azure/azure-monitor/alerts/alerts-overview)
- [Application Insights](https://learn.microsoft.com/azure/azure-monitor/app/app-insights-overview)
- [App Service Deployment Slots](https://learn.microsoft.com/azure/app-service/deploy-staging-slots)
- [Bicep Documentation](https://learn.microsoft.com/azure/azure-resource-manager/bicep/)

### ASP.NET Core
- [Health Checks](https://learn.microsoft.com/aspnet/core/host-and-deploy/health-checks)
- [Middleware](https://learn.microsoft.com/aspnet/core/fundamentals/middleware/)
- [Configuration](https://learn.microsoft.com/aspnet/core/fundamentals/configuration/)

### Performance
- [Performance Best Practices](https://learn.microsoft.com/aspnet/core/performance/performance-best-practices)
- [Monitoring and Diagnostics](https://learn.microsoft.com/azure/architecture/best-practices/monitoring)

---

## Summary

This demo provides a complete SRE workflow:

1. ✅ **Deploy** infrastructure and baseline application
2. ⚠️ **Introduce** performance regression (CPU-intensive code)
3. 🚨 **Detect** via Azure Monitor alerts (automatic)
4. 🔧 **Remediate** via slot swap (automatic or manual)
5. ✅ **Verify** service recovery

**Key Takeaways**:
- Blue-green deployments enable quick rollback
- Health checks provide application-level monitoring
- Azure Monitor provides infrastructure-level alerting
- Custom metrics enhance observability
- Automated remediation reduces MTTR (Mean Time To Recovery)

---

**For questions or issues, refer to the troubleshooting section or check Azure Portal logs.**
