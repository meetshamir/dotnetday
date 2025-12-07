using Microsoft.Extensions.Diagnostics.HealthChecks;
using SREPerfDemo.Services;

namespace SREPerfDemo;

/// <summary>
/// Health check for Cosmos DB dependency.
/// Reports status based on throttling rate and latency from the rolling window.
/// </summary>
public class CosmosDbHealthCheck : IHealthCheck
{
    private readonly CosmosDbMetrics _metrics;

    public CosmosDbHealthCheck(CosmosDbMetrics metrics)
    {
        _metrics = metrics;
    }

    public Task<HealthCheckResult> CheckHealthAsync(HealthCheckContext context, CancellationToken cancellationToken = default)
    {
        var snapshot = _metrics.GetSnapshot();

        if (snapshot.SampleCount == 0)
        {
            return Task.FromResult(HealthCheckResult.Healthy("No Cosmos DB operations recorded yet"));
        }

        var data = new Dictionary<string, object>
        {
            { "sampleCount", snapshot.SampleCount },
            { "avgLatencyMs", snapshot.AvgLatencyMs },
            { "p95LatencyMs", snapshot.P95LatencyMs },
            { "throttledCount", snapshot.ThrottledCount },
            { "throttledPercentage", snapshot.ThrottledPercentage },
            { "avgRequestCharge", snapshot.AvgRequestCharge },
            { "totalRequests", snapshot.TotalRequests },
            { "totalThrottled", snapshot.TotalThrottled }
        };

        return snapshot.Status switch
        {
            "Unhealthy" => Task.FromResult(HealthCheckResult.Unhealthy(snapshot.Message, data: data)),
            "Degraded" => Task.FromResult(HealthCheckResult.Degraded(snapshot.Message, data: data)),
            _ => Task.FromResult(HealthCheckResult.Healthy(snapshot.Message, data: data))
        };
    }
}
