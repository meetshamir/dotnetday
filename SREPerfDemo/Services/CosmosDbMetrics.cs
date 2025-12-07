using System.Collections.Concurrent;

namespace SREPerfDemo.Services;

/// <summary>
/// Tracks Cosmos DB metrics using a rolling window of the last 100 operations.
/// Same pattern as PerformanceHealthCheck but for Cosmos DB dependency.
/// </summary>
public class CosmosDbMetrics
{
    private readonly List<CosmosDbOperationRecord> _records = new();
    private readonly object _lock = new();
    private const int MaxRecords = 100;

    // All-time counters
    private long _totalRequests;
    private long _totalThrottled;
    private double _totalRuConsumed;

    public void RecordOperation(CosmosDbOperationRecord record)
    {
        lock (_lock)
        {
            _records.Add(record);
            if (_records.Count > MaxRecords)
            {
                _records.RemoveAt(0);
            }

            // Update all-time counters
            _totalRequests++;
            _totalRuConsumed += record.RequestCharge;
            if (record.IsThrottled)
            {
                _totalThrottled++;
            }
        }
    }

    public CosmosDbMetricsSnapshot GetSnapshot()
    {
        lock (_lock)
        {
            if (_records.Count == 0)
            {
                return new CosmosDbMetricsSnapshot
                {
                    SampleCount = 0,
                    TotalRequests = _totalRequests,
                    TotalThrottled = _totalThrottled,
                    TotalRuConsumed = _totalRuConsumed,
                    Status = "Unknown",
                    Message = "No Cosmos DB operations recorded yet"
                };
            }

            var latencies = _records.Select(r => r.LatencyMs).OrderBy(x => x).ToList();
            var throttledCount = _records.Count(r => r.IsThrottled);
            var throttledPercentage = (double)throttledCount / _records.Count * 100;
            var successfulRecords = _records.Where(r => !r.IsThrottled).ToList();

            var avgLatency = latencies.Average();
            var p95Index = (int)(latencies.Count * 0.95);
            var p95Latency = latencies.Count > 0 ? latencies[Math.Min(p95Index, latencies.Count - 1)] : 0;
            var maxLatency = latencies.Max();
            var minLatency = latencies.Min();

            var avgRu = _records.Average(r => r.RequestCharge);
            var maxRu = _records.Max(r => r.RequestCharge);
            var totalRu = _records.Sum(r => r.RequestCharge);

            // Determine status
            string status;
            string message;

            if (throttledPercentage >= 20)
            {
                status = "Unhealthy";
                message = $"Critical throttling: {throttledPercentage:F1}% of requests throttled. Increase RU/s immediately.";
            }
            else if (throttledPercentage >= 5)
            {
                status = "Degraded";
                message = $"Throttling detected: {throttledPercentage:F1}% of requests throttled. Consider increasing RU/s.";
            }
            else if (avgLatency > 500)
            {
                status = "Degraded";
                message = $"High latency: Average {avgLatency:F1}ms. Check Cosmos DB performance.";
            }
            else
            {
                status = "Healthy";
                message = $"Cosmos DB is healthy. Avg latency: {avgLatency:F1}ms, Throttled: {throttledPercentage:F1}%";
            }

            return new CosmosDbMetricsSnapshot
            {
                SampleCount = _records.Count,
                AvgLatencyMs = Math.Round(avgLatency, 2),
                P95LatencyMs = Math.Round(p95Latency, 2),
                MaxLatencyMs = Math.Round(maxLatency, 2),
                MinLatencyMs = Math.Round(minLatency, 2),
                AvgRequestCharge = Math.Round(avgRu, 2),
                MaxRequestCharge = Math.Round(maxRu, 2),
                TotalRequestChargeInWindow = Math.Round(totalRu, 2),
                ThrottledCount = throttledCount,
                ThrottledPercentage = Math.Round(throttledPercentage, 2),
                SuccessCount = _records.Count - throttledCount,
                TotalRequests = _totalRequests,
                TotalThrottled = _totalThrottled,
                TotalRuConsumed = Math.Round(_totalRuConsumed, 2),
                Status = status,
                Message = message,
                RecentOperations = _records.TakeLast(10).Reverse().Select(r => new RecentOperation
                {
                    Timestamp = r.Timestamp,
                    Operation = r.OperationType,
                    LatencyMs = Math.Round(r.LatencyMs, 2),
                    RequestCharge = Math.Round(r.RequestCharge, 2),
                    IsThrottled = r.IsThrottled,
                    StatusCode = r.StatusCode
                }).ToList()
            };
        }
    }

    public void Reset()
    {
        lock (_lock)
        {
            _records.Clear();
            _totalRequests = 0;
            _totalThrottled = 0;
            _totalRuConsumed = 0;
        }
    }
}

public class CosmosDbOperationRecord
{
    public DateTime Timestamp { get; set; } = DateTime.UtcNow;
    public string OperationType { get; set; } = string.Empty;
    public double LatencyMs { get; set; }
    public double RequestCharge { get; set; }
    public bool IsThrottled { get; set; }
    public int StatusCode { get; set; }
    public string? ErrorMessage { get; set; }
}

public class CosmosDbMetricsSnapshot
{
    // Rolling window stats
    public int SampleCount { get; set; }
    public double AvgLatencyMs { get; set; }
    public double P95LatencyMs { get; set; }
    public double MaxLatencyMs { get; set; }
    public double MinLatencyMs { get; set; }
    public double AvgRequestCharge { get; set; }
    public double MaxRequestCharge { get; set; }
    public double TotalRequestChargeInWindow { get; set; }
    public int ThrottledCount { get; set; }
    public double ThrottledPercentage { get; set; }
    public int SuccessCount { get; set; }

    // All-time stats
    public long TotalRequests { get; set; }
    public long TotalThrottled { get; set; }
    public double TotalRuConsumed { get; set; }

    // Status
    public string Status { get; set; } = string.Empty;
    public string Message { get; set; } = string.Empty;

    // Recent operations
    public List<RecentOperation> RecentOperations { get; set; } = new();
}

public class RecentOperation
{
    public DateTime Timestamp { get; set; }
    public string Operation { get; set; } = string.Empty;
    public double LatencyMs { get; set; }
    public double RequestCharge { get; set; }
    public bool IsThrottled { get; set; }
    public int StatusCode { get; set; }
}
