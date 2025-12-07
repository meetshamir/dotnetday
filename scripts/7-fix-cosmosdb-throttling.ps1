#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Fix Cosmos DB throttling by scaling up RU/s
.DESCRIPTION
    This script increases the provisioned throughput on Cosmos DB
    to resolve throttling issues.
.PARAMETER RUs
    Target throughput in Request Units per second (default: 4000)
.PARAMETER ResourceGroupName
    Name of the Azure resource group
.EXAMPLE
    .\7-fix-cosmosdb-throttling.ps1
    .\7-fix-cosmosdb-throttling.ps1 -RUs 10000
#>

param(
    [Parameter(Mandatory=$false)]
    [int]$RUs = 4000,

    [Parameter(Mandatory=$false)]
    [string]$ResourceGroupName
)

$ErrorActionPreference = "Stop"

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
║          SRE Performance Demo - Fix Throttling                ║
║              Scale Up Cosmos DB Throughput                     ║
║                                                                ║
╚════════════════════════════════════════════════════════════════╝
"@ -ForegroundColor Green

# Load configuration
if ([string]::IsNullOrEmpty($ResourceGroupName)) {
    if (Test-Path $ConfigPath) {
        $config = Get-Content $ConfigPath | ConvertFrom-Json
        $ResourceGroupName = $config.ResourceGroupName
        $AppServiceName = $config.AppServiceName
        $BaseUrl = $config.ProductionUrl
        Write-Info "Loaded configuration from demo-config.json"
    } else {
        $ResourceGroupName = "dotnet-day-demo"
        Write-Warn "No config file found, using default resource group: $ResourceGroupName"
    }
}

Write-Info "Configuration:"
Write-Info "  Resource Group: $ResourceGroupName"
Write-Info "  Target RU/s: $RUs"

# Get Cosmos DB account name
Write-Step "Finding Cosmos DB Account"
$cosmosAccounts = az cosmosdb list --resource-group $ResourceGroupName --query "[].name" -o tsv 2>$null
if (-not $cosmosAccounts) {
    Write-Err "No Cosmos DB account found in resource group '$ResourceGroupName'"
    exit 1
}

$cosmosAccountName = $cosmosAccounts | Select-Object -First 1
Write-Success "Found Cosmos DB account: $cosmosAccountName"

# Get current throughput
Write-Step "Getting Current Throughput"
$currentThroughput = az cosmosdb sql container throughput show `
    --account-name $cosmosAccountName `
    --resource-group $ResourceGroupName `
    --database-name "ProductsDb" `
    --name "Products" `
    --query "resource.throughput" -o tsv 2>$null

if ($currentThroughput) {
    Write-Info "Current throughput: $currentThroughput RU/s"
} else {
    Write-Warn "Could not get current throughput"
    $currentThroughput = "unknown"
}

# Show before metrics if available
if ($BaseUrl) {
    Write-Step "Current Cosmos DB Status (Before Fix)"
    try {
        $beforeMetrics = Invoke-RestMethod -Uri "$BaseUrl/api/cosmos/metrics" -Method Get -TimeoutSec 10
        Write-Info "Status: $($beforeMetrics.cosmosDb.status)"
        Write-Info "Throttled: $($beforeMetrics.cosmosDb.rollingWindow.errors.throttledCount) requests ($($beforeMetrics.cosmosDb.rollingWindow.errors.throttledPercentage)%)"
        Write-Info "Avg Latency: $($beforeMetrics.cosmosDb.rollingWindow.latency.avgMs)ms"
    } catch {
        Write-Warn "Could not get current metrics"
    }
}

# Scale up
Write-Step "Scaling Up Cosmos DB to $RUs RU/s"
Write-Info "This may take a minute..."

$result = az cosmosdb sql container throughput update `
    --account-name $cosmosAccountName `
    --resource-group $ResourceGroupName `
    --database-name "ProductsDb" `
    --name "Products" `
    --throughput $RUs `
    --output json 2>&1

if ($LASTEXITCODE -eq 0) {
    Write-Success "Cosmos DB scaled to $RUs RU/s"
} else {
    Write-Err "Failed to scale Cosmos DB: $result"
    exit 1
}

# Wait for scale to take effect
Write-Info "Waiting for scale operation to take effect (30 seconds)..."
Start-Sleep -Seconds 30

# Verify new throughput
Write-Step "Verifying New Throughput"
$newThroughput = az cosmosdb sql container throughput show `
    --account-name $cosmosAccountName `
    --resource-group $ResourceGroupName `
    --database-name "ProductsDb" `
    --name "Products" `
    --query "resource.throughput" -o tsv

Write-Success "New throughput: $newThroughput RU/s"

# Show after metrics if available
if ($BaseUrl) {
    Write-Step "Cosmos DB Status (After Fix)"
    
    # Reset metrics to get fresh readings
    try {
        Invoke-RestMethod -Uri "$BaseUrl/api/cosmos/metrics/reset" -Method Post -TimeoutSec 10
        Write-Info "Metrics reset"
    } catch {}
    
    # Make a few test requests
    Write-Info "Making test requests..."
    for ($i = 0; $i -lt 10; $i++) {
        try {
            $null = Invoke-RestMethod -Uri "$BaseUrl/api/cosmos/products" -Method Get -TimeoutSec 30
            Write-Host "." -NoNewline -ForegroundColor Green
        } catch {
            Write-Host "." -NoNewline -ForegroundColor Red
        }
        Start-Sleep -Milliseconds 500
    }
    Write-Host ""
    
    # Get new metrics
    Start-Sleep -Seconds 2
    try {
        $afterMetrics = Invoke-RestMethod -Uri "$BaseUrl/api/cosmos/metrics" -Method Get -TimeoutSec 10
        Write-Success "Status: $($afterMetrics.cosmosDb.status)"
        Write-Info "Throttled: $($afterMetrics.cosmosDb.rollingWindow.errors.throttledCount) requests ($($afterMetrics.cosmosDb.rollingWindow.errors.throttledPercentage)%)"
        Write-Info "Avg Latency: $($afterMetrics.cosmosDb.rollingWindow.latency.avgMs)ms"
    } catch {
        Write-Warn "Could not get new metrics"
    }
}

Write-Host @"

╔════════════════════════════════════════════════════════════════╗
║                   ✅ THROTTLING FIXED! ✅                      ║
╠════════════════════════════════════════════════════════════════╣
║                                                                ║
║  Cosmos DB has been scaled from $($currentThroughput.ToString().PadRight(4)) to $($RUs.ToString().PadRight(5)) RU/s           ║
║                                                                ║
║  The application should now respond faster with                ║
║  no more throttling (429) errors.                              ║
║                                                                ║
╠════════════════════════════════════════════════════════════════╣
║  VERIFY THE FIX:                                               ║
║                                                                ║
║  1. Check health endpoint:                                     ║
║     $BaseUrl/health                                            ║
║                                                                ║
║  2. Check Cosmos metrics:                                      ║
║     $BaseUrl/api/cosmos/metrics                                ║
║                                                                ║
║  3. Run load test again (should succeed now):                 ║
║     .\6-trigger-cosmosdb-throttling.ps1                       ║
║                                                                ║
╠════════════════════════════════════════════════════════════════╣
║  TO RESET FOR NEXT DEMO:                                       ║
║                                                                ║
║  Scale back down to trigger throttling again:                 ║
║     .\7-fix-cosmosdb-throttling.ps1 -RUs 400                  ║
║                                                                ║
╚════════════════════════════════════════════════════════════════╝

"@ -ForegroundColor Green

Write-Success "Fix completed successfully!"
