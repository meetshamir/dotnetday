# SRE Performance Demo

A demonstration of Site Reliability Engineering practices for monitoring and managing application performance in Azure App Service.

## Quick Start

### Prerequisites

- Azure CLI installed ([Install here](https://aka.ms/InstallAzureCLIDocs))
- .NET 9.0 SDK installed ([Install here](https://dotnet.microsoft.com/download))
- Azure subscription with permissions to create resources
- PowerShell 7+ (for Windows)

### 1. Deploy Healthy Application to Production

Run the main deployment script:

**Windows (PowerShell):**
```powershell
.\deploy.ps1
```

**With custom parameters:**
```powershell
.\deploy.ps1 -AppServiceName "my-unique-app-name" -Location "westus2" -Email "admin@example.com"
```

**Parameters:**
- `ResourceGroupName`: Resource group name (default: `sre-perf-demo-rg`)
- `AppServiceName`: App Service name - must be globally unique (default: auto-generated)
- `Location`: Azure region (default: `eastus`)
- `Email`: Email for alert notifications (optional)
- `SkipInfrastructure`: Skip infrastructure deployment, only deploy app

This script will:
- ✅ Create Azure resource group
- ✅ Deploy infrastructure (App Service, Application Insights, Alerts)
- ✅ Build and deploy application to **production**
- ✅ Run health checks
- ✅ Configure email alerts (if provided)

**Expected result:** Healthy production deployment with fast response times (~50-100ms)

### 2. Deploy Bad Performance to Staging

Once production is healthy, simulate a performance regression:

```powershell
.\deploy-bad-performance.ps1 -AppServiceName "your-app-name"
```

This script will:
- ⚠️ Deploy application to **staging slot only**
- ⚠️ Enable slow performance mode (2-5 second responses)
- ⚠️ Run performance tests showing degradation
- 🔔 **Trigger Azure Monitor alerts within 5 minutes**

**Expected result:** Staging has degraded performance, production remains healthy, alerts fire

### 3. Observe Azure Monitor Alerts

1. Open [Azure Portal](https://portal.azure.com)
2. Navigate to your resource group: `sre-perf-demo-rg`
3. Click on "Alerts" in the left menu
4. Within 5 minutes, you should see alerts firing:
   - Response Time Alert (Severity 2)
   - Critical Response Time Alert (Severity 1)

### 4. View Application Insights

1. In Azure Portal, go to your resource group
2. Open Application Insights: `{your-app-name}-ai`
3. View:
   - **Performance** → See slow request traces
   - **Live Metrics** → Real-time performance monitoring
   - **Metrics** → Chart response times over time

## What This Demo Shows

### Architecture

```
Production Slot (Healthy)           Staging Slot (Degraded)
        ↓                                   ↓
   Fast APIs                           Slow APIs
  (~50-100ms)                        (~2000-5000ms)
        ↓                                   ↓
        └─────────── Application Insights ──────────┘
                           ↓
                    Azure Monitor Alerts
                  (Fire when perf degrades)
```

### Key SRE Concepts Demonstrated

1. **Deployment Slots**: Separate staging/production environments
2. **Performance Monitoring**: Application Insights telemetry
3. **Alerting**: Azure Monitor metric alerts
4. **Health Checks**: ASP.NET Core health endpoints
5. **Safe Deployments**: Bad performance stays in staging, doesn't reach production

## Scripts Overview

| Script | Purpose | Deploys To | Performance |
|--------|---------|------------|-------------|
| `deploy.ps1` | Main deployment | Production | Fast/Healthy |
| `deploy-bad-performance.ps1` | Demo degradation | Staging only | Slow/Degraded |

## Infrastructure Created

- **App Service Plan**: B1 SKU
- **App Service**: With production + staging slots
- **Application Insights**: Performance monitoring
- **Log Analytics Workspace**: Centralized logging
- **Azure Monitor Alerts**:
  - Response Time > 1000ms (Warning)
  - Response Time > 2000ms (Critical)
  - CPU > 80%
  - Memory > 85%
- **Action Group**: For alert notifications

## API Endpoints

### Production (Fast)
- `GET /api/products` - List products (~10-50ms)
- `GET /api/products/{id}` - Get product (~5-25ms)
- `GET /api/products/search?query={q}` - Search (~20-100ms)
- `GET /health` - Health check with metrics

### Staging (Slow - when degraded)
- `GET /api/slowproducts` - List products (~2000-5000ms)
- `GET /api/slowproducts/{id}` - Get product (~100-300ms)
- `GET /api/slowproducts/search?query={q}` - Search (~1500-3000ms)

### Feature Flags
- `GET /api/featureflag/performance-mode` - Check current mode
- `POST /api/featureflag/enable-slow-mode` - Enable degradation
- `POST /api/featureflag/disable-slow-mode` - Disable degradation
- `GET /api/featureflag/metrics` - Get performance metrics

## Testing the Demo

### Test Healthy Production
```bash
# Health check
curl https://your-app-name.azurewebsites.net/health

# Fast endpoint
curl https://your-app-name.azurewebsites.net/api/products
```

### Test Degraded Staging
```bash
# Health check (will show Degraded/Unhealthy)
curl https://your-app-name-staging.azurewebsites.net/health

# Slow endpoint (takes 2-5 seconds)
curl https://your-app-name-staging.azurewebsites.net/api/slowproducts

# Get metrics
curl https://your-app-name-staging.azurewebsites.net/api/featureflag/metrics
```

## Cleanup

To remove all Azure resources:

```powershell
az group delete --name sre-perf-demo-rg --yes --no-wait
```

## Troubleshooting

### Alerts Not Firing

- **Wait**: Alerts evaluate every 1 minute with a 5-minute window. Wait 5-6 minutes.
- **Generate Load**: Make multiple requests to slow endpoints
- **Check Rules**: Verify alert rules are enabled in Azure Portal

### Deployment Fails

- **App Name Conflict**: App Service name must be globally unique
- **Permissions**: Ensure you have Contributor role on subscription
- **Login**: Run `az login` if authentication fails

### App Not Responding

- **Wait**: App needs 30-60 seconds to warm up after deployment
- **Check Logs**: View Application Insights logs in Azure Portal
- **Restart**: Restart the app service in Azure Portal

## Documentation

For detailed information, see:
- [DEMO-GUIDE.md](./DEMO-GUIDE.md) - Complete demo walkthrough
- [infrastructure/main.bicep](./infrastructure/main.bicep) - Infrastructure as Code

## Learning Resources

- [Azure Monitor Documentation](https://docs.microsoft.com/azure/azure-monitor/)
- [Application Insights](https://docs.microsoft.com/azure/azure-monitor/app/app-insights-overview)
- [App Service Deployment Slots](https://docs.microsoft.com/azure/app-service/deploy-staging-slots)
- [ASP.NET Core Health Checks](https://docs.microsoft.com/aspnet/core/host-and-deploy/health-checks)