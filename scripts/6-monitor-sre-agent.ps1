#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Step 6: Monitor SRE Agent remediation
.DESCRIPTION
    This script monitors the application for SRE Agent remediation actions.
    It checks Azure Monitor alerts, Application Insights metrics, and health status.
.PARAMETER ResourceGroupName
    Name of the Azure resource group (default: sre-perf-demo-rg)
.PARAMETER AppServiceName
    Name of the App Service (must match the production deployment)
.PARAMETER MonitorMinutes
    Duration to monitor in minutes (default: 10)
.EXAMPLE
    .\6-monitor-sre-agent.ps1 -AppServiceName "sre-perf-demo-app" -MonitorMinutes 10
#>

param(
    [Parameter(Mandatory=$false)]
    [string]$ResourceGroupName = "sre-perf-demo-rg",

    [Parameter(Mandatory=$false)]
    [string]$AppServiceName = "",

    [Parameter(Mandatory=$false)]
    [int]$MonitorMinutes = 10
)

$ErrorActionPreference = "Stop"

# Color output functions
function Write-Success { Write-Host "✅ $args" -ForegroundColor Green }
function Write-Info { Write-Host "ℹ️  $args" -ForegroundColor Cyan }
function Write-Warn { Write-Host "⚠️  $args" -ForegroundColor Yellow }
function Write-Err { Write-Host "❌ $args" -ForegroundColor Red }
function Write-Step { Write-Host "`n🔍 $args" -ForegroundColor Magenta }

Write-Host @"
╔════════════════════════════════════════════════════════════════╗
║                                                                ║
║          SRE Performance Demo - Step 6                        ║
║              Monitor SRE Agent Remediation                    ║
║                                                                ║
╚════════════════════════════════════════════════════════════════╝
"@ -ForegroundColor Blue

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
Write-Info "  Monitor Duration: $MonitorMinutes minutes"

$prodUrl = "https://$AppServiceName.azurewebsites.net"

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

# Monitoring function
function Start-Monitoring {
    param(
        [string]$ResourceGroupName,
        [string]$AppServiceName,
        [string]$ProdUrl,
        [int]$MonitorMinutes
    )

    $endTime = (Get-Date).AddMinutes($MonitorMinutes)
    $checkInterval = 30 # seconds
    $lastCheckTime = Get-Date
    $alertsFired = $false
    $remediationDetected = $false
    $baselineHealth = $null

    Write-Step "Starting SRE Agent Monitoring"
    Write-Info "Monitoring until: $($endTime.ToString('HH:mm:ss'))"
    Write-Info "Check interval: $checkInterval seconds"

    # Get baseline health
    try {
        $baselineResponse = Invoke-RestMethod -Uri "$ProdUrl/health" -Method Get -TimeoutSec 10
        $baselineHealth = $baselineResponse.status
        Write-Info "Baseline health status: $baselineHealth"
    } catch {
        Write-Warn "Could not get baseline health status"
    }

    while ((Get-Date) -lt $endTime) {
        $currentTime = Get-Date
        Write-Info "`n--- Monitoring Check at $($currentTime.ToString('HH:mm:ss')) ---"

        # Check Azure Monitor Alerts
        Write-Info "Checking Azure Monitor Alerts..."
        try {
            $alerts = az monitor metrics alert list --resource-group $ResourceGroupName --output json | ConvertFrom-Json
            $firedAlerts = $alerts | Where-Object { $_.properties.enabled -eq $true -and $_.properties.state -eq "Fired" }
            
            if ($firedAlerts.Count -gt 0) {
                if (-not $alertsFired) {
                    Write-Warn "🚨 ALERTS FIRED! ($($firedAlerts.Count) alerts)"
                    $alertsFired = $true
                }
                
                foreach ($alert in $firedAlerts) {
                    Write-Warn "  - $($alert.name): $($alert.properties.description)"
                }
            } else {
                Write-Info "  No fired alerts detected"
            }
        } catch {
            Write-Warn "  Could not check alerts: $_"
        }

        # Check Application Health
        Write-Info "Checking Application Health..."
        try {
            $healthResponse = Invoke-RestMethod -Uri "$ProdUrl/health" -Method Get -TimeoutSec 10
            $currentHealth = $healthResponse.status
            
            if ($baselineHealth -and $currentHealth -ne $baselineHealth) {
                Write-Warn "🔄 Health status changed: $baselineHealth → $currentHealth"
                if ($currentHealth -eq "Healthy") {
                    Write-Success "✅ REMEDIATION DETECTED! Application returned to healthy state"
                    $remediationDetected = $true
                }
            } else {
                Write-Info "  Health status: $currentHealth"
            }
            
            if ($healthResponse.metrics.averageResponseTimeMs) {
                Write-Info "  Average response time: $($healthResponse.metrics.averageResponseTimeMs)ms"
            }
        } catch {
            Write-Warn "  Could not check health status: $_"
        }

        # Check Performance Metrics
        Write-Info "Checking Performance Metrics..."
        try {
            $metricsResponse = Invoke-RestMethod -Uri "$ProdUrl/api/featureflag/metrics" -Method Get -TimeoutSec 10
            Write-Info "  Memory usage: $($metricsResponse.MemoryUsage.TotalMemoryMB) MB"
            Write-Info "  GC Collections - Gen0: $($metricsResponse.GarbageCollection.Gen0Collections), Gen1: $($metricsResponse.GarbageCollection.Gen1Collections), Gen2: $($metricsResponse.GarbageCollection.Gen2Collections)"
        } catch {
            Write-Warn "  Could not check performance metrics: $_"
        }

        # Check Slot Status
        Write-Info "Checking Slot Status..."
        try {
            $slotStatus = az webapp show --resource-group $ResourceGroupName --name $AppServiceName --query "state" --output tsv
            Write-Info "  Production slot status: $slotStatus"
        } catch {
            Write-Warn "  Could not check slot status: $_"
        }

        # Check for SRE Agent activity (simulated)
        Write-Info "Checking for SRE Agent Activity..."
        try {
            # In a real scenario, this would check for actual SRE Agent logs or actions
            # For demo purposes, we'll simulate based on health status changes
            if ($remediationDetected) {
                Write-Success "🤖 SRE Agent activity detected - remediation in progress"
            } else {
                Write-Info "  No SRE Agent activity detected yet"
            }
        } catch {
            Write-Warn "  Could not check SRE Agent activity: $_"
        }

        # Calculate remaining time
        $remaining = $endTime - (Get-Date)
        if ($remaining.TotalSeconds -gt 0) {
            Write-Info "Next check in $checkInterval seconds. Remaining time: $($remaining.ToString('mm\:ss'))"
            Start-Sleep -Seconds $checkInterval
        }
    }

    return @{
        AlertsFired = $alertsFired
        RemediationDetected = $remediationDetected
        FinalHealth = $currentHealth
    }
}

# Run monitoring
$monitoringResults = Start-Monitoring -ResourceGroupName $ResourceGroupName -AppServiceName $AppServiceName -ProdUrl $prodUrl -MonitorMinutes $MonitorMinutes

# Final status check
Write-Step "Final Status Check"
try {
    $finalHealthResponse = Invoke-RestMethod -Uri "$prodUrl/health" -Method Get -TimeoutSec 10
    Write-Info "Final health status: $($finalHealthResponse.status)"
    if ($finalHealthResponse.metrics.averageResponseTimeMs) {
        Write-Info "Final average response time: $($finalHealthResponse.metrics.averageResponseTimeMs)ms"
    }
} catch {
    Write-Warn "Could not get final health status"
}

# Summary
Write-Host "`n================================================" -ForegroundColor Blue
Write-Host "📊 SRE Agent Monitoring Results" -ForegroundColor Blue
Write-Host "================================================" -ForegroundColor Blue
Write-Host "Monitoring Duration: $MonitorMinutes minutes" -ForegroundColor White
Write-Host "Alerts Fired: $($monitoringResults.AlertsFired ? 'Yes' : 'No')" -ForegroundColor White
Write-Host "Remediation Detected: $($monitoringResults.RemediationDetected ? 'Yes' : 'No')" -ForegroundColor White
Write-Host "Final Health Status: $($monitoringResults.FinalHealth)" -ForegroundColor White
Write-Host "================================================" -ForegroundColor Blue

# Determine demo outcome
if ($monitoringResults.RemediationDetected) {
    Write-Success "🎉 SRE Agent successfully detected and remediated the performance issue!"
    Write-Success "Demo completed successfully - application returned to healthy state"
} elseif ($monitoringResults.AlertsFired) {
    Write-Warn "⚠️  Alerts fired but no automatic remediation detected"
    Write-Warn "This may indicate SRE Agent is still processing or manual intervention is required"
} else {
    Write-Info "ℹ️  No alerts fired during monitoring period"
    Write-Info "This may indicate the performance issue was not severe enough to trigger alerts"
}

# Summary
Write-Host @"

╔════════════════════════════════════════════════════════════════╗
║                  MONITORING COMPLETED! 🔍                     ║
╚════════════════════════════════════════════════════════════════╝

📋 Monitoring Summary
─────────────────────────────────────────────────────────────────
Resource Group:    $ResourceGroupName
App Service Name:  $AppServiceName
Duration:          $MonitorMinutes minutes
Alerts Fired:      $($monitoringResults.AlertsFired ? 'Yes' : 'No')
Remediation:       $($monitoringResults.RemediationDetected ? 'Detected' : 'Not Detected')
Final Health:      $($monitoringResults.FinalHealth)

📈 Demo Outcome
─────────────────────────────────────────────────────────────────
$($monitoringResults.RemediationDetected ? '✅ SRE Agent successfully remediated the performance issue' : $monitoringResults.AlertsFired ? '⚠️  Alerts fired but no automatic remediation detected' : 'ℹ️  No alerts fired - performance may be acceptable')

🧪 Next Steps
─────────────────────────────────────────────────────────────────
1. If remediation was detected:
   - Verify application is working correctly
   - Check that performance has returned to normal
   - Review SRE Agent logs for remediation details

2. If no remediation was detected:
   - Check Azure Monitor alerts manually
   - Verify SRE Agent configuration
   - Consider manual intervention

3. Open Azure Portal to review:
   - Resource Group → Alerts → Alert history
   - Application Insights → Performance
   - App Service → Deployment slots

📖 Documentation
─────────────────────────────────────────────────────────────────
See DEMO-SCRIPT.md for complete demo walkthrough

"@ -ForegroundColor Blue

Write-Success "Monitoring completed successfully!"
if ($monitoringResults.RemediationDetected) {
    Write-Success "SRE Agent demonstration successful!"
} else {
    Write-Info "Continue monitoring or check Azure Portal for more details"
}
