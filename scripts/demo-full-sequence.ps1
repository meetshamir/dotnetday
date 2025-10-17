#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Complete SRE Performance Demo Sequence
.DESCRIPTION
    This script runs the complete SRE Performance Demo sequence from start to finish.
    It deploys infrastructure, healthy app, CPU-intensive version, swaps to production,
    generates load, and monitors for SRE Agent remediation.
.PARAMETER ResourceGroupName
    Name of the Azure resource group (default: sre-perf-demo-rg)
.PARAMETER Location
    Azure region for deployment (default: eastus)
.PARAMETER AppServiceName
    Name of the App Service (must be globally unique)
.PARAMETER DurationMinutes
    Duration for load generation and monitoring (default: 10)
.PARAMETER Email
    Email address for alert notifications (optional)
.EXAMPLE
    .\demo-full-sequence.ps1 -ResourceGroupName "sre-perf-demo-rg" -Location "eastus"
#>

param(
    [Parameter(Mandatory=$false)]
    [string]$ResourceGroupName = "sre-perf-demo-rg",

    [Parameter(Mandatory=$false)]
    [string]$Location = "eastus",

    [Parameter(Mandatory=$false)]
    [string]$AppServiceName = "sre-perf-demo-app-$(Get-Random -Maximum 9999)",

    [Parameter(Mandatory=$false)]
    [int]$DurationMinutes = 10,

    [Parameter(Mandatory=$false)]
    [string]$Email = ""
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
║          SRE Performance Demo - Full Sequence                 ║
║              Complete Demo from Start to Finish               ║
║                                                                ║
╚════════════════════════════════════════════════════════════════╝
"@ -ForegroundColor Cyan

Write-Info "Configuration:"
Write-Info "  Resource Group: $ResourceGroupName"
Write-Info "  Location: $Location"
Write-Info "  App Name: $AppServiceName"
Write-Info "  Duration: $DurationMinutes minutes"
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

# Step 1: Deploy Infrastructure
Write-Step "Step 1: Deploying Infrastructure"
Write-Info "This may take 5-10 minutes..."

try {
    & ".\1-deploy-infrastructure.ps1" -ResourceGroupName $ResourceGroupName -Location $Location -AppServiceName $AppServiceName
    if ($LASTEXITCODE -ne 0) {
        Write-Err "Infrastructure deployment failed"
        exit 1
    }
    Write-Success "Infrastructure deployed successfully"
} catch {
    Write-Err "Infrastructure deployment failed: $_"
    exit 1
}

# Step 2: Deploy Healthy App
Write-Step "Step 2: Deploying Healthy Application to Production"
Write-Info "Deploying healthy version with fast performance..."

try {
    & ".\2-deploy-healthy-app.ps1" -ResourceGroupName $ResourceGroupName -AppServiceName $AppServiceName
    if ($LASTEXITCODE -ne 0) {
        Write-Err "Healthy app deployment failed"
        exit 1
    }
    Write-Success "Healthy application deployed successfully"
} catch {
    Write-Err "Healthy app deployment failed: $_"
    exit 1
}

# Step 3: Deploy CPU-Intensive to Staging
Write-Step "Step 3: Deploying CPU-Intensive Version to Staging"
Write-Info "Deploying CPU-intensive version to staging slot..."

try {
    & ".\3-deploy-cpu-intensive-to-staging.ps1" -ResourceGroupName $ResourceGroupName -AppServiceName $AppServiceName
    if ($LASTEXITCODE -ne 0) {
        Write-Err "CPU-intensive deployment failed"
        exit 1
    }
    Write-Success "CPU-intensive version deployed to staging"
} catch {
    Write-Err "CPU-intensive deployment failed: $_"
    exit 1
}

# Step 4: Swap to Production
Write-Step "Step 4: Swapping to Production (Bad Deployment)"
Write-Info "Swapping CPU-intensive version to production..."

try {
    & ".\4-swap-to-production.ps1" -ResourceGroupName $ResourceGroupName -AppServiceName $AppServiceName
    if ($LASTEXITCODE -ne 0) {
        Write-Err "Slot swap failed"
        exit 1
    }
    Write-Success "Bad deployment is now in production"
} catch {
    Write-Err "Slot swap failed: $_"
    exit 1
}

# Step 5: Generate Load
Write-Step "Step 5: Generating Load to Trigger Alerts"
Write-Info "Generating load for $DurationMinutes minutes to trigger performance degradation..."

try {
    & ".\5-generate-load.ps1" -ResourceGroupName $ResourceGroupName -AppServiceName $AppServiceName -DurationMinutes $DurationMinutes
    if ($LASTEXITCODE -ne 0) {
        Write-Err "Load generation failed"
        exit 1
    }
    Write-Success "Load generation completed"
} catch {
    Write-Err "Load generation failed: $_"
    exit 1
}

# Step 6: Monitor SRE Agent
Write-Step "Step 6: Monitoring SRE Agent Remediation"
Write-Info "Monitoring for SRE Agent remediation for $DurationMinutes minutes..."

try {
    & ".\6-monitor-sre-agent.ps1" -ResourceGroupName $ResourceGroupName -AppServiceName $AppServiceName -MonitorMinutes $DurationMinutes
    if ($LASTEXITCODE -ne 0) {
        Write-Err "Monitoring failed"
        exit 1
    }
    Write-Success "Monitoring completed"
} catch {
    Write-Err "Monitoring failed: $_"
    exit 1
}

# Final Summary
Write-Host @"

╔════════════════════════════════════════════════════════════════╗
║                  DEMO SEQUENCE COMPLETED! 🎉                  ║
╚════════════════════════════════════════════════════════════════╝

📋 Demo Summary
─────────────────────────────────────────────────────────────────
Resource Group:    $ResourceGroupName
App Service Name:  $AppServiceName
Location:          $Location
Duration:          $DurationMinutes minutes

🌐 Application URLs
─────────────────────────────────────────────────────────────────
Production:        https://$AppServiceName.azurewebsites.net
Staging:           https://$AppServiceName-staging.azurewebsites.net
Health Check:      https://$AppServiceName.azurewebsites.net/health

📊 What Was Demonstrated
─────────────────────────────────────────────────────────────────
✅ Infrastructure deployment with monitoring
✅ Healthy application deployment
✅ CPU-intensive version deployment
✅ Bad deployment simulation (slot swap)
✅ Load generation and alert triggering
✅ SRE Agent monitoring and remediation

🧪 Demo Endpoints
─────────────────────────────────────────────────────────────────
Fast endpoints:    https://$AppServiceName.azurewebsites.net/api/products
CPU-intensive:     https://$AppServiceName.azurewebsites.net/api/cpuintensive
CPU stress test:   https://$AppServiceName.azurewebsites.net/api/cpuintensive/cpu-stress
Health check:      https://$AppServiceName.azurewebsites.net/health
Metrics:           https://$AppServiceName.azurewebsites.net/api/featureflag/metrics

📈 Monitoring Resources
─────────────────────────────────────────────────────────────────
Azure Monitor:     https://portal.azure.com → Resource Group → Alerts
Application Insights: https://portal.azure.com → Resource Group → $AppServiceName-ai
App Service:       https://portal.azure.com → Resource Group → $AppServiceName

🧹 Cleanup
─────────────────────────────────────────────────────────────────
To remove all resources:
az group delete --name $ResourceGroupName --yes --no-wait

📖 Documentation
─────────────────────────────────────────────────────────────────
See DEMO-SCRIPT.md for detailed walkthrough
See individual step scripts for manual execution

🎯 Learning Outcomes
─────────────────────────────────────────────────────────────────
1. ✅ Azure App Service deployment slots
2. ✅ Application Insights monitoring
3. ✅ Azure Monitor alerts
4. ✅ Performance degradation simulation
5. ✅ SRE Agent integration
6. ✅ Automated remediation workflows

"@ -ForegroundColor Green

Write-Success "Complete demo sequence finished successfully!"
Write-Info "Check Azure Portal to see the results and continue exploring the monitoring capabilities"
