#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Check what version is deployed to production and staging slots
.DESCRIPTION
    This script checks the current deployment status of production and staging slots
    by hitting the health endpoints and displaying version information.
.PARAMETER AppChoice
    Choose which app to check: 1 = sre-perf-demo-app-3198, 2 = sre-perf-demo-app-7380
.EXAMPLE
    .\check-slot-status.ps1 -AppChoice 1
    .\check-slot-status.ps1 -AppChoice 2
#>

param(
    [Parameter(Mandatory=$false)]
    [ValidateSet("1", "2", "both")]
    [string]$AppChoice = "both"
)

$ErrorActionPreference = "Stop"

# App choice mapping
$AppMap = @{
    "1" = @{ Name = "sre-perf-demo-app-3198"; ResourceGroup = "sre-perf-demo-rg" }
    "2" = @{ Name = "sre-perf-demo-app-7380"; ResourceGroup = "dotnet-day-demo" }
}

# Color output functions
function Write-Success { Write-Host "[SUCCESS] $args" -ForegroundColor Green }
function Write-Info { Write-Host "[INFO] $args" -ForegroundColor Cyan }
function Write-Warn { Write-Host "[WARNING] $args" -ForegroundColor Yellow }
function Write-Err { Write-Host "[ERROR] $args" -ForegroundColor Red }

Write-Host @"
╔════════════════════════════════════════════════════════════════╗
║                                                                ║
║              Check Slot Deployment Status                      ║
║                                                                ║
╚════════════════════════════════════════════════════════════════╝
"@ -ForegroundColor Cyan

# Determine which apps to check
if ($AppChoice -eq "both") {
    $appsToCheck = @("1", "2")
} else {
    $appsToCheck = @($AppChoice)
}

foreach ($choice in $appsToCheck) {
    $appName = $AppMap[$choice].Name
    $resourceGroup = $AppMap[$choice].ResourceGroup
    
    Write-Host "`n─────────────────────────────────────────────────────────────────" -ForegroundColor Gray
    Write-Host "App $choice`: $appName ($resourceGroup)" -ForegroundColor White
    Write-Host "─────────────────────────────────────────────────────────────────" -ForegroundColor Gray
    
    $prodUrl = "https://$appName.azurewebsites.net"
    $stagingUrl = "https://$appName-staging.azurewebsites.net"
    
    # Check Production
    Write-Host "`n[PRODUCTION] $prodUrl" -ForegroundColor Green
    try {
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $prodHealth = Invoke-RestMethod -Uri "$prodUrl/health" -TimeoutSec 30
        $stopwatch.Stop()
        $prodResponseTime = $stopwatch.ElapsedMilliseconds
        
        Write-Host "  Status: $($prodHealth.status)" -ForegroundColor $(if ($prodHealth.status -eq "Healthy") { "Green" } elseif ($prodHealth.status -eq "Degraded") { "Yellow" } else { "Red" })
        Write-Host "  Response Time: ${prodResponseTime}ms" -ForegroundColor $(if ($prodResponseTime -lt 500) { "Green" } elseif ($prodResponseTime -lt 2000) { "Yellow" } else { "Red" })
        
        if ($prodHealth.metrics) {
            if ($prodHealth.metrics.averageResponseTimeMs) {
                Write-Host "  Avg Response Time: $($prodHealth.metrics.averageResponseTimeMs)ms" -ForegroundColor White
            }
        }
        
        # Determine version by response time pattern
        if ($prodResponseTime -gt 2000 -or ($prodHealth.metrics.averageResponseTimeMs -and $prodHealth.metrics.averageResponseTimeMs -gt 1000)) {
            Write-Host "  Version: CPU-INTENSIVE (Bad)" -ForegroundColor Red
        } else {
            Write-Host "  Version: HEALTHY (Good)" -ForegroundColor Green
        }
    } catch {
        Write-Err "  Could not reach production: $($_.Exception.Message)"
    }
    
    # Check Staging
    Write-Host "`n[STAGING] $stagingUrl" -ForegroundColor Yellow
    try {
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $stagingHealth = Invoke-RestMethod -Uri "$stagingUrl/health" -TimeoutSec 30
        $stopwatch.Stop()
        $stagingResponseTime = $stopwatch.ElapsedMilliseconds
        
        Write-Host "  Status: $($stagingHealth.status)" -ForegroundColor $(if ($stagingHealth.status -eq "Healthy") { "Green" } elseif ($stagingHealth.status -eq "Degraded") { "Yellow" } else { "Red" })
        Write-Host "  Response Time: ${stagingResponseTime}ms" -ForegroundColor $(if ($stagingResponseTime -lt 500) { "Green" } elseif ($stagingResponseTime -lt 2000) { "Yellow" } else { "Red" })
        
        if ($stagingHealth.metrics) {
            if ($stagingHealth.metrics.averageResponseTimeMs) {
                Write-Host "  Avg Response Time: $($stagingHealth.metrics.averageResponseTimeMs)ms" -ForegroundColor White
            }
        }
        
        # Determine version by response time pattern
        if ($stagingResponseTime -gt 2000 -or ($stagingHealth.metrics.averageResponseTimeMs -and $stagingHealth.metrics.averageResponseTimeMs -gt 1000)) {
            Write-Host "  Version: CPU-INTENSIVE (Bad)" -ForegroundColor Red
        } else {
            Write-Host "  Version: HEALTHY (Good)" -ForegroundColor Green
        }
    } catch {
        Write-Err "  Could not reach staging: $($_.Exception.Message)"
    }
}

Write-Host "`n─────────────────────────────────────────────────────────────────" -ForegroundColor Gray
Write-Host "Legend:" -ForegroundColor White
Write-Host "  HEALTHY - Fast response times, less than 500ms" -ForegroundColor Green
Write-Host "  CPU-INTENSIVE - Slow response times, greater than 2000ms" -ForegroundColor Red
Write-Host "─────────────────────────────────────────────────────────────────" -ForegroundColor Gray
