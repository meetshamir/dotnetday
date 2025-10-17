#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Deploy bad performance version to Staging slot (Demo)
.DESCRIPTION
    This script deploys the application with degraded performance to the STAGING slot only.
    It demonstrates what happens when performance regressions occur and triggers Azure Monitor alerts.
.PARAMETER ResourceGroupName
    Name of the Azure resource group (default: sre-perf-demo-rg)
.PARAMETER AppServiceName
    Name of the App Service (must match the production deployment)
.EXAMPLE
    .\deploy-bad-performance.ps1 -AppServiceName "sre-perf-demo-app"
#>

param(
    [Parameter(Mandatory=$false)]
    [string]$ResourceGroupName = "sre-perf-demo-rg",

    [Parameter(Mandatory=$true)]
    [string]$AppServiceName
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
║          SRE Performance Demo - Bad Performance                ║
║             (Deploy to Staging Slot Only)                      ║
║                                                                ║
╚════════════════════════════════════════════════════════════════╝
"@ -ForegroundColor Red

Write-Warn "This will deploy DEGRADED performance to STAGING slot"
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
Push-Location "SREPerfDemo"

try {
    Write-Info "Restoring packages..."
    dotnet restore --nologo --verbosity quiet

    Write-Info "Building application..."
    dotnet build --configuration Release --no-restore --nologo --verbosity quiet

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

az webapp deployment source config-zip `
    --resource-group $ResourceGroupName `
    --name $AppServiceName `
    --slot staging `
    --src "SREPerfDemo/deploy.zip" `
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

# Enable slow mode
Write-Step "Enabling Performance Degradation Mode"
Write-Warn "Configuring slow performance endpoints..."

# Update app settings to enable slow mode
az webapp config appsettings set `
    --resource-group $ResourceGroupName `
    --name $AppServiceName `
    --slot staging `
    --settings PerformanceSettings__EnableSlowEndpoints=true `
    --output none

Write-Success "Slow mode enabled via app settings"

# Try to enable via API as well
$stagingUrl = "https://$AppServiceName-staging.azurewebsites.net"
Start-Sleep -Seconds 10

try {
    Invoke-RestMethod -Uri "$stagingUrl/api/featureflag/enable-slow-mode" -Method Post -TimeoutSec 10 | Out-Null
    Write-Success "Slow mode enabled via API"
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
Write-Info "Testing degraded endpoints (expect slow responses)..."

$endpoints = @("/api/slowproducts", "/api/products/1")
$responseTimes = @()
$slowRequests = 0

foreach ($endpoint in $endpoints) {
    for ($i = 1; $i -le 3; $i++) {
        $url = "$stagingUrl$endpoint"
        Write-Info "Testing $endpoint - Attempt $i"

        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            $httpResponse = Invoke-WebRequest -Uri $url -Method Get -TimeoutSec 15
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

        Start-Sleep -Seconds 1
    }
}

if ($responseTimes.Count -gt 0) {
    $avgResponseTime = ($responseTimes | Measure-Object -Average).Average
    Write-Host "`n================================================" -ForegroundColor Yellow
    Write-Host "📊 Performance Test Results" -ForegroundColor Yellow
    Write-Host "================================================" -ForegroundColor Yellow
    Write-Host "Total successful requests: $($responseTimes.Count)" -ForegroundColor White
    Write-Host "Slow requests (>1000ms): $slowRequests" -ForegroundColor White
    Write-Host "Average response time: ${avgResponseTime}ms" -ForegroundColor White
    Write-Host "" -ForegroundColor White

    if ($avgResponseTime -gt 1000) {
        Write-Warn "❌ Performance DEGRADED - Average exceeds 1000ms threshold"
        Write-Warn "Azure Monitor alerts should fire within 5 minutes"
    } else {
        Write-Info "Performance acceptable but degraded endpoints active"
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
║          BAD PERFORMANCE DEPLOYED TO STAGING! ⚠️               ║
╚════════════════════════════════════════════════════════════════╝

📋 Deployment Summary
─────────────────────────────────────────────────────────────────
Resource Group:    $ResourceGroupName
App Service Name:  $AppServiceName
Environment:       STAGING ONLY

🌐 URLs
─────────────────────────────────────────────────────────────────
Staging (SLOW):    https://$AppServiceName-staging.azurewebsites.net
Production (OK):   https://$AppServiceName.azurewebsites.net

🧪 Test URLs (Staging - Degraded Performance)
─────────────────────────────────────────────────────────────────
Slow endpoint:     https://$AppServiceName-staging.azurewebsites.net/api/slowproducts
Fast endpoint:     https://$AppServiceName-staging.azurewebsites.net/api/products
Health check:      https://$AppServiceName-staging.azurewebsites.net/health
Metrics:           https://$AppServiceName-staging.azurewebsites.net/api/featureflag/metrics

📊 What to Observe
─────────────────────────────────────────────────────────────────
1. Azure Monitor Alerts (will fire within 5 minutes):
   - Response Time Alert (>1000ms)
   - Critical Response Time Alert (>2000ms)

2. Application Insights:
   - High response times in Performance tab
   - Slow requests in Live Metrics
   - Performance degradation charts

3. Health Endpoint Status:
   - Will report "Degraded" or "Unhealthy"

4. Production Remains Healthy:
   - Production slot is UNAFFECTED
   - Staging demonstrates the problem
   - No slot swap will occur

📖 Next Steps
─────────────────────────────────────────────────────────────────
1. Open Azure Portal and navigate to:
   Resource Group → Alerts → See fired alerts

2. Open Application Insights:
   Resource Group → $AppServiceName-ai → Performance

3. Compare staging vs production performance

4. To clean up, disable slow mode:
   curl -X POST https://$AppServiceName-staging.azurewebsites.net/api/featureflag/disable-slow-mode

"@ -ForegroundColor Yellow

Write-Warn "Staging deployment completed with DEGRADED performance"
Write-Success "Production remains healthy and unaffected"
