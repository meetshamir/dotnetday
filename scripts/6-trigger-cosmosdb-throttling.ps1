#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Trigger Cosmos DB throttling by generating high load
.DESCRIPTION
    This script simulates a "Black Friday" traffic spike that overwhelms 
    the low-provisioned Cosmos DB (400 RU/s), causing throttling (429 errors).
    
    This demonstrates Scenario 2: App is slow due to dependency issues, not code bugs.
.PARAMETER BaseUrl
    The base URL of the deployed app
.PARAMETER DurationSeconds
    How long to run the load test (default: 60 seconds)
.PARAMETER ConcurrentRequests
    Number of concurrent requests (default: 20)
.EXAMPLE
    .\6-trigger-cosmosdb-throttling.ps1
    .\6-trigger-cosmosdb-throttling.ps1 -DurationSeconds 120 -ConcurrentRequests 30
#>

param(
    [Parameter(Mandatory=$false)]
    [string]$BaseUrl,

    [Parameter(Mandatory=$false)]
    [int]$DurationSeconds = 60,

    [Parameter(Mandatory=$false)]
    [int]$ConcurrentRequests = 20
)

$ErrorActionPreference = "Continue"

# Color output functions
function Write-Success { Write-Host "[SUCCESS] $args" -ForegroundColor Green }
function Write-Info { Write-Host "[INFO] $args" -ForegroundColor Cyan }
function Write-Warn { Write-Host "[WARNING] $args" -ForegroundColor Yellow }
function Write-Err { Write-Host "[ERROR] $args" -ForegroundColor Red }
function Write-Step { Write-Host "`n[STEP] $args" -ForegroundColor Magenta }

# Get the script directory and load config
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent $ScriptDir
$ConfigPath = Join-Path $ProjectRoot "demo-config.json"

Write-Host @"
╔════════════════════════════════════════════════════════════════╗
║                                                                ║
║          SRE Performance Demo - Scenario 2                    ║
║              Trigger Cosmos DB Throttling                      ║
║                                                                ║
║          "Black Friday Traffic Spike"                          ║
║                                                                ║
╚════════════════════════════════════════════════════════════════╝
"@ -ForegroundColor Yellow

# Load configuration
if ([string]::IsNullOrEmpty($BaseUrl)) {
    if (Test-Path $ConfigPath) {
        $config = Get-Content $ConfigPath | ConvertFrom-Json
        $BaseUrl = $config.ProductionUrl
        Write-Info "Loaded URL from config: $BaseUrl"
    } else {
        Write-Err "No BaseUrl provided and no config file found"
        Write-Err "Please run 1-deploy-infrastructure.ps1 first or provide -BaseUrl"
        exit 1
    }
}

Write-Info "Configuration:"
Write-Info "  Target URL: $BaseUrl"
Write-Info "  Duration: $DurationSeconds seconds"
Write-Info "  Concurrent Requests: $ConcurrentRequests"

# Check if Cosmos DB endpoints are available
Write-Step "Checking Cosmos DB Endpoints"
try {
    $metricsUrl = "$BaseUrl/api/cosmos/metrics"
    $response = Invoke-RestMethod -Uri $metricsUrl -Method Get -TimeoutSec 10
    Write-Success "Cosmos DB endpoints available"
    Write-Info "Current status: $($response.cosmosDb.status)"
} catch {
    Write-Err "Cosmos DB endpoints not available. Make sure:"
    Write-Err "  1. The app is deployed with Cosmos DB integration"
    Write-Err "  2. Cosmos DB infrastructure is deployed"
    Write-Err "  3. Run: .\1-deploy-infrastructure.ps1 to update infrastructure"
    exit 1
}

# Seed data if needed
Write-Step "Seeding Sample Data"
try {
    $seedUrl = "$BaseUrl/api/cosmos/seed?count=100"
    $seedResult = Invoke-RestMethod -Uri $seedUrl -Method Post -TimeoutSec 60
    Write-Success "Seeded data: $($seedResult.message)"
} catch {
    Write-Warn "Seeding failed (data may already exist): $($_.Exception.Message)"
}

# Reset metrics before test
Write-Step "Resetting Metrics"
try {
    Invoke-RestMethod -Uri "$BaseUrl/api/cosmos/metrics/reset" -Method Post -TimeoutSec 10
    Write-Success "Metrics reset"
} catch {
    Write-Warn "Could not reset metrics"
}

# Show initial metrics
Write-Step "Initial Cosmos DB Status"
$initialMetrics = Invoke-RestMethod -Uri "$BaseUrl/api/cosmos/metrics" -Method Get -TimeoutSec 10
Write-Info "Status: $($initialMetrics.cosmosDb.status)"
Write-Info "Message: $($initialMetrics.cosmosDb.message)"

Write-Host @"

╔════════════════════════════════════════════════════════════════╗
║                                                                ║
║         🚨 STARTING TRAFFIC SPIKE SIMULATION 🚨                ║
║                                                                ║
║  This will generate high load to trigger Cosmos DB throttling  ║
║  Watch the Azure Portal for:                                   ║
║    - Cosmos DB 429 errors                                     ║
║    - RU consumption alerts                                     ║
║    - Application Insights slow requests                       ║
║                                                                ║
╚════════════════════════════════════════════════════════════════╝

"@ -ForegroundColor Red

Write-Info "Starting load test in 3 seconds..."
Start-Sleep -Seconds 3

# Endpoints to hit (mix of cheap and expensive operations)
$endpoints = @(
    @{ Url = "/api/cosmos/products"; Weight = 3; Name = "GetAll" },
    @{ Url = "/api/cosmos/products/search?query=product"; Weight = 2; Name = "Search" },
    @{ Url = "/api/cosmos/expensive-query"; Weight = 2; Name = "ExpensiveQuery" }
)

# Stats tracking
$stats = @{
    TotalRequests = 0
    SuccessfulRequests = 0
    ThrottledRequests = 0
    FailedRequests = 0
    TotalLatencyMs = 0
}
$statsLock = [System.Threading.Mutex]::new()

# Create weighted endpoint list
$weightedEndpoints = @()
foreach ($ep in $endpoints) {
    for ($i = 0; $i -lt $ep.Weight; $i++) {
        $weightedEndpoints += $ep
    }
}

Write-Step "Generating Load ($DurationSeconds seconds, $ConcurrentRequests concurrent)"
$startTime = Get-Date
$endTime = $startTime.AddSeconds($DurationSeconds)

# Progress display
$progressJob = Start-Job -ScriptBlock {
    param($endTime, $statsRef)
    while ((Get-Date) -lt $endTime) {
        Start-Sleep -Seconds 5
    }
} -ArgumentList $endTime, $stats

# Run load test
$runspacePool = [runspacefactory]::CreateRunspacePool(1, $ConcurrentRequests)
$runspacePool.Open()

$jobs = @()

while ((Get-Date) -lt $endTime) {
    # Create new requests up to concurrent limit
    while ($jobs.Count -lt $ConcurrentRequests -and (Get-Date) -lt $endTime) {
        $endpoint = $weightedEndpoints | Get-Random
        $url = "$BaseUrl$($endpoint.Url)"
        
        $powershell = [powershell]::Create().AddScript({
            param($url, $name)
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            try {
                $response = Invoke-WebRequest -Uri $url -Method Get -TimeoutSec 30 -UseBasicParsing
                $sw.Stop()
                return @{
                    Success = $true
                    StatusCode = $response.StatusCode
                    LatencyMs = $sw.ElapsedMilliseconds
                    Name = $name
                    Throttled = $false
                }
            } catch {
                $sw.Stop()
                $statusCode = 0
                if ($_.Exception.Response) {
                    $statusCode = [int]$_.Exception.Response.StatusCode
                }
                return @{
                    Success = $false
                    StatusCode = $statusCode
                    LatencyMs = $sw.ElapsedMilliseconds
                    Name = $name
                    Throttled = ($statusCode -eq 503 -or $statusCode -eq 429)
                }
            }
        }).AddArgument($url).AddArgument($endpoint.Name)
        
        $powershell.RunspacePool = $runspacePool
        $jobs += @{
            PowerShell = $powershell
            Handle = $powershell.BeginInvoke()
        }
    }
    
    # Process completed jobs
    $completedJobs = $jobs | Where-Object { $_.Handle.IsCompleted }
    foreach ($job in $completedJobs) {
        $result = $job.PowerShell.EndInvoke($job.Handle)
        $job.PowerShell.Dispose()
        
        $stats.TotalRequests++
        $stats.TotalLatencyMs += $result.LatencyMs
        
        if ($result.Throttled) {
            $stats.ThrottledRequests++
            Write-Host "." -NoNewline -ForegroundColor Red
        } elseif ($result.Success) {
            $stats.SuccessfulRequests++
            Write-Host "." -NoNewline -ForegroundColor Green
        } else {
            $stats.FailedRequests++
            Write-Host "." -NoNewline -ForegroundColor Yellow
        }
        
        $jobs = $jobs | Where-Object { $_ -ne $job }
    }
    
    # Brief pause to avoid overwhelming local resources
    Start-Sleep -Milliseconds 50
}

# Wait for remaining jobs
Write-Host ""
Write-Info "Waiting for remaining requests to complete..."
foreach ($job in $jobs) {
    $null = $job.Handle.AsyncWaitHandle.WaitOne()
    $result = $job.PowerShell.EndInvoke($job.Handle)
    $job.PowerShell.Dispose()
    
    $stats.TotalRequests++
    if ($result.Throttled) { $stats.ThrottledRequests++ }
    elseif ($result.Success) { $stats.SuccessfulRequests++ }
    else { $stats.FailedRequests++ }
}

$runspacePool.Close()
$runspacePool.Dispose()
Stop-Job $progressJob -ErrorAction SilentlyContinue
Remove-Job $progressJob -ErrorAction SilentlyContinue

# Final metrics
Write-Step "Load Test Results"
$avgLatency = if ($stats.TotalRequests -gt 0) { [math]::Round($stats.TotalLatencyMs / $stats.TotalRequests, 2) } else { 0 }
$throttleRate = if ($stats.TotalRequests -gt 0) { [math]::Round(($stats.ThrottledRequests / $stats.TotalRequests) * 100, 2) } else { 0 }

Write-Host @"

═══════════════════════════════════════════════════════════════════
                      LOAD TEST RESULTS
═══════════════════════════════════════════════════════════════════
  Total Requests:      $($stats.TotalRequests)
  Successful:          $($stats.SuccessfulRequests) (Green dots)
  Throttled (429/503): $($stats.ThrottledRequests) (Red dots)
  Other Failures:      $($stats.FailedRequests) (Yellow dots)
  
  Throttle Rate:       $throttleRate%
  Avg Latency:         ${avgLatency}ms
═══════════════════════════════════════════════════════════════════

"@ -ForegroundColor Cyan

# Get final Cosmos DB metrics
Write-Step "Final Cosmos DB Status"
Start-Sleep -Seconds 2
$finalMetrics = Invoke-RestMethod -Uri "$BaseUrl/api/cosmos/metrics" -Method Get -TimeoutSec 10

Write-Host @"

╔════════════════════════════════════════════════════════════════╗
║                   COSMOS DB METRICS                            ║
╠════════════════════════════════════════════════════════════════╣
║  Status: $($finalMetrics.cosmosDb.status.PadRight(50))║
║  Message: $($finalMetrics.cosmosDb.message.Substring(0, [Math]::Min(48, $finalMetrics.cosmosDb.message.Length)).PadRight(48))║
╠════════════════════════════════════════════════════════════════╣
║  Rolling Window (Last 100 operations):                         ║
║    Avg Latency:     $("$($finalMetrics.cosmosDb.rollingWindow.latency.avgMs)ms".PadRight(40))║
║    P95 Latency:     $("$($finalMetrics.cosmosDb.rollingWindow.latency.p95Ms)ms".PadRight(40))║
║    Max Latency:     $("$($finalMetrics.cosmosDb.rollingWindow.latency.maxMs)ms".PadRight(40))║
║    Throttled:       $("$($finalMetrics.cosmosDb.rollingWindow.errors.throttledCount) ($($finalMetrics.cosmosDb.rollingWindow.errors.throttledPercentage)%)".PadRight(40))║
║    Avg RU/request:  $("$($finalMetrics.cosmosDb.rollingWindow.requestUnits.avgPerRequest) RU".PadRight(40))║
╠════════════════════════════════════════════════════════════════╣
║  All-Time:                                                      ║
║    Total Requests:  $("$($finalMetrics.cosmosDb.allTime.totalRequests)".PadRight(40))║
║    Total Throttled: $("$($finalMetrics.cosmosDb.allTime.totalThrottled)".PadRight(40))║
║    Total RU:        $("$($finalMetrics.cosmosDb.allTime.totalRuConsumed) RU".PadRight(40))║
╚════════════════════════════════════════════════════════════════╝

"@ -ForegroundColor $(if ($finalMetrics.cosmosDb.status -eq "Healthy") { "Green" } elseif ($finalMetrics.cosmosDb.status -eq "Degraded") { "Yellow" } else { "Red" })

if ($finalMetrics.cosmosDb.status -ne "Healthy") {
    Write-Host @"

╔════════════════════════════════════════════════════════════════╗
║                   🔥 THROTTLING DETECTED! 🔥                   ║
╠════════════════════════════════════════════════════════════════╣
║                                                                ║
║  The Cosmos DB is experiencing throttling (429 errors).        ║
║  This is causing the application to slow down.                 ║
║                                                                ║
║  NEXT STEPS:                                                   ║
║                                                                ║
║  1. Use Azure SRE Agent to investigate:                        ║
║     "Why is my Products API slow?"                             ║
║     "Investigate Cosmos DB throttling"                         ║
║                                                                ║
║  2. Fix by scaling up Cosmos DB:                              ║
║     .\7-fix-cosmosdb-throttling.ps1 -RUs 4000                 ║
║                                                                ║
║  3. View in Azure Portal:                                      ║
║     - Cosmos DB → Metrics → Total Requests (filter by 429)    ║
║     - Cosmos DB → Metrics → Normalized RU Consumption         ║
║     - Application Insights → Failures → Dependency failures   ║
║                                                                ║
╚════════════════════════════════════════════════════════════════╝

"@ -ForegroundColor Red
} else {
    Write-Success "Cosmos DB is still healthy. Try increasing load or duration."
    Write-Info "Run with: .\6-trigger-cosmosdb-throttling.ps1 -DurationSeconds 120 -ConcurrentRequests 50"
}

Write-Success "Traffic spike simulation completed!"
