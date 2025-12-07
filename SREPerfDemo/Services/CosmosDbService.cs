using System.Diagnostics;
using System.Net;
using Microsoft.Azure.Cosmos;

namespace SREPerfDemo.Services;

/// <summary>
/// Service for interacting with Cosmos DB with full instrumentation.
/// All operations are tracked for latency, RU consumption, and throttling.
/// </summary>
public class CosmosDbService
{
    private readonly Container _container;
    private readonly CosmosDbMetrics _metrics;
    private readonly ILogger<CosmosDbService> _logger;

    public CosmosDbService(CosmosClient cosmosClient, CosmosDbMetrics metrics, ILogger<CosmosDbService> logger, IConfiguration configuration)
    {
        _metrics = metrics;
        _logger = logger;

        var databaseName = configuration["CosmosDb:DatabaseName"] ?? "ProductsDb";
        var containerName = configuration["CosmosDb:ContainerName"] ?? "Products";

        _container = cosmosClient.GetContainer(databaseName, containerName);
    }

    public async Task<List<CosmosProduct>> GetAllProductsAsync()
    {
        var stopwatch = Stopwatch.StartNew();
        var products = new List<CosmosProduct>();
        double totalRu = 0;
        int statusCode = 200;
        bool isThrottled = false;
        string? errorMessage = null;

        try
        {
            // Cross-partition query - uses more RUs, good for demo
            var query = new QueryDefinition("SELECT * FROM c");
            var iterator = _container.GetItemQueryIterator<CosmosProduct>(query);

            while (iterator.HasMoreResults)
            {
                var response = await iterator.ReadNextAsync();
                products.AddRange(response);
                totalRu += response.RequestCharge;
            }
        }
        catch (CosmosException ex) when (ex.StatusCode == HttpStatusCode.TooManyRequests)
        {
            stopwatch.Stop();
            isThrottled = true;
            statusCode = 429;
            errorMessage = "Throttled by Cosmos DB";
            
            _logger.LogWarning("Cosmos DB throttled: {Message}. Retry after: {RetryAfter}ms", 
                ex.Message, ex.RetryAfter?.TotalMilliseconds);
            
            RecordOperation("GetAll", stopwatch.ElapsedMilliseconds, ex.RequestCharge, isThrottled, statusCode, errorMessage);
            throw;
        }
        catch (CosmosException ex)
        {
            stopwatch.Stop();
            statusCode = (int)ex.StatusCode;
            errorMessage = ex.Message;
            
            _logger.LogError(ex, "Cosmos DB error: {StatusCode} - {Message}", ex.StatusCode, ex.Message);
            
            RecordOperation("GetAll", stopwatch.ElapsedMilliseconds, ex.RequestCharge, false, statusCode, errorMessage);
            throw;
        }

        stopwatch.Stop();
        RecordOperation("GetAll", stopwatch.ElapsedMilliseconds, totalRu, isThrottled, statusCode, errorMessage);

        _logger.LogInformation("GetAllProducts completed in {Latency}ms, consumed {RU} RUs, returned {Count} products",
            stopwatch.ElapsedMilliseconds, totalRu, products.Count);

        return products;
    }

    public async Task<CosmosProduct?> GetProductByIdAsync(string id, string category)
    {
        var stopwatch = Stopwatch.StartNew();
        double requestCharge = 0;
        int statusCode = 200;
        bool isThrottled = false;
        string? errorMessage = null;

        try
        {
            var response = await _container.ReadItemAsync<CosmosProduct>(id, new PartitionKey(category));
            requestCharge = response.RequestCharge;
            stopwatch.Stop();
            
            RecordOperation("PointRead", stopwatch.ElapsedMilliseconds, requestCharge, false, statusCode, null);
            
            _logger.LogInformation("GetProductById({Id}) completed in {Latency}ms, consumed {RU} RUs",
                id, stopwatch.ElapsedMilliseconds, requestCharge);

            return response.Resource;
        }
        catch (CosmosException ex) when (ex.StatusCode == HttpStatusCode.NotFound)
        {
            stopwatch.Stop();
            RecordOperation("PointRead", stopwatch.ElapsedMilliseconds, ex.RequestCharge, false, 404, "Not found");
            return null;
        }
        catch (CosmosException ex) when (ex.StatusCode == HttpStatusCode.TooManyRequests)
        {
            stopwatch.Stop();
            isThrottled = true;
            statusCode = 429;
            errorMessage = "Throttled by Cosmos DB";
            
            _logger.LogWarning("Cosmos DB throttled on PointRead: {Message}", ex.Message);
            
            RecordOperation("PointRead", stopwatch.ElapsedMilliseconds, ex.RequestCharge, isThrottled, statusCode, errorMessage);
            throw;
        }
        catch (CosmosException ex)
        {
            stopwatch.Stop();
            statusCode = (int)ex.StatusCode;
            errorMessage = ex.Message;
            
            RecordOperation("PointRead", stopwatch.ElapsedMilliseconds, ex.RequestCharge, false, statusCode, errorMessage);
            throw;
        }
    }

    public async Task<List<CosmosProduct>> SearchProductsAsync(string searchTerm)
    {
        var stopwatch = Stopwatch.StartNew();
        var products = new List<CosmosProduct>();
        double totalRu = 0;
        int statusCode = 200;
        bool isThrottled = false;
        string? errorMessage = null;

        try
        {
            // Cross-partition query with filter - uses moderate RUs
            var query = new QueryDefinition("SELECT * FROM c WHERE CONTAINS(LOWER(c.name), @search) OR CONTAINS(LOWER(c.description), @search)")
                .WithParameter("@search", searchTerm.ToLower());
            
            var iterator = _container.GetItemQueryIterator<CosmosProduct>(query);

            while (iterator.HasMoreResults)
            {
                var response = await iterator.ReadNextAsync();
                products.AddRange(response);
                totalRu += response.RequestCharge;
            }
        }
        catch (CosmosException ex) when (ex.StatusCode == HttpStatusCode.TooManyRequests)
        {
            stopwatch.Stop();
            isThrottled = true;
            statusCode = 429;
            errorMessage = "Throttled by Cosmos DB";
            
            _logger.LogWarning("Cosmos DB throttled on Search: {Message}", ex.Message);
            
            RecordOperation("Search", stopwatch.ElapsedMilliseconds, ex.RequestCharge, isThrottled, statusCode, errorMessage);
            throw;
        }
        catch (CosmosException ex)
        {
            stopwatch.Stop();
            statusCode = (int)ex.StatusCode;
            errorMessage = ex.Message;
            
            RecordOperation("Search", stopwatch.ElapsedMilliseconds, ex.RequestCharge, false, statusCode, errorMessage);
            throw;
        }

        stopwatch.Stop();
        RecordOperation("Search", stopwatch.ElapsedMilliseconds, totalRu, isThrottled, statusCode, errorMessage);

        _logger.LogInformation("SearchProducts('{Term}') completed in {Latency}ms, consumed {RU} RUs, returned {Count} products",
            searchTerm, stopwatch.ElapsedMilliseconds, totalRu, products.Count);

        return products;
    }

    public async Task<CosmosProduct> CreateProductAsync(CosmosProduct product)
    {
        var stopwatch = Stopwatch.StartNew();
        double requestCharge = 0;
        int statusCode = 201;
        bool isThrottled = false;
        string? errorMessage = null;

        try
        {
            if (string.IsNullOrEmpty(product.Id))
            {
                product.Id = Guid.NewGuid().ToString();
            }

            var response = await _container.CreateItemAsync(product, new PartitionKey(product.Category));
            requestCharge = response.RequestCharge;
            stopwatch.Stop();
            
            RecordOperation("Create", stopwatch.ElapsedMilliseconds, requestCharge, false, statusCode, null);
            
            _logger.LogInformation("CreateProduct completed in {Latency}ms, consumed {RU} RUs",
                stopwatch.ElapsedMilliseconds, requestCharge);

            return response.Resource;
        }
        catch (CosmosException ex) when (ex.StatusCode == HttpStatusCode.TooManyRequests)
        {
            stopwatch.Stop();
            isThrottled = true;
            statusCode = 429;
            errorMessage = "Throttled by Cosmos DB";
            
            _logger.LogWarning("Cosmos DB throttled on Create: {Message}", ex.Message);
            
            RecordOperation("Create", stopwatch.ElapsedMilliseconds, ex.RequestCharge, isThrottled, statusCode, errorMessage);
            throw;
        }
        catch (CosmosException ex)
        {
            stopwatch.Stop();
            statusCode = (int)ex.StatusCode;
            errorMessage = ex.Message;
            
            RecordOperation("Create", stopwatch.ElapsedMilliseconds, ex.RequestCharge, false, statusCode, errorMessage);
            throw;
        }
    }

    /// <summary>
    /// Expensive query that uses many RUs - for demo purposes to trigger throttling
    /// </summary>
    public async Task<object> RunExpensiveQueryAsync()
    {
        var stopwatch = Stopwatch.StartNew();
        double totalRu = 0;
        int statusCode = 200;
        bool isThrottled = false;
        string? errorMessage = null;
        int itemCount = 0;

        try
        {
            // Expensive aggregation query - high RU consumption
            var query = new QueryDefinition(@"
                SELECT 
                    c.category,
                    COUNT(1) as productCount,
                    AVG(c.price) as avgPrice,
                    MIN(c.price) as minPrice,
                    MAX(c.price) as maxPrice
                FROM c
                GROUP BY c.category");
            
            var results = new List<dynamic>();
            var iterator = _container.GetItemQueryIterator<dynamic>(query);

            while (iterator.HasMoreResults)
            {
                var response = await iterator.ReadNextAsync();
                results.AddRange(response);
                totalRu += response.RequestCharge;
                itemCount += response.Count;
            }

            stopwatch.Stop();
            RecordOperation("ExpensiveQuery", stopwatch.ElapsedMilliseconds, totalRu, false, statusCode, null);

            _logger.LogInformation("ExpensiveQuery completed in {Latency}ms, consumed {RU} RUs",
                stopwatch.ElapsedMilliseconds, totalRu);

            return new { results, ruConsumed = totalRu, latencyMs = stopwatch.ElapsedMilliseconds };
        }
        catch (CosmosException ex) when (ex.StatusCode == HttpStatusCode.TooManyRequests)
        {
            stopwatch.Stop();
            isThrottled = true;
            statusCode = 429;
            errorMessage = "Throttled by Cosmos DB";
            
            _logger.LogWarning("Cosmos DB throttled on ExpensiveQuery: {Message}", ex.Message);
            
            RecordOperation("ExpensiveQuery", stopwatch.ElapsedMilliseconds, ex.RequestCharge, isThrottled, statusCode, errorMessage);
            throw;
        }
        catch (CosmosException ex)
        {
            stopwatch.Stop();
            statusCode = (int)ex.StatusCode;
            errorMessage = ex.Message;
            
            RecordOperation("ExpensiveQuery", stopwatch.ElapsedMilliseconds, ex.RequestCharge, false, statusCode, errorMessage);
            throw;
        }
    }

    /// <summary>
    /// Seeds the database with sample products for the demo
    /// </summary>
    public async Task<int> SeedDataAsync(int count = 50)
    {
        var categories = new[] { "Electronics", "Clothing", "Books", "Home", "Sports", "Toys" };
        var random = new Random();
        var created = 0;

        for (int i = 0; i < count; i++)
        {
            var category = categories[random.Next(categories.Length)];
            var product = new CosmosProduct
            {
                Id = Guid.NewGuid().ToString(),
                Name = $"Product {i + 1}",
                Description = $"This is a sample product in the {category} category. It has many great features.",
                Price = Math.Round(random.NextDouble() * 500 + 10, 2),
                Category = category,
                InStock = random.Next(100),
                CreatedAt = DateTime.UtcNow.AddDays(-random.Next(365))
            };

            try
            {
                await _container.CreateItemAsync(product, new PartitionKey(product.Category));
                created++;
            }
            catch (CosmosException ex) when (ex.StatusCode == HttpStatusCode.Conflict)
            {
                // Item already exists, skip
            }
            catch (CosmosException ex) when (ex.StatusCode == HttpStatusCode.TooManyRequests)
            {
                // Throttled, wait and continue
                _logger.LogWarning("Throttled during seeding, waiting...");
                await Task.Delay(1000);
                i--; // Retry this item
            }
        }

        _logger.LogInformation("Seeded {Count} products to Cosmos DB", created);
        return created;
    }

    private void RecordOperation(string operationType, double latencyMs, double requestCharge, bool isThrottled, int statusCode, string? errorMessage)
    {
        _metrics.RecordOperation(new CosmosDbOperationRecord
        {
            Timestamp = DateTime.UtcNow,
            OperationType = operationType,
            LatencyMs = latencyMs,
            RequestCharge = requestCharge,
            IsThrottled = isThrottled,
            StatusCode = statusCode,
            ErrorMessage = errorMessage
        });
    }
}

public class CosmosProduct
{
    [Newtonsoft.Json.JsonProperty("id")]
    public string Id { get; set; } = string.Empty;
    
    [Newtonsoft.Json.JsonProperty("name")]
    public string Name { get; set; } = string.Empty;
    
    [Newtonsoft.Json.JsonProperty("description")]
    public string Description { get; set; } = string.Empty;
    
    [Newtonsoft.Json.JsonProperty("price")]
    public double Price { get; set; }
    
    [Newtonsoft.Json.JsonProperty("category")]
    public string Category { get; set; } = string.Empty;
    
    [Newtonsoft.Json.JsonProperty("inStock")]
    public int InStock { get; set; }
    
    [Newtonsoft.Json.JsonProperty("createdAt")]
    public DateTime CreatedAt { get; set; } = DateTime.UtcNow;
}
