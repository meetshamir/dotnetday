using System.Diagnostics;

public class PerformanceMiddleware
{
    private readonly RequestDelegate _next;
    private readonly ILogger<PerformanceMiddleware> _logger;

    public PerformanceMiddleware(RequestDelegate next, ILogger<PerformanceMiddleware> logger)
    {
        _next = next;
        _logger = logger;
    }

    public async Task InvokeAsync(HttpContext context)
    {
        var stopwatch = Stopwatch.StartNew();

        try
        {
            await _next(context);
        }
        finally
        {
            stopwatch.Stop();
            var responseTimeMs = stopwatch.Elapsed.TotalMilliseconds;

            // Record for health checks
            PerformanceHealthCheck.RecordResponseTime(responseTimeMs);

            // Log performance data
            _logger.LogInformation("Request {Method} {Path} completed in {ResponseTime}ms with status {StatusCode}",
                context.Request.Method,
                context.Request.Path,
                Math.Round(responseTimeMs, 2),
                context.Response.StatusCode);

            // Add custom header for monitoring
            context.Response.Headers.Add("X-Response-Time-Ms", responseTimeMs.ToString("F2"));

            // Log slow requests
            if (responseTimeMs > 500)
            {
                _logger.LogWarning("Slow request detected: {Method} {Path} took {ResponseTime}ms",
                    context.Request.Method,
                    context.Request.Path,
                    Math.Round(responseTimeMs, 2));
            }
        }
    }
}