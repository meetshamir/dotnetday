# SRE Agent - Performance Anomaly Detection & Auto-Rollback
# Run every 15 minutes via scheduled task
# This script monitors performance baseline deviation and triggers rollback if needed

param(
    [string]$AppUrl = "https://sre-perf-demo-app-3304.azurewebsites.net",
    [string]$ResourceGroup = "dotnet-day-demo",
    [string]$AppName = "sre-perf-demo-app-3304",
    [double]$DeviationThresholdPercent = 100,  # Rollback if >100% slower (2x baseline)
    [int]$LookbackMinutes = 60,  # Look for deployments in last 60 mins
    [switch]$DryRun = $false  # Set to test without actually rolling back
)

$ErrorActionPreference = "Stop"

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $color = switch ($Level) {
        "ERROR" { "Red" }
        "WARN"  { "Yellow" }
        "SUCCESS" { "Green" }
        default { "White" }
    }
    Write-Host "[$timestamp] [$Level] $Message" -ForegroundColor $color
}

function Get-PerformanceSnapshot {
    param([string]$BaseUrl)
    
    try {
        $response = Invoke-RestMethod -Uri "$BaseUrl/api/baseline" -Method Get -TimeoutSec 30
        return $response
    }
    catch {
        Write-Log "Failed to get performance snapshot: $_" -Level "ERROR"
        return $null
    }
}

function Get-RecentDeployments {
    param(
        [string]$ResourceGroup,
        [string]$AppName,
        [int]$LookbackMinutes
    )
    
    $endTime = Get-Date
    $startTime = $endTime.AddMinutes(-$LookbackMinutes)
    
    Write-Log "Checking for slot swaps in the last $LookbackMinutes minutes..."
    
    try {
        # Query activity log for slot swap operations
        $logs = az monitor activity-log list `
            --resource-group $ResourceGroup `
            --query "[?(contains(operationName.value, 'swap') || contains(operationName.value, 'Swap')) && status.value=='Succeeded']" `
            --output json 2>$null | ConvertFrom-Json
        
        if ($logs -and $logs.Count -gt 0) {
            Write-Log "Found $($logs.Count) slot swap(s) in the last $LookbackMinutes minutes" -Level "WARN"
            return $logs
        }
        else {
            Write-Log "No recent slot swaps found"
            return @()
        }
    }
    catch {
        Write-Log "Failed to query activity log: $_" -Level "ERROR"
        return @()
    }
}

function Invoke-Rollback {
    param(
        [string]$ResourceGroup,
        [string]$AppName,
        [switch]$DryRun
    )
    
    Write-Log "INITIATING ROLLBACK - Swapping staging back to production..." -Level "WARN"
    
    if ($DryRun) {
        Write-Log "[DRY RUN] Would execute: az webapp deployment slot swap --name $AppName --resource-group $ResourceGroup --slot staging --action swap" -Level "WARN"
        return $true
    }
    
    try {
        az webapp deployment slot swap `
            --name $AppName `
            --resource-group $ResourceGroup `
            --slot staging `
            --action swap
        
        Write-Log "ROLLBACK COMPLETED - Staging slot swapped back to production" -Level "SUCCESS"
        return $true
    }
    catch {
        Write-Log "ROLLBACK FAILED: $_" -Level "ERROR"
        return $false
    }
}

function Send-Alert {
    param(
        [string]$Title,
        [string]$Message,
        [string]$Severity
    )
    
    # In production, integrate with PagerDuty, Slack, Teams, etc.
    Write-Log "ALERT [$Severity]: $Title - $Message" -Level $(if ($Severity -eq "Critical") { "ERROR" } else { "WARN" })
    
    # Example: Post to Teams webhook
    # $teamsWebhook = $env:TEAMS_WEBHOOK_URL
    # if ($teamsWebhook) {
    #     $body = @{
    #         "@type" = "MessageCard"
    #         "summary" = $Title
    #         "themeColor" = if ($Severity -eq "Critical") { "FF0000" } else { "FFA500" }
    #         "title" = $Title
    #         "text" = $Message
    #     } | ConvertTo-Json
    #     Invoke-RestMethod -Uri $teamsWebhook -Method Post -Body $body -ContentType "application/json"
    # }
}

# Main execution
Write-Log "=========================================="
Write-Log "SRE Agent - Performance Anomaly Detection"
Write-Log "=========================================="
Write-Log "App URL: $AppUrl"
Write-Log "Deviation Threshold: $DeviationThresholdPercent%"
Write-Log "Dry Run: $DryRun"
Write-Log ""

# Step 1: Get current performance snapshot
Write-Log "Step 1: Getting current performance snapshot..."
$snapshot = Get-PerformanceSnapshot -BaseUrl $AppUrl

if (-not $snapshot) {
    Write-Log "Cannot proceed without performance data" -Level "ERROR"
    exit 1
}

Write-Log "Current Metrics:"
Write-Log "  - Avg Response Time: $($snapshot.metrics.avgResponseTimeMs)ms"
Write-Log "  - P95 Response Time: $($snapshot.metrics.p95ResponseTimeMs)ms"
Write-Log "  - Max Response Time: $($snapshot.metrics.maxResponseTimeMs)ms"
Write-Log "  - Status: $($snapshot.metrics.status)"
Write-Log "  - Sample Count: $($snapshot.metrics.sampleCount)"
Write-Log ""
Write-Log "Baseline:"
Write-Log "  - Established: $($snapshot.baseline.established)"
Write-Log "  - Baseline Avg: $($snapshot.baseline.avgMs)ms"
Write-Log "  - Deviation: $($snapshot.baseline.deviationPercent)%"
Write-Log ""

# Step 2: Check for anomalies
$requiresAction = $false
$anomalyReason = ""

if ($snapshot.alerts.isUnhealthy) {
    $requiresAction = $true
    $anomalyReason = "Application is UNHEALTHY (avg > 1000ms)"
    Write-Log "ANOMALY DETECTED: $anomalyReason" -Level "ERROR"
}
elseif ($snapshot.alerts.significantDeviation -and $snapshot.baseline.deviationPercent -gt $DeviationThresholdPercent) {
    $requiresAction = $true
    $anomalyReason = "Performance deviation of $($snapshot.baseline.deviationPercent)% exceeds threshold of $DeviationThresholdPercent%"
    Write-Log "ANOMALY DETECTED: $anomalyReason" -Level "ERROR"
}
elseif ($snapshot.alerts.isDegraded) {
    $anomalyReason = "Application is DEGRADED (P95 > 2000ms)"
    Write-Log "WARNING: $anomalyReason" -Level "WARN"
    Send-Alert -Title "Performance Degradation Detected" -Message $anomalyReason -Severity "Warning"
}
else {
    Write-Log "Performance is within acceptable parameters" -Level "SUCCESS"
}

# Step 3: If anomaly detected, check for recent deployments
if ($requiresAction) {
    Write-Log ""
    Write-Log "Step 2: Checking for recent deployments..."
    $recentDeployments = Get-RecentDeployments -ResourceGroup $ResourceGroup -AppName $AppName -LookbackMinutes $LookbackMinutes
    
    if ($recentDeployments.Count -gt 0) {
        Write-Log "Recent deployment found - this is likely the cause of performance degradation" -Level "WARN"
        
        foreach ($deployment in $recentDeployments) {
            Write-Log "  - Swap at: $($deployment.eventTimestamp) by $($deployment.caller)"
        }
        
        # Send critical alert
        Send-Alert -Title "Performance Anomaly After Deployment" `
            -Message "Detected $anomalyReason after recent slot swap. Auto-rollback initiated." `
            -Severity "Critical"
        
        # Step 4: Execute rollback
        Write-Log ""
        Write-Log "Step 3: Executing rollback..."
        $rollbackSuccess = Invoke-Rollback -ResourceGroup $ResourceGroup -AppName $AppName -DryRun:$DryRun
        
        if ($rollbackSuccess) {
            Write-Log "Rollback completed successfully" -Level "SUCCESS"
            Send-Alert -Title "Auto-Rollback Completed" `
                -Message "Successfully rolled back to previous version due to $anomalyReason" `
                -Severity "Info"
        }
        else {
            Write-Log "Rollback failed - manual intervention required!" -Level "ERROR"
            Send-Alert -Title "Rollback Failed" `
                -Message "Auto-rollback failed! Manual intervention required. Reason: $anomalyReason" `
                -Severity "Critical"
        }
    }
    else {
        Write-Log "No recent deployments found - performance issue may be external (traffic spike, dependency issue)" -Level "WARN"
        Send-Alert -Title "Performance Anomaly - No Recent Deployment" `
            -Message "$anomalyReason - No recent deployment detected. Investigate external factors." `
            -Severity "Warning"
    }
}

Write-Log ""
Write-Log "SRE Agent check completed"
Write-Log "=========================================="

# Return exit code for monitoring
if ($requiresAction -and -not $DryRun) {
    exit 1
}
exit 0
