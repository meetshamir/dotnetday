#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Deployment script for SRE Performance Demo - Healthy Production Deployment
.DESCRIPTION
    This script deploys the entire SRE Performance Demo infrastructure and application to Azure.
    It handles resource group creation, infrastructure deployment, and application deployment to PRODUCTION.
.PARAMETER ResourceGroupName
    Name of the Azure resource group (default: sre-perf-demo-rg)
.PARAMETER Location
    Azure region for deployment (default: eastus)
.PARAMETER AppServiceName
    Name of the App Service (must be globally unique)
.PARAMETER Email
    Email address for alert notifications (optional)
.PARAMETER SkipInfrastructure
    Skip infrastructure deployment (only deploy application)
.EXAMPLE
    .\deploy.ps1
    .\deploy.ps1 -AppServiceName "my-unique-app-name" -Location "westus2"
    .\deploy.ps1 -Email "admin@example.com"
#>

param(
    [Parameter(Mandatory=$false)]
    [string]$ResourceGroupName = "sre-perf-demo-rg",

    [Parameter(Mandatory=$false)]
    [string]$Location = "eastus",

    [Parameter(Mandatory=$false)]
    [string]$AppServiceName = "sre-perf-demo-app-$(Get-Random -Maximum 9999)",

    [Parameter(Mandatory=$false)]
    [string]$Email = "",

    [Parameter(Mandatory=$false)]
    [switch]$SkipInfrastructure
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
║          SRE Performance Demo - Deployment Script             ║
║                 (Healthy Production Deployment)                ║
║                                                                ║
╚════════════════════════════════════════════════════════════════╝
"@ -ForegroundColor Cyan

Write-Info "Configuration:"
Write-Info "  Resource Group: $ResourceGroupName"
Write-Info "  Location: $Location"
Write-Info "  App Name: $AppServiceName"
if ($Email) { Write-Info "  Email Alerts: $Email" }

# Check prerequisites
Write-Step "Checking Prerequisites"

# Check Azure CLI
try {
    $azVersion = az version --output json | ConvertFrom-Json
    Write-Success "Azure CLI version: $($azVersion.'azure-cli')"
} catch {
    Write-Err "Azure CLI is not installed. Please install from: https://aka.ms/InstallAzureCLIDocs"
    exit 1
}

# Check .NET SDK
try {
    $dotnetVersion = dotnet --version
    Write-Success ".NET SDK version: $dotnetVersion"
} catch {
    Write-Err ".NET SDK is not installed. Please install from: https://dotnet.microsoft.com/download"
    exit 1
}

# Check login status
Write-Step "Checking Azure Login Status"
$accountInfo = az account show 2>$null | ConvertFrom-Json
if (-not $accountInfo) {
    Write-Warn "Not logged in to Azure. Logging in..."
    az login
    $accountInfo = az account show | ConvertFrom-Json
}
Write-Success "Logged in as: $($accountInfo.user.name)"
Write-Success "Subscription: $($accountInfo.name) ($($accountInfo.id))"

# Create resource group
Write-Step "Creating Resource Group"
$rgExists = az group exists --name $ResourceGroupName
if ($rgExists -eq "true") {
    Write-Info "Resource group '$ResourceGroupName' already exists"
} else {
    az group create --name $ResourceGroupName --location $Location --output none
    Write-Success "Resource group '$ResourceGroupName' created"
}

# Deploy infrastructure
if (-not $SkipInfrastructure) {
    Write-Step "Deploying Infrastructure (This may take 5-10 minutes)"
    Write-Info "Creating App Service, Application Insights, and Monitor Alerts..."

    $deploymentResult = az deployment group create `
        --resource-group $ResourceGroupName `
        --template-file "infrastructure/main.bicep" `
        --parameters appServiceName=$AppServiceName location=$Location `
        --output json | ConvertFrom-Json

    if ($LASTEXITCODE -eq 0) {
        Write-Success "Infrastructure deployed successfully"

        # Display outputs
        $outputs = $deploymentResult.properties.outputs
        Write-Info "`nDeployment Outputs:"
        Write-Info "  Production URL: $($outputs.appServiceUrl.value)"
        Write-Info "  Staging URL: $($outputs.stagingUrl.value)"
        Write-Info "  App Insights Key: $($outputs.applicationInsightsInstrumentationKey.value)"
    } else {
        Write-Err "Infrastructure deployment failed"
        exit 1
    }
} else {
    Write-Warn "Skipping infrastructure deployment"
}

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

# Deploy to Production
Write-Step "Deploying to Production Slot"
Write-Info "Uploading and deploying application..."

az webapp deployment source config-zip `
    --resource-group $ResourceGroupName `
    --name $AppServiceName `
    --src "SREPerfDemo/deploy.zip" `
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

# Configure email alerts (if provided)
if ($Email) {
    Write-Step "Configuring Email Alerts"
    Write-Info "Adding email receiver: $Email"

    az monitor action-group update `
        --resource-group $ResourceGroupName `
        --name "$AppServiceName-alert-action-group" `
        --add-email-receiver name=admin email-address=$Email `
        --output none

    Write-Success "Email alerts configured for: $Email"
}

# Summary
Write-Host @"

╔════════════════════════════════════════════════════════════════╗
║                  DEPLOYMENT SUCCESSFUL! ✅                     ║
╚════════════════════════════════════════════════════════════════╝

📋 Deployment Summary
─────────────────────────────────────────────────────────────────
Resource Group:    $ResourceGroupName
App Service Name:  $AppServiceName
Location:          $Location

🌐 URLs
─────────────────────────────────────────────────────────────────
Production:        https://$AppServiceName.azurewebsites.net
Staging:           https://$AppServiceName-staging.azurewebsites.net
Health Check:      https://$AppServiceName.azurewebsites.net/health

📊 API Endpoints (Production - Fast)
─────────────────────────────────────────────────────────────────
GET  https://$AppServiceName.azurewebsites.net/api/products
GET  https://$AppServiceName.azurewebsites.net/api/products/1
GET  https://$AppServiceName.azurewebsites.net/api/products/search?query=test

🧪 Demo Next Steps
─────────────────────────────────────────────────────────────────
1. Test healthy production deployment:
   curl https://$AppServiceName.azurewebsites.net/health

2. Deploy bad performance to staging:
   .\deploy-bad-performance.ps1 -AppServiceName $AppServiceName

3. View Azure Monitor alerts in portal:
   https://portal.azure.com

4. View Application Insights:
   https://portal.azure.com

📖 Documentation
─────────────────────────────────────────────────────────────────
See DEMO-GUIDE.md for detailed usage instructions

"@ -ForegroundColor Green

Write-Success "Deployment completed successfully!"