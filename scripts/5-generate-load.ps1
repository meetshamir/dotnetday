#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Step 5: Generate load to trigger performance degradation and alerts
.DESCRIPTION
    This script generates load on the application to trigger performance degradation
    and cause Azure Monitor alerts to fire. It simulates real user traffic.
.PARAMETER ResourceGroupName
    Name of the Azure resource group (default: sre-perf-demo-rg)
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
    [string]$ResourceGroupName = "sre-perf-demo-rg",

    [Parameter(Mandatory=$false)]
    [string]$AppServiceName = "",

    [Parameter(Mandatory=$false)]
    [int]$DurationMinutes = 10,

    [Parameter(Mandatory=$false)]
    [int]$ConcurrentUsers = 5
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
║          SRE Performance Demo - Step 5                        ║
║              Generate Load to Trigger Alerts                 ║
║                                                                ║
╚════════════════════════════════════════════════════════════════╝
"@ -ForegroundColor Yellow

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

Write-Info "Configuration:"
Write-Info "  Resource Group: $ResourceGroupName"
Write-Info "  App Name: $AppServiceName"
Write-Info "  Duration: $DurationMinutes minutes"
Write-Info "  Concurrent Users: $ConcurrentUsers"

$prodUrl = "https://$AppServiceName.azurewebsites.net"

# Define endpoints to test
$endpoints = @(
    "/api/cpuintensive",
    "/api/cpuintensive/1",
    "/api/cpuintensive/2",
    "/api/cpuintensive/3",
    "/api/cpuintensive/search?query=test",
    "/api/cpuintensive/cpu-stress",
    "/health",
    "/api/featureflag/metrics"
)

# Load generation function
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
    Write-Info "Concurrent Users: $ConcurrentUsers"
    Write-Info "Start Time: $(Get-Date -Format 'HH:mm:ss')"
    Write-Info "End Time: $($endTime.ToString('HH:mm:ss'))"

    # Create concurrent user tasks
    $userTasks = @()
    for ($user = 1; $user -le $ConcurrentUsers; $user++) {
        $userTasks += Start-Job -ScriptBlock {
            param($BaseUrl, $Endpoints, $EndTime, $UserNumber)
            
            $userRequests = 0
            $userSuccessful = 0
            $userFailed = 0
            $userResponseTimes = @()
            $userSlowRequests = 0

            while ((Get-Date) -lt $EndTime) {
                $endpoint = $Endpoints | Get-Random
                $url = "$BaseUrl$endpoint"
                $userRequests++

                $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
                try {
                    $response = Invoke-WebRequest -Uri $url -Method Get -TimeoutSec 30
                    $stopwatch.Stop()
                    $responseTime = $stopwatch.ElapsedMilliseconds

                    if ($response.StatusCode -eq 200) {
                        $userSuccessful++
                        $userResponseTimes += $responseTime
                        
                        if ($responseTime -gt 1000) {
                            $userSlowRequests++
                        }
                    } else {
                        $userFailed++
                    }
                } catch {
                    $userFailed++
                }

                # Random delay between requests (1-3 seconds)
                Start-Sleep -Seconds (Get-Random -Minimum 1 -Maximum 4)
            }

            return @{
                UserNumber = $UserNumber
                TotalRequests = $userRequests
                SuccessfulRequests = $userSuccessful
                FailedRequests = $userFailed
                ResponseTimes = $userResponseTimes
                SlowRequests = $userSlowRequests
            }
        } -ArgumentList $BaseUrl, $Endpoints, $endTime, $user
    }

    # Monitor progress
    $progressInterval = 30 # seconds
    $lastProgressTime = Get-Date

    while ((Get-Date) -lt $endTime) {
        Start-Sleep -Seconds 5
        
        if ((Get-Date) - $lastProgressTime -gt [TimeSpan]::FromSeconds($progressInterval)) {
            $elapsed = (Get-Date) - $lastProgressTime
            $remaining = $endTime - (Get-Date)
            Write-Info "Load generation in progress... Elapsed: $($elapsed.ToString('mm\:ss')), Remaining: $($remaining.ToString('mm\:ss'))"
            $lastProgressTime = Get-Date
        }
    }

    Write-Info "Load generation completed. Collecting results..."

    # Collect results from all user tasks
    foreach ($task in $userTasks) {
        $result = Receive-Job -Job $task
        Remove-Job -Job $task

        $totalRequests += $result.TotalRequests
        $successfulRequests += $result.SuccessfulRequests
        $failedRequests += $result.FailedRequests
        $responseTimes += $result.ResponseTimes
        $slowRequests += $result.SlowRequests

        Write-Info "User $($result.UserNumber): $($result.SuccessfulRequests)/$($result.TotalRequests) successful, $($result.SlowRequests) slow requests"
    }

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
Write-Host "📊 Load Generation Results" -ForegroundColor Yellow
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
    Write-Warn "❌ PERFORMANCE DEGRADED DETECTED"
    Write-Warn "Average response time exceeds 1000ms threshold"
    Write-Warn "Azure Monitor alerts should fire within 5 minutes"
} elseif ($results.SlowRequests -gt 0) {
    Write-Warn "⚠️  Some slow requests detected"
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
║                  LOAD GENERATION COMPLETED! 🔥                ║
╚════════════════════════════════════════════════════════════════╝

📋 Load Test Summary
─────────────────────────────────────────────────────────────────
Resource Group:    $ResourceGroupName
App Service Name:  $AppServiceName
Duration:          $DurationMinutes minutes
Concurrent Users:  $ConcurrentUsers
Total Requests:    $($results.TotalRequests)
Success Rate:      $([Math]::Round(($results.SuccessfulRequests / $results.TotalRequests) * 100, 2))%

📊 Performance Impact
─────────────────────────────────────────────────────────────────
Average Response Time: $([Math]::Round($avgResponseTime, 2))ms
95th Percentile:        $([Math]::Round($p95ResponseTime, 2))ms
Slow Requests (>1000ms): $($results.SlowRequests)

📈 Expected Alert Behavior
─────────────────────────────────────────────────────────────────
1. Azure Monitor Alerts (should fire within 5 minutes):
   - Response Time Alert (>1000ms) - $($avgResponseTime -gt 1000 ? 'SHOULD FIRE' : 'May not fire')
   - Critical Response Time Alert (>2000ms) - $($avgResponseTime -gt 2000 ? 'SHOULD FIRE' : 'May not fire')
   - CPU Alert (>80%) - Should fire due to CPU-intensive operations

2. Application Insights:
   - High response times in Performance tab
   - High CPU usage in Live Metrics
   - Performance degradation charts

🧪 Next Steps
─────────────────────────────────────────────────────────────────
1. Monitor SRE Agent remediation:
   .\6-monitor-sre-agent.ps1

2. Open Azure Portal and navigate to:
   Resource Group → Alerts → See fired alerts

3. Open Application Insights:
   Resource Group → $AppServiceName-ai → Performance

4. Wait for SRE Agent to detect and remediate the issue

📖 Documentation
─────────────────────────────────────────────────────────────────
See DEMO-SCRIPT.md for complete demo walkthrough

"@ -ForegroundColor Yellow

Write-Success "Load generation completed successfully!"
if ($avgResponseTime -gt 1000) {
    Write-Warn "Performance degradation detected - alerts should fire soon"
} else {
    Write-Info "Load test completed - monitor for alert firing"
}
