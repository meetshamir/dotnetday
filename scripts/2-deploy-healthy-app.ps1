#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Step 2: Deploy healthy application to production slot
.DESCRIPTION
    This script deploys the healthy version of the application to the production slot.
    It demonstrates normal, fast performance with response times of 10-100ms.
.PARAMETER ResourceGroupName
    Name of the Azure resource group (default: sre-perf-demo-rg)
.PARAMETER AppServiceName
    Name of the App Service (must match infrastructure deployment)
.EXAMPLE
    .\2-deploy-healthy-app.ps1 -AppServiceName "sre-perf-demo-app"
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
function Write-Step { Write-Host "`n🚀 $args" -ForegroundColor Magenta }

Write-Host @"
╔════════════════════════════════════════════════════════════════╗
║                                                                ║
║          SRE Performance Demo - Step 2                        ║
║              Deploy Healthy App to Production                  ║
║                                                                ║
╚════════════════════════════════════════════════════════════════╝
"@ -ForegroundColor Green

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
Push-Location "../SREPerfDemo"

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

# Deploy to Production
Write-Step "Deploying to Production Slot"
Write-Info "Uploading and deploying healthy application..."

az webapp deployment source config-zip `
    --resource-group $ResourceGroupName `
    --name $AppServiceName `
    --src "../SREPerfDemo/deploy.zip" `
    --output none

if ($LASTEXITCODE -eq 0) {
    Write-Success "Deployed to production"
} else {
    Write-Err "Production deployment failed"
    exit 1
}

# Wait for app to start
Write-Info "Waiting for application to start (30 seconds)..."
Start-Sleep -Seconds 30

# Health check
Write-Step "Running Health Check"
$prodUrl = "https://$AppServiceName.azurewebsites.net"
$healthUrl = "$prodUrl/health"

try {
    $response = Invoke-RestMethod -Uri $healthUrl -Method Get -TimeoutSec 30
    if ($response.status -eq "Healthy") {
        Write-Success "Production is HEALTHY"
        Write-Info "  Status: $($response.status)"
        if ($response.metrics.averageResponseTimeMs) {
            Write-Info "  Average Response Time: $($response.metrics.averageResponseTimeMs)ms"
        }
    } else {
        Write-Warn "Production is $($response.status)"
        Write-Info "  Status: $($response.status)"
        if ($response.metrics.averageResponseTimeMs) {
            Write-Info "  Average Response Time: $($response.metrics.averageResponseTimeMs)ms"
        }
    }
} catch {
    Write-Warn "Health check failed: $_"
}

# Performance test
Write-Step "Running Performance Tests"
Write-Info "Testing healthy endpoints (expect fast responses)..."

$endpoints = @("/api/products", "/api/products/1", "/api/products/search?query=test")
$responseTimes = @()
$fastRequests = 0

foreach ($endpoint in $endpoints) {
    for ($i = 1; $i -le 3; $i++) {
        $url = "$prodUrl$endpoint"
        Write-Info "Testing $endpoint - Attempt $i"

        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            $httpResponse = Invoke-WebRequest -Uri $url -Method Get -TimeoutSec 10
            $stopwatch.Stop()
            $responseTime = $stopwatch.ElapsedMilliseconds

            if ($httpResponse.StatusCode -eq 200) {
                $responseTimes += $responseTime
                Write-Info "  ✓ Response: $($httpResponse.StatusCode) - Time: ${responseTime}ms"

                if ($responseTime -lt 500) {
                    $fastRequests++
                    Write-Success "  FAST response: ${responseTime}ms"
                }
            }
        } catch {
            Write-Warn "  Request failed: $($_.Exception.Message)"
        }

        Start-Sleep -Seconds 1
    }
}

if ($responseTimes.Count -gt 0) {
    $avgResponseTime = ($responseTimes | Measure-Object -Average).Average
    Write-Host "`n================================================" -ForegroundColor Green
    Write-Host "📊 Performance Test Results" -ForegroundColor Green
    Write-Host "================================================" -ForegroundColor Green
    Write-Host "Total successful requests: $($responseTimes.Count)" -ForegroundColor White
    Write-Host "Fast requests (<500ms): $fastRequests" -ForegroundColor White
    Write-Host "Average response time: ${avgResponseTime}ms" -ForegroundColor White
    Write-Host "" -ForegroundColor White

    if ($avgResponseTime -lt 500) {
        Write-Success "✅ Performance EXCELLENT - Average under 500ms threshold"
        Write-Success "Production is ready for demo"
    } else {
        Write-Warn "Performance acceptable but higher than expected"
    }
    Write-Host "================================================" -ForegroundColor Green
}

# Summary
Write-Host @"

╔════════════════════════════════════════════════════════════════╗
║                  HEALTHY APP DEPLOYED! ✅                       ║
╚════════════════════════════════════════════════════════════════╝

📋 Deployment Summary
─────────────────────────────────────────────────────────────────
Resource Group:    $ResourceGroupName
App Service Name:  $AppServiceName
Environment:       PRODUCTION (Healthy)

🌐 URLs
─────────────────────────────────────────────────────────────────
Production:        https://$AppServiceName.azurewebsites.net
Health Check:      https://$AppServiceName.azurewebsites.net/health

🧪 Test URLs (Production - Fast Performance)
─────────────────────────────────────────────────────────────────
Fast endpoint:     https://$AppServiceName.azurewebsites.net/api/products
Single product:    https://$AppServiceName.azurewebsites.net/api/products/1
Search:            https://$AppServiceName.azurewebsites.net/api/products/search?query=test
Health check:      https://$AppServiceName.azurewebsites.net/health
Metrics:           https://$AppServiceName.azurewebsites.net/api/featureflag/metrics

📊 Expected Performance
─────────────────────────────────────────────────────────────────
✅ Response Times: 10-100ms
✅ Health Status: "Healthy"
✅ No alerts triggered
✅ Fast database queries
✅ Optimized processing

🧪 Next Steps
─────────────────────────────────────────────────────────────────
1. Deploy CPU-intensive version to staging:
   .\3-deploy-cpu-intensive-to-staging.ps1

2. View Application Insights:
   https://portal.azure.com

📖 Documentation
─────────────────────────────────────────────────────────────────
See DEMO-SCRIPT.md for complete demo walkthrough

"@ -ForegroundColor Green

Write-Success "Healthy application deployment completed successfully!"
