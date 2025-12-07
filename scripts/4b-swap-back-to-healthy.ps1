# Swap back from staging to production (rollback)
# This reverses the swap, putting the healthy version back in production

$ErrorActionPreference = "Stop"

# Get the app name from the config
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$configPath = Join-Path (Split-Path -Parent $scriptDir) "demo-config.json"

if (Test-Path $configPath) {
    $config = Get-Content $configPath | ConvertFrom-Json
    $appName = $config.appServiceName
    $resourceGroup = $config.resourceGroupName
} else {
    Write-Error "Config file not found. Run 1-deploy-infrastructure.ps1 first."
    exit 1
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  ROLLBACK: Swap Back to Healthy App" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

Write-Host "This will swap staging <-> production, rolling back to the previous version." -ForegroundColor Yellow
Write-Host ""
Write-Host "App Service: $appName" -ForegroundColor White
Write-Host "Resource Group: $resourceGroup" -ForegroundColor White
Write-Host ""

# Check current status before swap
Write-Host "Checking current production health..." -ForegroundColor Cyan
try {
    $healthBefore = Invoke-RestMethod -Uri "https://$appName.azurewebsites.net/health" -TimeoutSec 10
    Write-Host "  Current production status: $($healthBefore.status)" -ForegroundColor $(if ($healthBefore.status -eq "Healthy") { "Green" } else { "Red" })
} catch {
    Write-Host "  Could not reach production endpoint" -ForegroundColor Red
}

Write-Host ""
Write-Host "Performing swap (staging <-> production)..." -ForegroundColor Yellow

# Perform the swap
az webapp deployment slot swap `
    --name $appName `
    --resource-group $resourceGroup `
    --slot staging `
    --target-slot production

if ($LASTEXITCODE -ne 0) {
    Write-Error "Swap failed!"
    exit 1
}

Write-Host ""
Write-Host "Swap completed! Waiting for app to stabilize..." -ForegroundColor Green
Start-Sleep -Seconds 10

# Verify the rollback
Write-Host ""
Write-Host "Verifying rollback..." -ForegroundColor Cyan

try {
    $healthAfter = Invoke-RestMethod -Uri "https://$appName.azurewebsites.net/health" -TimeoutSec 10
    Write-Host "  Production status after rollback: $($healthAfter.status)" -ForegroundColor $(if ($healthAfter.status -eq "Healthy") { "Green" } else { "Yellow" })
} catch {
    Write-Host "  Could not verify health" -ForegroundColor Yellow
}

# Quick performance test
Write-Host ""
Write-Host "Running quick performance test..." -ForegroundColor Cyan
$times = @()
1..3 | ForEach-Object {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        Invoke-RestMethod -Uri "https://$appName.azurewebsites.net/api/products" -TimeoutSec 30 | Out-Null
        $sw.Stop()
        $times += $sw.ElapsedMilliseconds
        Write-Host "  Request $_: $($sw.ElapsedMilliseconds)ms" -ForegroundColor White
    } catch {
        Write-Host "  Request $_: Failed" -ForegroundColor Red
    }
}

if ($times.Count -gt 0) {
    $avg = [math]::Round(($times | Measure-Object -Average).Average)
    $status = if ($avg -lt 500) { "FAST" } elseif ($avg -lt 2000) { "SLOW" } else { "VERY SLOW" }
    $color = if ($avg -lt 500) { "Green" } elseif ($avg -lt 2000) { "Yellow" } else { "Red" }
    Write-Host ""
    Write-Host "  Average response time: ${avg}ms ($status)" -ForegroundColor $color
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host "  Rollback Complete!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host ""
Write-Host "Production URL: https://$appName.azurewebsites.net" -ForegroundColor White
Write-Host ""
