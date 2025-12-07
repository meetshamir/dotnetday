using Microsoft.AspNetCore.Mvc;
using Microsoft.Azure.Cosmos;
using SREPerfDemo.Services;
using System.Net;

namespace SREPerfDemo.Controllers;

/// <summary>
/// API controller for Cosmos DB-backed products.
/// Used for Scenario 2: Demonstrating Cosmos DB throttling issues.
/// </summary>
[ApiController]
[Route("api/cosmos")]
public class CosmosProductsController : ControllerBase
{
    private readonly CosmosDbService _cosmosDbService;
    private readonly CosmosDbMetrics _metrics;
    private readonly ILogger<CosmosProductsController> _logger;

    public CosmosProductsController(CosmosDbService cosmosDbService, CosmosDbMetrics metrics, ILogger<CosmosProductsController> logger)
    {
        _cosmosDbService = cosmosDbService;
        _metrics = metrics;
        _logger = logger;
    }

    /// <summary>
    /// Get all products from Cosmos DB
    /// </summary>
    [HttpGet("products")]
    public async Task<IActionResult> GetAllProducts()
    {
        try
        {
            var products = await _cosmosDbService.GetAllProductsAsync();
            return Ok(products);
        }
        catch (CosmosException ex) when (ex.StatusCode == HttpStatusCode.TooManyRequests)
        {
            _logger.LogWarning("Request throttled by Cosmos DB");
            return StatusCode(503, new { error = "Service temporarily unavailable due to high demand", retryAfterMs = ex.RetryAfter?.TotalMilliseconds });
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Error retrieving products from Cosmos DB");
            return StatusCode(500, new { error = "Failed to retrieve products", details = ex.Message });
        }
    }

    /// <summary>
    /// Get a single product by ID (point read - low RU)
    /// </summary>
    [HttpGet("products/{id}")]
    public async Task<IActionResult> GetProductById(string id, [FromQuery] string category = "Electronics")
    {
        try
        {
            var product = await _cosmosDbService.GetProductByIdAsync(id, category);
            if (product == null)
            {
                return NotFound(new { error = "Product not found", id });
            }
            return Ok(product);
        }
        catch (CosmosException ex) when (ex.StatusCode == HttpStatusCode.TooManyRequests)
        {
            _logger.LogWarning("Request throttled by Cosmos DB");
            return StatusCode(503, new { error = "Service temporarily unavailable due to high demand", retryAfterMs = ex.RetryAfter?.TotalMilliseconds });
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Error retrieving product {Id} from Cosmos DB", id);
            return StatusCode(500, new { error = "Failed to retrieve product", details = ex.Message });
        }
    }

    /// <summary>
    /// Search products (cross-partition query - moderate RU)
    /// </summary>
    [HttpGet("products/search")]
    public async Task<IActionResult> SearchProducts([FromQuery] string query = "product")
    {
        try
        {
            var products = await _cosmosDbService.SearchProductsAsync(query);
            return Ok(new { query, count = products.Count, products });
        }
        catch (CosmosException ex) when (ex.StatusCode == HttpStatusCode.TooManyRequests)
        {
            _logger.LogWarning("Search request throttled by Cosmos DB");
            return StatusCode(503, new { error = "Service temporarily unavailable due to high demand", retryAfterMs = ex.RetryAfter?.TotalMilliseconds });
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Error searching products in Cosmos DB");
            return StatusCode(500, new { error = "Failed to search products", details = ex.Message });
        }
    }

    /// <summary>
    /// Create a new product
    /// </summary>
    [HttpPost("products")]
    public async Task<IActionResult> CreateProduct([FromBody] CosmosProduct product)
    {
        try
        {
            var created = await _cosmosDbService.CreateProductAsync(product);
            return CreatedAtAction(nameof(GetProductById), new { id = created.Id }, created);
        }
        catch (CosmosException ex) when (ex.StatusCode == HttpStatusCode.TooManyRequests)
        {
            _logger.LogWarning("Create request throttled by Cosmos DB");
            return StatusCode(503, new { error = "Service temporarily unavailable due to high demand", retryAfterMs = ex.RetryAfter?.TotalMilliseconds });
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Error creating product in Cosmos DB");
            return StatusCode(500, new { error = "Failed to create product", details = ex.Message });
        }
    }

    /// <summary>
    /// Run expensive aggregation query (high RU - for triggering throttling)
    /// </summary>
    [HttpGet("expensive-query")]
    public async Task<IActionResult> RunExpensiveQuery()
    {
        try
        {
            var result = await _cosmosDbService.RunExpensiveQueryAsync();
            return Ok(result);
        }
        catch (CosmosException ex) when (ex.StatusCode == HttpStatusCode.TooManyRequests)
        {
            _logger.LogWarning("Expensive query throttled by Cosmos DB");
            return StatusCode(503, new { error = "Service temporarily unavailable due to high demand", retryAfterMs = ex.RetryAfter?.TotalMilliseconds });
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Error running expensive query");
            return StatusCode(500, new { error = "Failed to run query", details = ex.Message });
        }
    }

    /// <summary>
    /// Simulate Black Friday traffic burst - runs many queries rapidly to trigger throttling
    /// </summary>
    [HttpPost("black-friday")]
    public async Task<IActionResult> SimulateBlackFriday([FromQuery] int requests = 100)
    {
        var results = new { succeeded = 0, throttled = 0, errors = 0, totalRu = 0.0 };
        int succeeded = 0, throttled = 0, errors = 0;
        double totalRu = 0;

        _logger.LogWarning("BLACK FRIDAY SIMULATION: Starting {Count} rapid requests", requests);

        // Run many requests as fast as possible to exhaust RU budget
        var tasks = Enumerable.Range(0, requests).Select(async i =>
        {
            try
            {
                var products = await _cosmosDbService.GetAllProductsAsync();
                Interlocked.Increment(ref succeeded);
            }
            catch (CosmosException ex) when (ex.StatusCode == HttpStatusCode.TooManyRequests)
            {
                Interlocked.Increment(ref throttled);
                _logger.LogWarning("Request {Index} throttled: {Message}", i, ex.Message);
            }
            catch (Exception)
            {
                Interlocked.Increment(ref errors);
            }
        });

        await Task.WhenAll(tasks);

        var snapshot = _metrics.GetSnapshot();
        
        return Ok(new
        {
            simulation = "Black Friday Traffic Burst",
            results = new { succeeded, throttled, errors, total = requests },
            throttleRate = $"{(double)throttled / requests * 100:F1}%",
            currentStatus = snapshot.Status,
            message = throttled > 0 
                ? $"Cosmos DB is being throttled! {throttled} requests failed with 429." 
                : "No throttling detected - try increasing request count or running again quickly."
        });
    }

    /// <summary>
    /// Get Cosmos DB metrics (rolling window of last 100 operations)
    /// </summary>
    [HttpGet("metrics")]
    public IActionResult GetMetrics()
    {
        var snapshot = _metrics.GetSnapshot();
        return Ok(new
        {
            cosmosDb = new
            {
                rollingWindow = new
                {
                    sampleCount = snapshot.SampleCount,
                    latency = new
                    {
                        avgMs = snapshot.AvgLatencyMs,
                        p95Ms = snapshot.P95LatencyMs,
                        maxMs = snapshot.MaxLatencyMs,
                        minMs = snapshot.MinLatencyMs
                    },
                    requestUnits = new
                    {
                        avgPerRequest = snapshot.AvgRequestCharge,
                        maxPerRequest = snapshot.MaxRequestCharge,
                        totalInWindow = snapshot.TotalRequestChargeInWindow
                    },
                    errors = new
                    {
                        throttledCount = snapshot.ThrottledCount,
                        throttledPercentage = snapshot.ThrottledPercentage,
                        successCount = snapshot.SuccessCount
                    }
                },
                allTime = new
                {
                    totalRequests = snapshot.TotalRequests,
                    totalThrottled = snapshot.TotalThrottled,
                    totalRuConsumed = snapshot.TotalRuConsumed
                },
                status = snapshot.Status,
                message = snapshot.Message,
                recentOperations = snapshot.RecentOperations
            },
            timestamp = DateTime.UtcNow
        });
    }

    /// <summary>
    /// Seed sample data into Cosmos DB
    /// </summary>
    [HttpPost("seed")]
    public async Task<IActionResult> SeedData([FromQuery] int count = 50)
    {
        try
        {
            var created = await _cosmosDbService.SeedDataAsync(count);
            return Ok(new { message = $"Seeded {created} products", count = created });
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Error seeding data");
            return StatusCode(500, new { error = "Failed to seed data", details = ex.Message });
        }
    }

    /// <summary>
    /// Reset metrics
    /// </summary>
    [HttpPost("metrics/reset")]
    public IActionResult ResetMetrics()
    {
        _metrics.Reset();
        return Ok(new { message = "Metrics reset successfully" });
    }
}
