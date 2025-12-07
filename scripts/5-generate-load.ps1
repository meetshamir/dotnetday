#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Step 5: Generate load to trigger performance degradation and alerts
.DESCRIPTION
    This script generates load on the application to trigger performance degradation
    and cause Azure Monitor alerts to fire. It simulates real user traffic.
.PARAMETER ResourceGroupName
    Name of the Azure resource group (default: dotnet-day-demo)
.PARAMETER AppServiceName
    Name of the App Service (must match the production deployment)
.PARAMETER DurationMinutes
    Duration to run load test in minutes (default: 10)
.PARAMETER ConcurrentUsers
    Number of concurrent users to simulate (default: 5)
.EXAMPLE
    .\5-generate-load.ps1 -AppServiceName "sre-perf-demo-app" -DurationMinutes 10
#>

param(
    [Parameter(Mandatory=$false)]
    [ValidateSet("1", "2", "both")]
    [string]$AppChoice = "",

    [Parameter(Mandatory=$false)]
    [ValidateSet("production", "staging", "prod", "stage")]
    [string]$Slot = "production",

    [Parameter(Mandatory=$false)]
    [ValidateSet("healthy", "stress", "all")]
    [string]$EndpointMode = "all",

    [Parameter(Mandatory=$false)]
    [string]$ResourceGroupName = "dotnet-day-demo",

    [Parameter(Mandatory=$false)]
    [string]$AppServiceName = "",

    [Parameter(Mandatory=$false)]
    [int]$DurationMinutes = 10,

    [Parameter(Mandatory=$false)]
    [int]$ConcurrentUsers = 5
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
║          SRE Performance Demo - Step 5                        ║
║              Generate Load to Trigger Alerts                 ║
║                                                                ║
╚════════════════════════════════════════════════════════════════╝
"@ -ForegroundColor Yellow

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

Write-Info "Configuration:"
Write-Info "  Resource Group: $ResourceGroupName"
Write-Info "  App Name: $AppServiceName"
Write-Info "  Duration: $DurationMinutes minutes"
Write-Info "  Concurrent Users: $ConcurrentUsers"

# Normalize slot name
$normalizedSlot = switch ($Slot.ToLower()) {
    "prod" { "production" }
    "stage" { "staging" }
    default { $Slot.ToLower() }
}

# Build URL based on slot
if ($normalizedSlot -eq "staging") {
    $prodUrl = "https://$AppServiceName-staging.azurewebsites.net"
    Write-Info "  Target Slot: STAGING"
} else {
    $prodUrl = "https://$AppServiceName.azurewebsites.net"
    Write-Info "  Target Slot: PRODUCTION"
}

# Define endpoint sets
$healthyEndpoints = @(
    "/api/products",
    "/api/products/1",
    "/api/products/2",
    "/api/products/3"
)

$stressEndpoints = @(
    "/api/cpuintensive",
    "/api/cpuintensive/1",
    "/api/cpuintensive/2",
    "/api/cpuintensive/3",
    "/api/cpuintensive/search?query=test",
    "/api/cpuintensive/cpu-stress",
    "/api/featureflag/error-spike"
)

$allEndpoints = @(
    "/api/cpuintensive",
    "/api/cpuintensive/1",
    "/api/cpuintensive/2",
    "/api/cpuintensive/3",
    "/api/cpuintensive/search?query=test",
    "/api/cpuintensive/cpu-stress",
    "/api/featureflag/error-spike",
    "/health",
    "/api/featureflag/metrics"
)

# Select endpoints based on mode
$endpoints = switch ($EndpointMode.ToLower()) {
    "healthy" { $healthyEndpoints }
    "stress" { $stressEndpoints }
    default { $allEndpoints }
}

Write-Info "  Endpoint Mode: $EndpointMode ($($endpoints.Count) endpoints)"

# Load generation function - sequential with real-time output
function Start-LoadGeneration {
    param(
        [string]$BaseUrl,
        [string[]]$Endpoints,
        [int]$DurationMinutes,
        [int]$ConcurrentUsers
    )

    $endTime = (Get-Date).AddMinutes($DurationMinutes)
    $totalRequests = 0
    $successfulRequests = 0
    $failedRequests = 0
    $responseTimes = @()
    $slowRequests = 0

    Write-Step "Starting Load Generation"
    Write-Info "Target URL: $BaseUrl"
    Write-Info "Endpoints: $($Endpoints.Count)"
    Write-Info "Duration: $DurationMinutes minutes"
    Write-Info "Concurrent Users: $ConcurrentUsers (sequential simulation)"
    Write-Info "Start Time: $(Get-Date -Format 'HH:mm:ss')"
    Write-Info "End Time: $($endTime.ToString('HH:mm:ss'))"
    Write-Host ""

    $requestNumber = 0
    while ((Get-Date) -lt $endTime) {
        $endpoint = $Endpoints | Get-Random
        $url = "$BaseUrl$endpoint"
        $requestNumber++
        $totalRequests++

        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            $response = Invoke-WebRequest -Uri $url -Method Get -TimeoutSec 30
            $stopwatch.Stop()
            $responseTime = $stopwatch.ElapsedMilliseconds

            if ($response.StatusCode -eq 200) {
                $successfulRequests++
                $responseTimes += $responseTime
                
                # Color code based on response time
                if ($responseTime -gt 2000) {
                    Write-Host "[#$requestNumber] $endpoint - ${responseTime}ms" -ForegroundColor Red -NoNewline
                    Write-Host " CRITICAL" -ForegroundColor Red
                    $slowRequests++
                } elseif ($responseTime -gt 1000) {
                    Write-Host "[#$requestNumber] $endpoint - ${responseTime}ms" -ForegroundColor Yellow -NoNewline
                    Write-Host " SLOW" -ForegroundColor Yellow
                    $slowRequests++
                } else {
                    Write-Host "[#$requestNumber] $endpoint - ${responseTime}ms" -ForegroundColor Green
                }
            } else {
                Write-Host "[#$requestNumber] $endpoint - ${responseTime}ms" -ForegroundColor Magenta -NoNewline
                Write-Host " STATUS: $($response.StatusCode)" -ForegroundColor Magenta
                $failedRequests++
            }
        } catch {
            $stopwatch.Stop()
            $responseTime = $stopwatch.ElapsedMilliseconds
            Write-Host "[#$requestNumber] $endpoint - FAILED (${responseTime}ms)" -ForegroundColor Red -NoNewline
            Write-Host " $($_.Exception.Message)" -ForegroundColor DarkRed
            $failedRequests++
        }

        # Small delay between requests (0.5-1.5 seconds for faster testing)
        Start-Sleep -Milliseconds (Get-Random -Minimum 500 -Maximum 1500)
    }

    Write-Host ""
    Write-Info "Load generation completed!"

    return @{
        TotalRequests = $totalRequests
        SuccessfulRequests = $successfulRequests
        FailedRequests = $failedRequests
        ResponseTimes = $responseTimes
        SlowRequests = $slowRequests
    }
}

# Run load generation
$results = Start-LoadGeneration -BaseUrl $prodUrl -Endpoints $endpoints -DurationMinutes $DurationMinutes -ConcurrentUsers $ConcurrentUsers

# Calculate statistics
if ($results.ResponseTimes.Count -gt 0) {
    $avgResponseTime = ($results.ResponseTimes | Measure-Object -Average).Average
    $maxResponseTime = ($results.ResponseTimes | Measure-Object -Maximum).Maximum
    $minResponseTime = ($results.ResponseTimes | Measure-Object -Minimum).Minimum
    $p95ResponseTime = ($results.ResponseTimes | Sort-Object)[[Math]::Floor($results.ResponseTimes.Count * 0.95)]
} else {
    $avgResponseTime = 0
    $maxResponseTime = 0
    $minResponseTime = 0
    $p95ResponseTime = 0
}

# Display results
Write-Host "`n================================================" -ForegroundColor Yellow
Write-Host "Load Generation Results" -ForegroundColor Yellow
Write-Host "================================================" -ForegroundColor Yellow
Write-Host "Duration: $DurationMinutes minutes" -ForegroundColor White
Write-Host "Concurrent Users: $ConcurrentUsers" -ForegroundColor White
Write-Host "Total Requests: $($results.TotalRequests)" -ForegroundColor White
Write-Host "Successful Requests: $($results.SuccessfulRequests)" -ForegroundColor White
Write-Host "Failed Requests: $($results.FailedRequests)" -ForegroundColor White
Write-Host "Success Rate: $([Math]::Round(($results.SuccessfulRequests / $results.TotalRequests) * 100, 2))%" -ForegroundColor White
Write-Host "" -ForegroundColor White
Write-Host "Response Time Statistics:" -ForegroundColor White
Write-Host "  Average: $([Math]::Round($avgResponseTime, 2))ms" -ForegroundColor White
Write-Host "  Minimum: $([Math]::Round($minResponseTime, 2))ms" -ForegroundColor White
Write-Host "  Maximum: $([Math]::Round($maxResponseTime, 2))ms" -ForegroundColor White
Write-Host "  95th Percentile: $([Math]::Round($p95ResponseTime, 2))ms" -ForegroundColor White
Write-Host "  Slow Requests (>1000ms): $($results.SlowRequests)" -ForegroundColor White
Write-Host "================================================" -ForegroundColor Yellow

# Determine if alerts should fire
if ($avgResponseTime -gt 1000) {
    Write-Warn "[!] PERFORMANCE DEGRADED DETECTED"
    Write-Warn "Average response time exceeds 1000ms threshold"
    Write-Warn "Azure Monitor alerts should fire within 5 minutes"
} elseif ($results.SlowRequests -gt 0) {
    Write-Warn "[!] Some slow requests detected"
    Write-Warn "Alerts may fire if slow requests continue"
} else {
    Write-Info "Performance appears acceptable"
}

# Check current health status
Write-Step "Checking Current Health Status"
try {
    $healthResponse = Invoke-RestMethod -Uri "$prodUrl/health" -Method Get -TimeoutSec 10
    Write-Info "Health Status: $($healthResponse.status)"
    if ($healthResponse.metrics.averageResponseTimeMs) {
        Write-Info "Current Average Response Time: $($healthResponse.metrics.averageResponseTimeMs)ms"
    }
} catch {
    Write-Warn "Could not check health status"
}

# Summary
Write-Host @"

╔════════════════════════════════════════════════════════════════╗
║              LOAD GENERATION COMPLETED!                        ║
╚════════════════════════════════════════════════════════════════╝

Load Test Summary
─────────────────────────────────────────────────────────────────
Resource Group:    $ResourceGroupName
App Service Name:  $AppServiceName
Duration:          $DurationMinutes minutes
Concurrent Users:  $ConcurrentUsers
Total Requests:    $($results.TotalRequests)
Success Rate:      $([Math]::Round(($results.SuccessfulRequests / $results.TotalRequests) * 100, 2))%

Performance Impact
─────────────────────────────────────────────────────────────────
Average Response Time: $([Math]::Round($avgResponseTime, 2))ms
95th Percentile:        $([Math]::Round($p95ResponseTime, 2))ms
Slow Requests (>1000ms): $($results.SlowRequests)

Expected Alert Behavior
─────────────────────────────────────────────────────────────────
1. Azure Monitor Alerts (should fire within 5 minutes):
   - Response Time Alert (>1000ms) - $(if ($avgResponseTime -gt 1000) { 'SHOULD FIRE' } else { 'May not fire' })
   - Critical Response Time Alert (>2000ms) - $(if ($avgResponseTime -gt 2000) { 'SHOULD FIRE' } else { 'May not fire' })
   - CPU Alert (>80%) - Should fire due to CPU-intensive operations

2. Smart Detection / Failure Anomalies (should fire within 3-5 minutes):
   - Error rate spike detected (85% error rate from error-spike endpoint)
   - Failure Anomalies alert will appear in Alerts section

3. Application Insights:
   - High response times in Performance tab
   - High CPU usage in Live Metrics
   - Performance degradation charts
   - Error spike visible in Failures tab

Next Steps
─────────────────────────────────────────────────────────────────
1. Monitor SRE Agent remediation:
   .\6-monitor-sre-agent.ps1

2. Open Azure Portal and navigate to:
   Resource Group → Alerts → See fired alerts

3. Open Application Insights:
   Resource Group → $AppServiceName-ai → Performance

4. Wait for SRE Agent to detect and remediate the issue

Documentation
─────────────────────────────────────────────────────────────────
See DEMO-SCRIPT.md for complete demo walkthrough

"@ -ForegroundColor Yellow

Write-Success "Load generation completed successfully!"
if ($avgResponseTime -gt 1000) {
    Write-Warn "Performance degradation detected - alerts should fire soon"
} else {
    Write-Info "Load test completed - monitor for alert firing"
}
