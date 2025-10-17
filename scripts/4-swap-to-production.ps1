#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Step 4: Swap staging to production (deploy CPU-intensive to production)
.DESCRIPTION
    This script swaps the staging slot (with CPU-intensive operations) to production.
    This simulates a bad deployment that reaches production and causes performance issues.
.PARAMETER ResourceGroupName
    Name of the Azure resource group (default: sre-perf-demo-rg)
.PARAMETER AppServiceName
    Name of the App Service (must match the production deployment)
.EXAMPLE
    .\4-swap-to-production.ps1 -AppServiceName "sre-perf-demo-app"
#>

param(
    [Parameter(Mandatory=$false)]
    [string]$ResourceGroupName = "sre-perf-demo-rg",

    [Parameter(Mandatory=$false)]
    [string]$AppServiceName = ""
)

$ErrorActionPreference = "Stop"

# Color output functions
function Write-Success { Write-Host "✅ $args" -ForegroundColor Green }
function Write-Info { Write-Host "ℹ️  $args" -ForegroundColor Cyan }
function Write-Warn { Write-Host "⚠️  $args" -ForegroundColor Yellow }
function Write-Err { Write-Host "❌ $args" -ForegroundColor Red }
function Write-Step { Write-Host "`n🔥 $args" -ForegroundColor Magenta }

Write-Host @"
╔════════════════════════════════════════════════════════════════╗
║                                                                ║
║          SRE Performance Demo - Step 4                        ║
║              Swap to Production (Bad Deployment)             ║
║                                                                ║
╚════════════════════════════════════════════════════════════════╝
"@ -ForegroundColor Red

# Load configuration from previous step
if (Test-Path "demo-config.json") {
    $config = Get-Content "demo-config.json" | ConvertFrom-Json
    if (-not $ResourceGroupName -or $ResourceGroupName -eq "sre-perf-demo-rg") {
        $ResourceGroupName = $config.ResourceGroupName
    }
    if (-not $AppServiceName) {
        $AppServiceName = $config.AppServiceName
    }
    Write-Info "Loaded configuration from previous step"
} else {
    if (-not $AppServiceName) {
        Write-Err "AppServiceName is required. Either provide it as parameter or run step 1 first."
        exit 1
    }
}

Write-Warn "This will swap CPU-INTENSIVE staging to PRODUCTION"
Write-Warn "This simulates a bad deployment reaching production"
Write-Info "`nConfiguration:"
Write-Info "  Resource Group: $ResourceGroupName"
Write-Info "  App Name: $AppServiceName"

# Check prerequisites
Write-Step "Checking Prerequisites"

# Check Azure CLI
try {
    $azVersion = az version --output json | ConvertFrom-Json
    Write-Success "Azure CLI version: $($azVersion.'azure-cli')"
} catch {
    Write-Err "Azure CLI is not installed"
    exit 1
}

# Check login
$accountInfo = az account show 2>$null | ConvertFrom-Json
if (-not $accountInfo) {
    Write-Err "Not logged in to Azure. Run 'az login'"
    exit 1
}
Write-Success "Logged in as: $($accountInfo.user.name)"

# Check current slot status
Write-Step "Checking Current Slot Status"
try {
    $prodStatus = az webapp show --resource-group $ResourceGroupName --name $AppServiceName --query "state" --output tsv
    $stagingStatus = az webapp show --resource-group $ResourceGroupName --name $AppServiceName --slot staging --query "state" --output tsv
    
    Write-Info "Production slot status: $prodStatus"
    Write-Info "Staging slot status: $stagingStatus"
} catch {
    Write-Warn "Could not check slot status"
}

# Perform slot swap
Write-Step "Performing Slot Swap"
Write-Warn "Swapping staging (CPU-intensive) to production..."

az webapp deployment slot swap `
    --resource-group $ResourceGroupName `
    --name $AppServiceName `
    --slot staging `
    --target-slot production `
    --output none

if ($LASTEXITCODE -eq 0) {
    Write-Success "Slot swap completed successfully"
    Write-Warn "CPU-intensive version is now in PRODUCTION"
} else {
    Write-Err "Slot swap failed"
    exit 1
}

# Wait for swap to complete
Write-Info "Waiting for swap to complete (30 seconds)..."
Start-Sleep -Seconds 30

# Health check on production
Write-Step "Running Health Check on Production"
$prodUrl = "https://$AppServiceName.azurewebsites.net"
$healthUrl = "$prodUrl/health"

try {
    $response = Invoke-RestMethod -Uri $healthUrl -Method Get -TimeoutSec 30
    Write-Info "Production Health Status: $($response.status)"
    if ($response.metrics.averageResponseTimeMs) {
        Write-Info "Average Response Time: $($response.metrics.averageResponseTimeMs)ms"
    }
    
    if ($response.status -eq "Unhealthy" -or $response.status -eq "Degraded") {
        Write-Warn "❌ Production is now $($response.status) - Performance issues detected"
    } else {
        Write-Info "Production status: $($response.status)"
    }
} catch {
    Write-Warn "Health check failed: $_"
}

# Performance test on production
Write-Step "Running Performance Tests on Production"
Write-Info "Testing production endpoints (expect degraded performance)..."

$endpoints = @("/api/cpuintensive", "/api/cpuintensive/1")
$responseTimes = @()
$slowRequests = 0

foreach ($endpoint in $endpoints) {
    for ($i = 1; $i -le 2; $i++) {
        $url = "$prodUrl$endpoint"
        Write-Info "Testing $endpoint - Attempt $i"

        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            $httpResponse = Invoke-WebRequest -Uri $url -Method Get -TimeoutSec 30
            $stopwatch.Stop()
            $responseTime = $stopwatch.ElapsedMilliseconds

            if ($httpResponse.StatusCode -eq 200) {
                $responseTimes += $responseTime
                Write-Info "  ✓ Response: $($httpResponse.StatusCode) - Time: ${responseTime}ms"

                if ($responseTime -gt 1000) {
                    $slowRequests++
                    Write-Warn "  SLOW response detected: ${responseTime}ms"
                }
            }
        } catch {
            Write-Warn "  Request failed or timeout: $($_.Exception.Message)"
        }

        Start-Sleep -Seconds 2
    }
}

if ($responseTimes.Count -gt 0) {
    $avgResponseTime = ($responseTimes | Measure-Object -Average).Average
    Write-Host "`n================================================" -ForegroundColor Red
    Write-Host "📊 Production Performance Test Results" -ForegroundColor Red
    Write-Host "================================================" -ForegroundColor Red
    Write-Host "Total successful requests: $($responseTimes.Count)" -ForegroundColor White
    Write-Host "Slow requests (>1000ms): $slowRequests" -ForegroundColor White
    Write-Host "Average response time: ${avgResponseTime}ms" -ForegroundColor White
    Write-Host "" -ForegroundColor White

    if ($avgResponseTime -gt 1000) {
        Write-Warn "❌ PRODUCTION PERFORMANCE DEGRADED"
        Write-Warn "Average response time exceeds 1000ms threshold"
        Write-Warn "Azure Monitor alerts will fire within 5 minutes"
        Write-Warn "CPU usage should be high (>80%)"
    }
    Write-Host "================================================" -ForegroundColor Red
}

# Summary
Write-Host @"

╔════════════════════════════════════════════════════════════════╗
║          BAD DEPLOYMENT IN PRODUCTION! ⚠️                     ║
╚════════════════════════════════════════════════════════════════╝

📋 Deployment Summary
─────────────────────────────────────────────────────────────────
Resource Group:    $ResourceGroupName
App Service Name:  $AppServiceName
Environment:       PRODUCTION (CPU-Intensive)

🌐 URLs
─────────────────────────────────────────────────────────────────
Production (DEGRADED): https://$AppServiceName.azurewebsites.net
Health Check:          https://$AppServiceName.azurewebsites.net/health

🧪 Test URLs (Production - CPU-Intensive Performance)
─────────────────────────────────────────────────────────────────
CPU-intensive:     https://$AppServiceName.azurewebsites.net/api/cpuintensive
Single product:    https://$AppServiceName.azurewebsites.net/api/cpuintensive/1
CPU stress test:   https://$AppServiceName.azurewebsites.net/api/cpuintensive/cpu-stress
Memory leak:       https://$AppServiceName.azurewebsites.net/api/cpuintensive/memory-cpu-leak
Health check:      https://$AppServiceName.azurewebsites.net/health
Metrics:           https://$AppServiceName.azurewebsites.net/api/featureflag/metrics

📊 What to Observe
─────────────────────────────────────────────────────────────────
1. Azure Monitor Alerts (will fire within 5 minutes):
   - Response Time Alert (>1000ms)
   - Critical Response Time Alert (>2000ms)
   - CPU Alert (>80%)

2. Application Insights:
   - High response times in Performance tab
   - High CPU usage in Live Metrics
   - Performance degradation charts

3. Health Endpoint Status:
   - Will report "Degraded" or "Unhealthy"

4. Production Impact:
   - Production now has CPU-intensive operations
   - Performance degradation affects all users
   - Alerts will fire due to production issues

🧪 Next Steps
─────────────────────────────────────────────────────────────────
1. Generate load to trigger alerts:
   .\5-generate-load.ps1

2. Monitor SRE Agent remediation:
   .\6-monitor-sre-agent.ps1

3. Open Azure Portal and navigate to:
   Resource Group → Alerts → See fired alerts

4. Open Application Insights:
   Resource Group → $AppServiceName-ai → Performance

5. Wait for SRE Agent to detect and remediate the issue

"@ -ForegroundColor Red

Write-Warn "Bad deployment is now in PRODUCTION"
Write-Warn "Performance issues will affect all users"
Write-Success "Ready for SRE Agent demonstration"
