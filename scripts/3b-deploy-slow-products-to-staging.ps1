#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Step 3b: Deploy SLOW Products API to staging (realistic bad deployment)
.DESCRIPTION
    This script deploys the same application but with EnableSlowEndpoints=true,
    which makes the /api/products endpoints slow due to simulated:
    - N+1 query patterns
    - Missing database indexes
    - CPU-intensive validation added by mistake
    
    This is MORE REALISTIC than the CPU-intensive controller because:
    - The SAME endpoints become slow (not different endpoints)
    - It simulates a common developer mistake (removing query optimization)
    - Alerts on /api/products response time will fire
.PARAMETER AppChoice
    Which app to deploy to: 1, 2, or both
.EXAMPLE
    .\3b-deploy-slow-products-to-staging.ps1 -AppChoice 1
#>

param(
    [Parameter(Mandatory=$false)]
    [ValidateSet("1", "2", "both")]
    [string]$AppChoice = "1"
)

$ErrorActionPreference = "Stop"

# App choice mapping
$AppMap = @{
    "1" = @{ Name = "sre-perf-demo-app-3198"; ResourceGroup = "sre-perf-demo-rg" }
    "2" = @{ Name = "sre-perf-demo-app-7380"; ResourceGroup = "dotnet-day-demo" }
}

# Get the script directory and set paths
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent $ScriptDir
$AppPath = Join-Path $ProjectRoot "SREPerfDemo"

# Color output functions
function Write-Success { param([string]$Message) Write-Host "[SUCCESS] $Message" -ForegroundColor Green }
function Write-Info { param([string]$Message) Write-Host "[INFO] $Message" -ForegroundColor Cyan }
function Write-Warn { param([string]$Message) Write-Host "[WARNING] $Message" -ForegroundColor Yellow }
function Write-Err { param([string]$Message) Write-Host "[ERROR] $Message" -ForegroundColor Red }
function Write-Step { param([string]$Message) Write-Host "`n[STEP] $Message" -ForegroundColor Magenta }

Write-Host @"
╔════════════════════════════════════════════════════════════════╗
║                                                                ║
║          SRE Performance Demo - Step 3b                        ║
║          Deploy SLOW Products API to Staging                   ║
║                                                                ║
║    This simulates a realistic bad deployment where the         ║
║    /api/products endpoints become slow due to:                 ║
║    - N+1 query patterns                                        ║
║    - Missing database indexes                                  ║
║    - CPU-intensive validation added by mistake                 ║
║                                                                ║
╚════════════════════════════════════════════════════════════════╝
"@ -ForegroundColor Yellow

# Determine which apps to process
if ($AppChoice -eq "both") {
    $appsToProcess = @("1", "2")
} else {
    $appsToProcess = @($AppChoice)
}

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

# Check login
$accountInfo = az account show 2>$null | ConvertFrom-Json
if (-not $accountInfo) {
    Write-Err "Not logged in to Azure. Run 'az login'"
    exit 1
}
Write-Success "Logged in as: $($accountInfo.user.name)"

# Check .NET SDK
try {
    $dotnetVersion = dotnet --version
    Write-Success ".NET SDK version: $dotnetVersion"
} catch {
    Write-Err ".NET SDK is not installed"
    exit 1
}

# Process each app
foreach ($appKey in $appsToProcess) {
    $app = $AppMap[$appKey]
    $AppServiceName = $app.Name
    $ResourceGroupName = $app.ResourceGroup

    Write-Host "`n" -NoNewline
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Yellow
    Write-Host "  Processing App $appKey`: $AppServiceName" -ForegroundColor Yellow
    Write-Host "  Resource Group: $ResourceGroupName" -ForegroundColor Yellow
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Yellow

    # Verify app exists
    Write-Step "Verifying App Service exists"
    $appExists = az webapp show --name $AppServiceName --resource-group $ResourceGroupName --query "name" -o tsv 2>$null
    if (-not $appExists) {
        Write-Err "App Service '$AppServiceName' not found in resource group '$ResourceGroupName'"
        Write-Info "Run step 1 first to deploy infrastructure"
        continue
    }
    Write-Success "App Service '$AppServiceName' found"

    # Verify staging slot exists
    Write-Step "Verifying staging slot exists"
    $slotExists = az webapp deployment slot list --name $AppServiceName --resource-group $ResourceGroupName --query "[?name=='staging'].name" -o tsv 2>$null
    if (-not $slotExists) {
        Write-Warn "Staging slot does not exist. Creating it..."
        az webapp deployment slot create --name $AppServiceName --resource-group $ResourceGroupName --slot staging --output none
        Write-Success "Staging slot created"
    } else {
        Write-Success "Staging slot exists"
    }

    # Build the application
    Write-Step "Building Application"
    Push-Location $AppPath
    try {
        Write-Info "Publishing application..."
        dotnet publish -c Release -o ./publish --verbosity quiet
        if ($LASTEXITCODE -ne 0) {
            Write-Err "Build failed"
            Pop-Location
            continue
        }
        Write-Success "Application built successfully"

        # Create deployment package
        Write-Info "Creating deployment package..."
        $publishPath = Join-Path $AppPath "publish"
        $zipPath = Join-Path $AppPath "deploy-slow.zip"
        
        if (Test-Path $zipPath) {
            Remove-Item $zipPath -Force
        }
        
        Compress-Archive -Path "$publishPath\*" -DestinationPath $zipPath -Force
        Write-Success "Deployment package created: $zipPath"
    }
    finally {
        Pop-Location
    }

    # Deploy to staging slot
    Write-Step "Deploying to Staging Slot"
    Write-Info "Deploying application to staging..."
    
    az webapp deploy `
        --resource-group $ResourceGroupName `
        --name $AppServiceName `
        --slot staging `
        --src-path $zipPath `
        --type zip `
        --output none

    if ($LASTEXITCODE -ne 0) {
        Write-Err "Deployment to staging failed"
        continue
    }
    Write-Success "Application deployed to staging"

    # Configure staging with SLOW endpoints ENABLED
    Write-Step "Configuring Staging for SLOW Performance"
    Write-Warn "Enabling EnableSlowEndpoints=true on staging..."
    
    az webapp config appsettings set `
        --resource-group $ResourceGroupName `
        --name $AppServiceName `
        --slot staging `
        --settings `
            "PerformanceSettings__EnableSlowEndpoints=true" `
            "PerformanceSettings__EnableCpuIntensiveEndpoints=false" `
        --output none

    if ($LASTEXITCODE -ne 0) {
        Write-Err "Failed to configure staging settings"
        continue
    }
    Write-Success "Staging configured with EnableSlowEndpoints=true"

    # Ensure production has HEALTHY settings
    Write-Step "Ensuring Production is Healthy"
    az webapp config appsettings set `
        --resource-group $ResourceGroupName `
        --name $AppServiceName `
        --settings `
            "PerformanceSettings__EnableSlowEndpoints=false" `
            "PerformanceSettings__EnableCpuIntensiveEndpoints=false" `
        --output none

    Write-Success "Production configured with EnableSlowEndpoints=false"

    # Restart staging to apply settings
    Write-Step "Restarting Staging Slot"
    az webapp restart --resource-group $ResourceGroupName --name $AppServiceName --slot staging --output none
    Write-Success "Staging slot restarted"

    # Wait for startup
    Write-Info "Waiting for staging to warm up (30 seconds)..."
    Start-Sleep -Seconds 30

    # Test staging endpoints
    Write-Step "Testing Staging (Should be SLOW)"
    $stagingUrl = "https://$AppServiceName-staging.azurewebsites.net"
    
    $testEndpoints = @(
        "/api/products",
        "/api/products/1",
        "/api/products/search?query=electronics"
    )

    $stagingTimes = @()
    foreach ($endpoint in $testEndpoints) {
        $url = "$stagingUrl$endpoint"
        Write-Info "Testing: $endpoint"
        
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            $response = Invoke-WebRequest -Uri $url -Method Get -TimeoutSec 60
            $stopwatch.Stop()
            $responseTime = $stopwatch.ElapsedMilliseconds
            $stagingTimes += $responseTime
            
            if ($responseTime -gt 1000) {
                Write-Warn "  Response: $($response.StatusCode) - Time: ${responseTime}ms [SLOW - Expected!]"
            } else {
                Write-Info "  Response: $($response.StatusCode) - Time: ${responseTime}ms"
            }
        } catch {
            $stopwatch.Stop()
            Write-Warn "  Request failed: $($_.Exception.Message)"
        }
    }

    # Test production endpoints
    Write-Step "Testing Production (Should be FAST)"
    $prodUrl = "https://$AppServiceName.azurewebsites.net"
    
    $prodTimes = @()
    foreach ($endpoint in $testEndpoints) {
        $url = "$prodUrl$endpoint"
        Write-Info "Testing: $endpoint"
        
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            $response = Invoke-WebRequest -Uri $url -Method Get -TimeoutSec 60
            $stopwatch.Stop()
            $responseTime = $stopwatch.ElapsedMilliseconds
            $prodTimes += $responseTime
            
            if ($responseTime -lt 200) {
                Write-Success "  Response: $($response.StatusCode) - Time: ${responseTime}ms [FAST - Expected!]"
            } else {
                Write-Warn "  Response: $($response.StatusCode) - Time: ${responseTime}ms"
            }
        } catch {
            $stopwatch.Stop()
            Write-Warn "  Request failed: $($_.Exception.Message)"
        }
    }

    # Summary for this app
    $avgStaging = if ($stagingTimes.Count -gt 0) { [math]::Round(($stagingTimes | Measure-Object -Average).Average) } else { "N/A" }
    $avgProd = if ($prodTimes.Count -gt 0) { [math]::Round(($prodTimes | Measure-Object -Average).Average) } else { "N/A" }

    Write-Host @"

╔════════════════════════════════════════════════════════════════╗
║          App $appKey Deployment Complete                              ║
╚════════════════════════════════════════════════════════════════╝

Configuration Summary
─────────────────────────────────────────────────────────────────
App Service:       $AppServiceName
Resource Group:    $ResourceGroupName

Slot Configuration
─────────────────────────────────────────────────────────────────
PRODUCTION:  EnableSlowEndpoints = false  (HEALTHY - fast)
STAGING:     EnableSlowEndpoints = true   (SLOW - bad deployment)

Performance Comparison
─────────────────────────────────────────────────────────────────
Production Avg Response Time:  ${avgProd}ms
Staging Avg Response Time:     ${avgStaging}ms

Test URLs
─────────────────────────────────────────────────────────────────
Production (FAST):
  - https://$AppServiceName.azurewebsites.net/api/products
  - https://$AppServiceName.azurewebsites.net/api/products/1

Staging (SLOW):
  - https://$AppServiceName-staging.azurewebsites.net/api/products
  - https://$AppServiceName-staging.azurewebsites.net/api/products/1

"@ -ForegroundColor Cyan
}

# Final summary
Write-Host @"
╔════════════════════════════════════════════════════════════════╗
║          REALISTIC BAD DEPLOYMENT READY                        ║
╚════════════════════════════════════════════════════════════════╝

What makes this realistic?
─────────────────────────────────────────────────────────────────
✓ SAME /api/products endpoints become slow (not different endpoints)
✓ Simulates common developer mistakes:
  - N+1 query patterns (20 individual lookups vs 1 batch)
  - Missing database index (full table scan)
  - CPU-intensive "security validation" added by mistake
✓ Response times go from ~50ms to ~2000-5000ms
✓ Alerts on /api/products will fire after swap

Next Steps
─────────────────────────────────────────────────────────────────
1. Verify the difference:
   # Test production (fast)
   .\5-generate-load.ps1 -AppChoice 1 -Slot prod -EndpointMode healthy
   
   # Test staging (slow)
   .\5-generate-load.ps1 -AppChoice 1 -Slot staging -EndpointMode healthy

2. Swap to production (simulate bad deployment going live):
   .\4-swap-to-production.ps1 -AppChoice 1

3. Generate load to trigger alerts:
   .\5-generate-load.ps1 -AppChoice 1 -EndpointMode healthy

4. Watch SRE Agent detect and remediate the issue

"@ -ForegroundColor Green

Write-Success "Slow products deployment staged and ready for swap!"
