#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Step 3: Deploy CPU-intensive version to staging slot
.DESCRIPTION
    This script deploys the application with CPU-intensive operations to the STAGING slot only.
    It demonstrates what happens when CPU-intensive code causes performance degradation.
.PARAMETER ResourceGroupName
    Name of the Azure resource group (default: dotnet-day-demo)
.PARAMETER AppServiceName
    Name of the App Service (must match the production deployment)
.EXAMPLE
    .\3-deploy-cpu-intensive-to-staging.ps1 -AppServiceName "sre-perf-demo-app"
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
║          SRE Performance Demo - Step 3                        ║
║              Deploy CPU-Intensive to Staging                  ║
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

Write-Warn "This will deploy CPU-INTENSIVE operations to STAGING slot"
Write-Warn "Production will remain HEALTHY and unaffected"
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

# Check .NET SDK
try {
    $dotnetVersion = dotnet --version
    Write-Success ".NET SDK version: $dotnetVersion"
} catch {
    Write-Err ".NET SDK is not installed"
    exit 1
}

# Check login
$accountInfo = az account show 2>$null | ConvertFrom-Json
if (-not $accountInfo) {
    Write-Err "Not logged in to Azure. Run 'az login'"
    exit 1
}
Write-Success "Logged in as: $($accountInfo.user.name)"

# Build and publish application
Write-Step "Building Application"
$AppPath = Join-Path $ProjectRoot "SREPerfDemo"
Push-Location $AppPath

try {
    Write-Info "Cleaning previous builds..."
    dotnet clean --configuration Release --nologo --verbosity quiet

    Write-Info "Restoring packages..."
    dotnet restore --nologo --verbosity quiet

    Write-Info "Building application..."
    dotnet build --configuration Release --no-restore --nologo --verbosity minimal

    Write-Info "Publishing application..."
    dotnet publish --configuration Release --no-build --output "./publish" --nologo --verbosity quiet

    Write-Success "Application built successfully"
} catch {
    Write-Err "Build failed: $_"
    Pop-Location
    exit 1
}

# Create deployment package
Write-Info "Creating deployment package..."
$publishPath = "./publish"
$zipPath = "./deploy.zip"

if (Test-Path $zipPath) {
    Remove-Item $zipPath -Force
}

Compress-Archive -Path "$publishPath/*" -DestinationPath $zipPath -Force
Write-Success "Deployment package created"

Pop-Location

# Deploy to Staging
Write-Step "Deploying to Staging Slot"
Write-Info "Uploading and deploying application..."

$DeployZipPath = Join-Path $AppPath "deploy.zip"
az webapp deployment source config-zip `
    --resource-group $ResourceGroupName `
    --name $AppServiceName `
    --slot staging `
    --src $DeployZipPath `
    --output none

if ($LASTEXITCODE -eq 0) {
    Write-Success "Deployed to staging slot"
} else {
    Write-Err "Staging deployment failed"
    exit 1
}

# Wait for deployment
Write-Info "Waiting for deployment to complete (30 seconds)..."
Start-Sleep -Seconds 30

# Enable CPU-intensive mode
Write-Step "Enabling CPU-Intensive Mode"
Write-Warn "Configuring CPU-intensive endpoints..."

# Update app settings to enable CPU-intensive mode
az webapp config appsettings set `
    --resource-group $ResourceGroupName `
    --name $AppServiceName `
    --slot staging `
    --settings PerformanceSettings__EnableCpuIntensiveEndpoints=true `
    --output none

Write-Success "CPU-intensive mode enabled via app settings"

# Try to enable via API as well
$stagingUrl = "https://$AppServiceName-staging.azurewebsites.net"
Start-Sleep -Seconds 10

try {
    Invoke-RestMethod -Uri "$stagingUrl/api/featureflag/enable-cpu-intensive-mode" -Method Post -TimeoutSec 10 | Out-Null
    Write-Success "CPU-intensive mode enabled via API"
} catch {
    Write-Warn "Could not enable via API (app might still be starting)"
}

# Health check
Write-Step "Running Health Check"
$healthUrl = "$stagingUrl/health"
$maxRetries = 10
$retryCount = 0

while ($retryCount -lt $maxRetries) {
    try {
        $response = Invoke-RestMethod -Uri $healthUrl -Method Get -TimeoutSec 30
        Write-Info "Health Status: $($response.status)"
        if ($response.metrics.averageResponseTimeMs) {
            Write-Info "Average Response Time: $($response.metrics.averageResponseTimeMs)ms"
        }
        break
    } catch {
        Write-Info "Waiting for app to respond... ($($retryCount + 1)/$maxRetries)"
        Start-Sleep -Seconds 10
        $retryCount++
    }
}

# Performance test
Write-Step "Running Performance Tests"
Write-Info "Testing CPU-intensive endpoints (expect high CPU usage)..."

$endpoints = @("/api/cpuintensive", "/api/cpuintensive/1", "/api/cpuintensive/cpu-stress")
$responseTimes = @()
$slowRequests = 0

foreach ($endpoint in $endpoints) {
    for ($i = 1; $i -le 2; $i++) {
        $url = "$stagingUrl$endpoint"
        Write-Info "Testing $endpoint - Attempt $i"

        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            $httpResponse = Invoke-WebRequest -Uri $url -Method Get -TimeoutSec 30
            $stopwatch.Stop()
            $responseTime = $stopwatch.ElapsedMilliseconds

            if ($httpResponse.StatusCode -eq 200) {
                $responseTimes += $responseTime
                Write-Info "  [+] Response: $($httpResponse.StatusCode) - Time: ${responseTime}ms"

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
    Write-Host "`n================================================" -ForegroundColor Yellow
    Write-Host "Performance Test Results" -ForegroundColor Yellow
    Write-Host "================================================" -ForegroundColor Yellow
    Write-Host "Total successful requests: $($responseTimes.Count)" -ForegroundColor White
    Write-Host "Slow requests (>1000ms): $slowRequests" -ForegroundColor White
    Write-Host "Average response time: ${avgResponseTime}ms" -ForegroundColor White
    Write-Host "" -ForegroundColor White

    if ($avgResponseTime -gt 1000) {
        Write-Warn "[!] Performance DEGRADED - Average exceeds 1000ms threshold"
        Write-Warn "Azure Monitor alerts should fire within 5 minutes"
        Write-Warn "CPU usage should be high (>80%)"
    } else {
        Write-Info "Performance acceptable but CPU-intensive endpoints active"
    }
    Write-Host "================================================" -ForegroundColor Yellow
}

# Get current metrics
Write-Step "Fetching Performance Metrics"
try {
    $metrics = Invoke-RestMethod -Uri "$stagingUrl/api/featureflag/metrics" -Method Get -TimeoutSec 10
    Write-Info "Current Performance Metrics:"
    $metrics | ConvertTo-Json -Depth 3 | Write-Host
} catch {
    Write-Warn "Could not fetch metrics"
}

# Summary
Write-Host @"

╔════════════════════════════════════════════════════════════════╗
║          CPU-INTENSIVE DEPLOYED TO STAGING!                    ║
╚════════════════════════════════════════════════════════════════╝

Deployment Summary
─────────────────────────────────────────────────────────────────
Resource Group:    $ResourceGroupName
App Service Name:  $AppServiceName
Environment:       STAGING ONLY

URLs
─────────────────────────────────────────────────────────────────
Staging (CPU-INTENSIVE): https://$AppServiceName-staging.azurewebsites.net
Production (OK):         https://$AppServiceName.azurewebsites.net

Test URLs (Staging - CPU-Intensive Performance)
─────────────────────────────────────────────────────────────────
CPU-intensive:     https://$AppServiceName-staging.azurewebsites.net/api/cpuintensive
Single product:    https://$AppServiceName-staging.azurewebsites.net/api/cpuintensive/1
CPU stress test:   https://$AppServiceName-staging.azurewebsites.net/api/cpuintensive/cpu-stress
Memory leak:       https://$AppServiceName-staging.azurewebsites.net/api/cpuintensive/memory-cpu-leak
Health check:      https://$AppServiceName-staging.azurewebsites.net/health
Metrics:           https://$AppServiceName-staging.azurewebsites.net/api/featureflag/metrics

What to Observe
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

4. Production Remains Healthy:
   - Production slot is UNAFFECTED
   - Staging demonstrates CPU-intensive issues
   - No slot swap will occur

Next Steps
─────────────────────────────────────────────────────────────────
1. Generate load to trigger alerts:
   .\5-generate-load.ps1

2. Open Azure Portal and navigate to:
   Resource Group → Alerts → See fired alerts

3. Open Application Insights:
   Resource Group → $AppServiceName-ai → Performance

4. Compare staging vs production performance

5. To clean up, disable CPU-intensive mode:
   curl -X POST https://$AppServiceName-staging.azurewebsites.net/api/featureflag/disable-cpu-intensive-mode

"@ -ForegroundColor Yellow

Write-Warn "Staging deployment completed with CPU-INTENSIVE operations"
Write-Success "Production remains healthy and unaffected"
