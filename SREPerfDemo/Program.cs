using System.Diagnostics;
using Azure.Identity;
using Microsoft.Azure.Cosmos;
using SREPerfDemo;
using SREPerfDemo.Services;

var builder = WebApplication.CreateBuilder(args);

// Add services to the container.
builder.Services.AddOpenApi();

// Add Application Insights
builder.Services.AddApplicationInsightsTelemetry();

// Add Cosmos DB
var cosmosEndpoint = builder.Configuration["CosmosDb:Endpoint"];
var cosmosKey = builder.Configuration["CosmosDb:AccountKey"];
var useEntraAuth = builder.Configuration.GetValue<bool>("CosmosDb:UseEntraAuth", false);

if (!string.IsNullOrEmpty(cosmosEndpoint))
{
    builder.Services.AddSingleton(sp =>
    {
        var cosmosClientOptions = new CosmosClientOptions
        {
            ApplicationName = "SREPerfDemo",
            // Disable automatic retries to make throttling visible in demo
            MaxRetryAttemptsOnRateLimitedRequests = 0,
            MaxRetryWaitTimeOnRateLimitedRequests = TimeSpan.FromSeconds(0)
        };

        if (useEntraAuth)
        {
            // Use Managed Identity / Entra ID authentication
            var credential = new DefaultAzureCredential();
            return new CosmosClient(cosmosEndpoint, credential, cosmosClientOptions);
        }
        else if (!string.IsNullOrEmpty(cosmosKey))
        {
            // Use key-based authentication (for local development)
            return new CosmosClient(cosmosEndpoint, cosmosKey, cosmosClientOptions);
        }
        else
        {
            throw new InvalidOperationException("Cosmos DB authentication not configured. Set either CosmosDb:AccountKey or CosmosDb:UseEntraAuth=true");
        }
    });
    builder.Services.AddSingleton<CosmosDbMetrics>();
    builder.Services.AddSingleton<CosmosDbService>();
}

// Add health checks with custom performance checks
builder.Services.AddHealthChecks()
    .AddCheck<PerformanceHealthCheck>("performance")
    .AddCheck<CosmosDbHealthCheck>("cosmosdb")
    .AddCheck("memory", () =>
    {
        var memoryUsage = GC.GetTotalMemory(false);
        var threshold = 100 * 1024 * 1024; // 100MB threshold
        return memoryUsage < threshold
            ? Microsoft.Extensions.Diagnostics.HealthChecks.HealthCheckResult.Healthy($"Memory usage: {memoryUsage / 1024 / 1024}MB")
            : Microsoft.Extensions.Diagnostics.HealthChecks.HealthCheckResult.Degraded($"High memory usage: {memoryUsage / 1024 / 1024}MB");
    });

// Add controllers for organized endpoints
builder.Services.AddControllers();

// Add configuration for performance modes
builder.Services.Configure<PerformanceSettings>(builder.Configuration.GetSection("PerformanceSettings"));

var app = builder.Build();

// Configure the HTTP request pipeline.
if (app.Environment.IsDevelopment())
{
    app.MapOpenApi();
}

app.UseHttpsRedirection();

// Add performance monitoring middleware
app.UseMiddleware<PerformanceMiddleware>();

// Add health check endpoints
app.MapHealthChecks("/health", new Microsoft.AspNetCore.Diagnostics.HealthChecks.HealthCheckOptions
{
    ResponseWriter = async (context, report) =>
    {
        context.Response.ContentType = "application/json";
        var response = new
        {
            status = report.Status.ToString(),
            checks = report.Entries.Select(entry => new
            {
                name = entry.Key,
                status = entry.Value.Status.ToString(),
                description = entry.Value.Description,
                duration = entry.Value.Duration.TotalMilliseconds
            }),
            totalDuration = report.TotalDuration.TotalMilliseconds
        };
        await context.Response.WriteAsync(System.Text.Json.JsonSerializer.Serialize(response));
    }
});

// Map controllers
app.MapControllers();

var summaries = new[]
{
    "Freezing", "Bracing", "Chilly", "Cool", "Mild", "Warm", "Balmy", "Hot", "Sweltering", "Scorching"
};

app.MapGet("/weatherforecast", () =>
{
    var forecast =  Enumerable.Range(1, 5).Select(index =>
        new WeatherForecast
        (
            DateOnly.FromDateTime(DateTime.Now.AddDays(index)),
            Random.Shared.Next(-20, 55),
            summaries[Random.Shared.Next(summaries.Length)]
        ))
        .ToArray();
    return forecast;
})
.WithName("GetWeatherForecast");

app.Run();

record WeatherForecast(DateOnly Date, int TemperatureC, string? Summary)
{
    public int TemperatureF => 32 + (int)(TemperatureC / 0.5556);
}
