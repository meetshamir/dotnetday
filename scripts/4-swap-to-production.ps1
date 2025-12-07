#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Step 4: Swap staging to production (deploy CPU-intensive to production)
.DESCRIPTION
    This script swaps the staging slot (with CPU-intensive operations) to production.
    This simulates a bad deployment that reaches production and causes performance issues.
.PARAMETER ResourceGroupName
    Name of the Azure resource group (default: dotnet-day-demo)
.PARAMETER AppServiceName
    Name of the App Service (must match the production deployment)
.EXAMPLE
    .\4-swap-to-production.ps1 -AppServiceName "sre-perf-demo-app"
#>

param(
    [Parameter(Mandatory=$false)]
    [ValidateSet("1", "2", "both")]
    [string]$AppChoice = "",

    [Parameter(Mandatory=$false)]
    [string]$ResourceGroupName = "dotnet-day-demo",

    [Parameter(Mandatory=$false)]
    [string]$AppServiceName = ""
)

# App choice mapping
$AppMap = @{
    "1" = @{ Name = "sre-perf-demo-app-3198"; ResourceGroup = "sre-perf-demo-rg" }
    "2" = @{ Name = "sre-perf-demo-app-7380"; ResourceGroup = "dotnet-day-demo" }
}

# Determine which apps to process
if ($AppChoice -eq "both") {
    $appsToProcess = @("1", "2")
} elseif ($AppChoice) {
    $appsToProcess = @($AppChoice)
} else {
    $appsToProcess = @()
}

# If AppChoice is provided (not 'both'), use it to set AppServiceName and ResourceGroupName
if ($AppChoice -and $AppChoice -ne "both") {
    $AppServiceName = $AppMap[$AppChoice].Name
    $ResourceGroupName = $AppMap[$AppChoice].ResourceGroup
    Write-Host "Using App Choice $AppChoice`: $AppServiceName in $ResourceGroupName" -ForegroundColor Cyan
}

$ErrorActionPreference = "Stop"

# Get the script directory and set paths
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent $ScriptDir
$ConfigPath = Join-Path $ProjectRoot "demo-config.json"

# Color output functions
function Write-Success { Write-Host "[SUCCESS] $args" -ForegroundColor Green }
function Write-Info { Write-Host "[INFO] $args" -ForegroundColor Cyan }
function Write-Warn { Write-Host "[WARNING] $args" -ForegroundColor Yellow }
function Write-Err { Write-Host "[ERROR] $args" -ForegroundColor Red }
function Write-Step { Write-Host "`n[STEP] $args" -ForegroundColor Magenta }

Write-Host @"
╔════════════════════════════════════════════════════════════════╗
║                                                                ║
║          SRE Performance Demo - Step 4                        ║
║              Swap to Production (Bad Deployment)             ║
║                                                                ║
╚════════════════════════════════════════════════════════════════╝
"@ -ForegroundColor Red

# Load configuration from previous step
if (Test-Path $ConfigPath) {
    $config = Get-Content $ConfigPath | ConvertFrom-Json
    if (-not $ResourceGroupName -or $ResourceGroupName -eq "dotnet-day-demo") {
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
    
    # Send custom event to App Insights to trigger Sev3 alert immediately
    Write-Step "Sending Swap Event to App Insights"
    try {
        $instrumentationKey = "3c1500ca-855c-4ef6-9393-bdf5275ca290"
        $eventBody = @{
            name = "Microsoft.ApplicationInsights.$instrumentationKey.Event"
            time = (Get-Date).ToUniversalTime().ToString("o")
            iKey = $instrumentationKey
            data = @{
                baseType = "EventData"
                baseData = @{
                    ver = 2
                    name = "SlotSwapCompleted"
                    properties = @{
                        AppName = $AppServiceName
                        ResourceGroup = $ResourceGroupName
                        SwapType = "staging-to-production"
                        Timestamp = (Get-Date).ToString("o")
                    }
                }
            }
        } | ConvertTo-Json -Depth 10
        
        $result = Invoke-RestMethod -Uri "https://dc.services.visualstudio.com/v2/track" -Method Post -Body $eventBody -ContentType "application/json"
        Write-Success "Swap event sent to App Insights (Sev3 alert will fire within 1-2 minutes)"
    } catch {
        Write-Warn "Could not send swap event to App Insights: $_"
    }
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
        Write-Warn "[!] Production is now $($response.status) - Performance issues detected"
    } else {
        Write-Info "Production status: $($response.status)"
    }
} catch {
    Write-Warn "Health check failed: $_"
}

# Performance test on production
Write-Step "Running Performance Tests on Production"
Write-Info "Testing production /api/products endpoints (expect degraded performance after swap)..."

# Test the SAME endpoints that were fast before - now they should be slow
$endpoints = @("/api/products", "/api/products/1", "/api/products/search?query=electronics")
$responseTimes = @()
$slowRequests = 0

foreach ($endpoint in $endpoints) {
    for ($i = 1; $i -le 2; $i++) {
        $url = "$prodUrl$endpoint"
        Write-Info "Testing $endpoint - Attempt $i"

        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            $httpResponse = Invoke-WebRequest -Uri $url -Method Get -TimeoutSec 60
            $stopwatch.Stop()
            $responseTime = $stopwatch.ElapsedMilliseconds

            if ($httpResponse.StatusCode -eq 200) {
                $responseTimes += $responseTime
                
                if ($responseTime -gt 2000) {
                    Write-Host "  [+] Response: $($httpResponse.StatusCode) - Time: ${responseTime}ms" -ForegroundColor Red -NoNewline
                    Write-Host " CRITICAL" -ForegroundColor Red
                    $slowRequests++
                } elseif ($responseTime -gt 1000) {
                    Write-Host "  [+] Response: $($httpResponse.StatusCode) - Time: ${responseTime}ms" -ForegroundColor Yellow -NoNewline
                    Write-Host " SLOW" -ForegroundColor Yellow
                    $slowRequests++
                } else {
                    Write-Host "  [+] Response: $($httpResponse.StatusCode) - Time: ${responseTime}ms" -ForegroundColor Green
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
    Write-Host "Production Performance Test Results" -ForegroundColor Red
    Write-Host "================================================" -ForegroundColor Red
    Write-Host "Total successful requests: $($responseTimes.Count)" -ForegroundColor White
    Write-Host "Slow requests (>1000ms): $slowRequests" -ForegroundColor White
    Write-Host "Average response time: ${avgResponseTime}ms" -ForegroundColor White
    Write-Host "" -ForegroundColor White

    if ($avgResponseTime -gt 1000) {
        Write-Warn "[!] PRODUCTION PERFORMANCE DEGRADED"
        Write-Warn "Average response time exceeds 1000ms threshold"
        Write-Warn "Azure Monitor alerts will fire within 5 minutes"
        Write-Warn "CPU usage should be high (>80%)"
    }
    Write-Host "================================================" -ForegroundColor Red
}

# Summary
Write-Host @"

╔════════════════════════════════════════════════════════════════╗
║          BAD DEPLOYMENT IN PRODUCTION!                         ║
╚════════════════════════════════════════════════════════════════╝

Deployment Summary
─────────────────────────────────────────────────────────────────
Resource Group:    $ResourceGroupName
App Service Name:  $AppServiceName
Environment:       PRODUCTION (Slow Products API)

What Changed?
─────────────────────────────────────────────────────────────────
The SAME /api/products endpoints are now SLOW because:
  ✗ N+1 query pattern (20 individual lookups vs 1 batch)
  ✗ Missing database index (full table scan)
  ✗ CPU-intensive "security validation" added by mistake

This is REALISTIC - same endpoints, degraded performance!

URLs
─────────────────────────────────────────────────────────────────
Production (DEGRADED): https://$AppServiceName.azurewebsites.net
Health Check:          https://$AppServiceName.azurewebsites.net/health

Test URLs (Same endpoints - now SLOW)
─────────────────────────────────────────────────────────────────
Products List:     https://$AppServiceName.azurewebsites.net/api/products
Single Product:    https://$AppServiceName.azurewebsites.net/api/products/1
Search Products:   https://$AppServiceName.azurewebsites.net/api/products/search?query=electronics
Health Check:      https://$AppServiceName.azurewebsites.net/health

What to Observe
─────────────────────────────────────────────────────────────────
1. Azure Monitor Alerts (will fire within 5 minutes):
   - Response Time Alert (>1000ms) on /api/products
   - Critical Response Time Alert (>2000ms)
   - CPU Alert (>80%)

2. Application Insights:
   - High response times in Performance tab for /api/products
   - Same endpoint name, different performance characteristics
   - Before/after comparison visible in charts

3. Health Endpoint Status:
   - Will report "Degraded" or "Unhealthy"

4. Production Impact:
   - ALL /api/products calls are now slow
   - Same API contract, degraded performance
   - Real-world scenario: developer removed query optimization

Next Steps
─────────────────────────────────────────────────────────────────
1. Generate load to trigger alerts:
   .\5-generate-load.ps1 -AppChoice 1 -EndpointMode healthy

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
