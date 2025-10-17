namespace SREPerfDemo;

public class PerformanceSettings
{
    public bool EnableSlowEndpoints { get; set; } = false;
    public bool EnableCpuIntensiveEndpoints { get; set; } = false;
    public int ResponseTimeThresholdMs { get; set; } = 1000;
    public int CpuThresholdPercentage { get; set; } = 80;
    public int MemoryThresholdMB { get; set; } = 100;
}
