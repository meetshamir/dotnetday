# SRE Performance Demo - Setup and Usage Guide

## Overview

This demo showcases Site Reliability Engineering (SRE) practices for monitoring and managing application performance in Azure. It demonstrates how to:

1. Deploy a healthy application to production
2. Set up Azure Monitor alerts for performance degradation
3. Deploy a performance-degraded version to staging to trigger alerts
4. Observe the monitoring and alerting system in action

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    GitHub Actions Workflows                  │
├──────────────────────┬──────────────────────────────────────┤
│  deploy-healthy.yml  │  deploy-bad-performance.yml          │
│  ↓                   │  ↓                                    │
│  Production Slot     │  Staging Slot                         │
└──────────────────────┴──────────────────────────────────────┘
                         ↓
            ┌────────────────────────┐
            │  Azure Monitor Alerts  │
            ├────────────────────────┤
            │ • Response Time > 1s   │
            │ • Response Time > 2s   │
            │ • CPU > 80%            │
            │ • Memory > 85%         │
            └────────────────────────┘
                         ↓
            ┌────────────────────────┐
            │ Application Insights   │
            │ Performance Tracking   │
            └────────────────────────┘
```

## Prerequisites

1. **Azure Subscription** with permissions to create:
   - App Service
   - Application Insights
   - Log Analytics Workspace
   - Azure Monitor Alerts

2. **GitHub Repository** with:
   - Actions enabled
   - Required secrets configured

3. **Azure CLI** installed locally (for manual deployments)

## Setup Instructions

### Step 1: Deploy Infrastructure

Deploy the Azure resources using Bicep:

```bash
# Login to Azure
az login

# Create resource group
az group create --name sre-perf-demo-rg --location eastus

# Deploy infrastructure
az deployment group create \
  --resource-group sre-perf-demo-rg \
  --template-file infrastructure/main.bicep \
  --parameters appServiceName=sre-perf-demo-app
```

This creates:
- App Service Plan (B1 SKU)
- App Service with Production slot
- Staging deployment slot
- Log Analytics Workspace
- Application Insights
- Azure Monitor Alert Rules:
  - **Warning Alert**: Response time > 1000ms (Severity 2)
  - **Critical Alert**: Response time > 2000ms (Severity 1)
  - **App Insights Alert**: Server response time > 1000ms (Severity 2)
  - CPU Alert: > 80%
  - Memory Alert: > 85%

### Step 2: Configure GitHub Secrets

Add the following secrets to your GitHub repository:

1. **AZURE_CREDENTIALS**: Azure service principal credentials

```bash
# Create service principal
az ad sp create-for-rbac \
  --name "sre-perf-demo-sp" \
  --role contributor \
  --scopes /subscriptions/{subscription-id}/resourceGroups/sre-perf-demo-rg \
  --sdk-auth
```

Copy the JSON output and add it as `AZURE_CREDENTIALS` secret in GitHub.

### Step 3: Configure Azure Monitor Alert Actions (Optional)

To receive email/SMS notifications when alerts fire:

```bash
# Update the action group with email receiver
az monitor action-group update \
  --resource-group sre-perf-demo-rg \
  --name sre-perf-demo-app-alert-action-group \
  --add-email-receiver \
    name=admin \
    email-address=your-email@example.com
```

## Demo Workflow

### Part 1: Deploy Healthy Application to Production

This demonstrates a normal, healthy deployment directly to production.

**Run the workflow:**

1. Go to GitHub Actions
2. Select "Deploy Healthy Version to Production"
3. Click "Run workflow"
4. Select branch: `main`
5. Click "Run workflow"

**What happens:**
- ✅ Builds the .NET application
- ✅ Deploys directly to production slot
- ✅ Runs health checks (expects "Healthy" status)
- ✅ Runs basic performance tests
- ✅ Verifies average response time < 500ms

**Expected Results:**
- Production URL: `https://sre-perf-demo-app.azurewebsites.net`
- Health: `Healthy`
- Avg Response Time: ~50-100ms
- No alerts triggered

**Test the healthy deployment:**

```bash
# Check health
curl https://sre-perf-demo-app.azurewebsites.net/health

# Test fast endpoints
curl https://sre-perf-demo-app.azurewebsites.net/api/products
curl https://sre-perf-demo-app.azurewebsites.net/api/products/1

# Expected: Fast responses (< 500ms)
```

### Part 2: Deploy Bad Performance to Staging

This simulates a deployment with performance issues to demonstrate monitoring and alerting.

**Run the workflow:**

1. Go to GitHub Actions
2. Select "Deploy Bad Performance to Staging (Demo)"
3. Click "Run workflow"
4. Select branch: `main`
5. Choose performance mode: `slow-endpoints`
6. Click "Run workflow"

**What happens:**
- ⚠️ Builds and deploys to staging slot
- ⚠️ Enables slow performance mode via app settings
- ⚠️ Runs performance tests (expects degraded performance)
- ⚠️ Reports high response times (2000-5000ms)
- 🔔 **Azure Monitor alerts will fire within 5 minutes**

**Expected Results:**
- Staging URL: `https://sre-perf-demo-app-staging.azurewebsites.net`
- Health: `Degraded` or `Unhealthy`
- Avg Response Time: ~2000-5000ms
- **Alerts triggered** in Azure Monitor

**Test the degraded deployment:**

```bash
# Check health (will show Degraded/Unhealthy)
curl https://sre-perf-demo-app-staging.azurewebsites.net/health

# Test slow endpoints (will take 2-5 seconds)
curl https://sre-perf-demo-app-staging.azurewebsites.net/api/slowproducts

# Get performance metrics
curl https://sre-perf-demo-app-staging.azurewebsites.net/api/featureflag/metrics
```

### Part 3: Observe Azure Monitor Alerts

**View alerts in Azure Portal:**

1. Navigate to Azure Portal
2. Go to your resource group: `sre-perf-demo-rg`
3. Open "Alerts" from the left menu
4. Within 5 minutes, you should see:
   - ⚠️ `sre-perf-demo-app-response-time-alert` - FIRED
   - 🔥 `sre-perf-demo-app-critical-response-time-alert` - FIRED (if avg > 2000ms)

**View metrics in Application Insights:**

1. Navigate to Application Insights: `sre-perf-demo-app-ai`
2. Go to "Performance" → See slow request traces
3. Go to "Live Metrics" → Watch real-time performance
4. Go to "Metrics Explorer" → Chart response times

**Sample KQL Query for Performance Analysis:**

```kql
requests
| where timestamp > ago(30m)
| where name contains "slowproducts" or name contains "products"
| summarize
    avg(duration),
    percentile(duration, 95),
    max(duration),
    count()
  by name
| order by avg_duration desc
```

## Monitoring and Alerts Explanation

### Alert Rules Configured

| Alert Name | Threshold | Window | Frequency | Severity |
|------------|-----------|---------|-----------|----------|
| Response Time Alert | Avg > 1000ms | 5 min | 1 min | Warning (2) |
| Critical Response Time | Avg > 2000ms | 5 min | 1 min | Critical (1) |
| App Insights Perf | Avg > 1000ms | 5 min | 1 min | Warning (2) |
| CPU Alert | > 80% | 5 min | 1 min | Warning (2) |
| Memory Alert | > 85% | 5 min | 1 min | Warning (2) |

### How Alerts Work

1. **Data Collection**: Application Insights collects telemetry every request
2. **Evaluation**: Azure Monitor evaluates metrics every 1 minute
3. **Window**: Uses 5-minute rolling window for aggregation
4. **Threshold**: Fires when average exceeds threshold
5. **Action**: Triggers action group (email/SMS/webhook)

### Health Check Status Levels

The `/health` endpoint returns different statuses:

- **Healthy**: Avg response time < 500ms, P95 < 2000ms
- **Degraded**: P95 > 2000ms but avg < 1000ms
- **Unhealthy**: Avg response time > 1000ms

## API Endpoints Reference

### Fast Endpoints (Production)
- `GET /api/products` - List products (10-50ms)
- `GET /api/products/{id}` - Get product (5-25ms)
- `GET /api/products/search?query={q}` - Search (20-100ms)
- `GET /health` - Health check with metrics

### Slow Endpoints (Staging Demo)
- `GET /api/slowproducts` - List products (2000-5000ms) - Simulates N+1 query
- `GET /api/slowproducts/{id}` - Get product (100-300ms per dependency)
- `GET /api/slowproducts/search?query={q}` - Search (1500-3000ms) - Full table scan
- `GET /api/slowproducts/memory-leak` - Memory leak simulation

### Feature Flag Endpoints
- `GET /api/featureflag/performance-mode` - Get current mode
- `POST /api/featureflag/enable-slow-mode` - Enable degradation
- `POST /api/featureflag/disable-slow-mode` - Disable degradation
- `GET /api/featureflag/metrics` - Get current performance metrics

## Troubleshooting

### Alerts Not Firing

1. **Wait Time**: Alerts evaluate every 1 minute with a 5-minute window. Wait at least 5-6 minutes.
2. **Check Metric Data**: Verify Application Insights is receiving data
3. **Verify Alert Rules**: Check rules are enabled in Azure Monitor
4. **Test Load**: Generate enough traffic to trigger thresholds

```bash
# Generate load on staging
for i in {1..20}; do
  curl https://sre-perf-demo-app-staging.azurewebsites.net/api/slowproducts
  sleep 2
done
```

### Deployment Failures

1. **Check Secrets**: Ensure `AZURE_CREDENTIALS` is configured correctly
2. **Service Principal Permissions**: Verify SP has Contributor role
3. **App Service Name**: Must be globally unique
4. **Health Check**: If failing, check application logs in Azure Portal

### Staging Slot Not Responding

1. **Wait for Warmup**: Staging slot needs 30-60 seconds after deployment
2. **Check App Settings**: Verify `PerformanceSettings__EnableSlowEndpoints` is set
3. **Review Logs**: Check Application Insights for errors

## Cleanup

To remove all resources:

```bash
# Delete resource group (removes all resources)
az group delete --name sre-perf-demo-rg --yes --no-wait
```

## Learning Outcomes

After completing this demo, you will understand:

1. ✅ How to deploy applications to Azure App Service with deployment slots
2. ✅ How to configure Azure Monitor alerts for performance monitoring
3. ✅ How to use Application Insights for performance telemetry
4. ✅ How to implement health checks in ASP.NET Core
5. ✅ How to simulate and detect performance degradation
6. ✅ How to use GitHub Actions for CI/CD with performance gates
7. ✅ How slot-based deployments prevent bad code from reaching production
8. ✅ How to use Azure Monitor alerts to detect production issues

## Next Steps

- Configure alert action groups with email/SMS notifications
- Add custom Application Insights queries for performance analysis
- Implement automated rollback on alert triggers
- Add load testing with Azure Load Testing
- Integrate with incident management systems (PagerDuty, OpsGenie)
- Create dashboards in Azure Monitor or Grafana

## Additional Resources

- [Azure Monitor Documentation](https://docs.microsoft.com/azure/azure-monitor/)
- [Application Insights](https://docs.microsoft.com/azure/azure-monitor/app/app-insights-overview)
- [App Service Deployment Slots](https://docs.microsoft.com/azure/app-service/deploy-staging-slots)
- [ASP.NET Core Health Checks](https://docs.microsoft.com/aspnet/core/host-and-deploy/health-checks)
- [GitHub Actions for Azure](https://docs.microsoft.com/azure/developer/github/github-actions)
