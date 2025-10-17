#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Step 1: Deploy Azure infrastructure for SRE Performance Demo
.DESCRIPTION
    This script deploys the Azure infrastructure including App Service, Application Insights, and monitoring alerts.
    It's the first step in the demo sequence.
.PARAMETER ResourceGroupName
    Name of the Azure resource group (default: sre-perf-demo-rg)
.PARAMETER Location
    Azure region for deployment (default: eastus)
.PARAMETER AppServiceName
    Name of the App Service (must be globally unique)
.EXAMPLE
    .\1-deploy-infrastructure.ps1 -ResourceGroupName "sre-perf-demo-rg" -Location "eastus"
#>

param(
    [Parameter(Mandatory=$false)]
    [string]$ResourceGroupName = "sre-perf-demo-rg",

    [Parameter(Mandatory=$false)]
    [string]$Location = "eastus",

    [Parameter(Mandatory=$false)]
    [string]$AppServiceName = "sre-perf-demo-app-$(Get-Random -Maximum 9999)"
)

$ErrorActionPreference = "Stop"

# Get the script directory and set paths
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent $ScriptDir
$BicepTemplatePath = Join-Path $ProjectRoot "infrastructure\main.bicep"

# Color output functions
function Write-Success { Write-Host "[SUCCESS] $args" -ForegroundColor Green }
function Write-Info { Write-Host "[INFO] $args" -ForegroundColor Cyan }
function Write-Warn { Write-Host "[WARNING] $args" -ForegroundColor Yellow }
function Write-Err { Write-Host "[ERROR] $args" -ForegroundColor Red }
function Write-Step { Write-Host "`n[STEP] $args" -ForegroundColor Magenta }

Write-Host @"
╔════════════════════════════════════════════════════════════════╗
║                                                                ║
║          SRE Performance Demo - Step 1                        ║
║              Deploy Infrastructure                             ║
║                                                                ║
╚════════════════════════════════════════════════════════════════╝
"@ -ForegroundColor Cyan

Write-Info "Configuration:"
Write-Info "  Resource Group: $ResourceGroupName"
Write-Info "  Location: $Location"
Write-Info "  App Name: $AppServiceName"

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
Write-Step "Deploying Infrastructure (This may take 5-10 minutes)"
Write-Info "Creating App Service, Application Insights, and Monitor Alerts..."

$deploymentResult = az deployment group create `
    --resource-group $ResourceGroupName `
    --template-file $BicepTemplatePath `
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
    
    # Save configuration for next steps
    $config = @{
        ResourceGroupName = $ResourceGroupName
        AppServiceName = $AppServiceName
        Location = $Location
        ProductionUrl = $outputs.appServiceUrl.value
        StagingUrl = $outputs.stagingUrl.value
        ApplicationInsightsKey = $outputs.applicationInsightsInstrumentationKey.value
        DeploymentTime = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    }
    
    $configPath = Join-Path $ProjectRoot "demo-config.json"
    $config | ConvertTo-Json | Out-File -FilePath $configPath -Encoding UTF8
    Write-Success "Configuration saved to $configPath"
    
} else {
    Write-Err "Infrastructure deployment failed"
    exit 1
}

# Summary
Write-Host @"

╔════════════════════════════════════════════════════════════════╗
║              INFRASTRUCTURE DEPLOYED SUCCESSFULLY!             ║
╚════════════════════════════════════════════════════════════════╝

Infrastructure Summary
─────────────────────────────────────────────────────────────────
Resource Group:    $ResourceGroupName
App Service Name:  $AppServiceName
Location:          $Location

URLs
─────────────────────────────────────────────────────────────────
Production:        https://$AppServiceName.azurewebsites.net
Staging:           https://$AppServiceName-staging.azurewebsites.net

Monitoring Resources Created
─────────────────────────────────────────────────────────────────
[+] App Service Plan (S1 SKU)
[+] App Service with Production + Staging slots
[+] Application Insights
[+] Log Analytics Workspace
[+] Azure Monitor Alerts:
   - Response Time > 1000ms (Warning)
   - Response Time > 2000ms (Critical)
   - CPU > 80%
   - Memory > 85%

Next Steps
─────────────────────────────────────────────────────────────────
1. Deploy healthy application to production:
   .\2-deploy-healthy-app.ps1

2. View infrastructure in Azure Portal:
   https://portal.azure.com

Documentation
─────────────────────────────────────────────────────────────────
See DEMO-SCRIPT.md for complete demo walkthrough

"@ -ForegroundColor Green

Write-Success "Infrastructure deployment completed successfully!"
