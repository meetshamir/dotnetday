using Microsoft.Extensions.Diagnostics.HealthChecks;
using System.Diagnostics;

public class PerformanceHealthCheck : IHealthCheck
{
    private static readonly List<double> ResponseTimes = new();
    private static readonly object Lock = new();

    public static void RecordResponseTime(double responseTimeMs)
    {
        lock (Lock)
        {
            ResponseTimes.Add(responseTimeMs);
            // Keep only last 100 measurements
            if (ResponseTimes.Count > 100)
            {
                ResponseTimes.RemoveAt(0);
            }
        }
    }

    public Task<HealthCheckResult> CheckHealthAsync(HealthCheckContext context, CancellationToken cancellationToken = default)
    {
        lock (Lock)
        {
            if (ResponseTimes.Count == 0)
            {
                return Task.FromResult(HealthCheckResult.Healthy("No response time data available yet"));
            }

            var avgResponseTime = ResponseTimes.Average();
            var maxResponseTime = ResponseTimes.Max();
            var p95ResponseTime = ResponseTimes.OrderBy(x => x).Skip((int)(ResponseTimes.Count * 0.95)).FirstOrDefault();

            var data = new Dictionary<string, object>
            {
                { "avgResponseTimeMs", Math.Round(avgResponseTime, 2) },
                { "maxResponseTimeMs", Math.Round(maxResponseTime, 2) },
                { "p95ResponseTimeMs", Math.Round(p95ResponseTime, 2) },
                { "sampleCount", ResponseTimes.Count }
            };

            // Performance thresholds
            if (avgResponseTime > 1000) // 1 second average
            {
                return Task.FromResult(HealthCheckResult.Unhealthy(
                    $"Average response time is too high: {avgResponseTime:F2}ms",
                    data: data));
            }

            if (p95ResponseTime > 2000) // 2 seconds for 95th percentile
            {
                return Task.FromResult(HealthCheckResult.Degraded(
                    $"95th percentile response time is high: {p95ResponseTime:F2}ms",
                    data: data));
            }

            return Task.FromResult(HealthCheckResult.Healthy(
                $"Performance is good. Avg: {avgResponseTime:F2}ms, P95: {p95ResponseTime:F2}ms",
                data: data));
        }
    }
}