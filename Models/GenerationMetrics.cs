namespace AionInstructPreview.Chat.Models;

// App-observed timing: update counts are callbacks, not tokens.
// AfterFirstUpdateMs includes completion overhead. Progress timings are null if no update arrived.
public sealed record GenerationMetrics(
    double? FirstUpdateMs,
    double? AfterFirstUpdateMs,
    double TotalMs,
    int UpdateCount,
    double? UpdatesPerSecond)
{
    // Compact one-line label for the bubble caption.
    public string DisplayText
    {
        get
        {
            var rate = UpdatesPerSecond.HasValue
                ? $"{UpdatesPerSecond.Value:0.0} updates/s"
                : "—";
            var latency = FirstUpdateMs.HasValue
                ? $"{FirstUpdateMs.Value:0} ms to first update"
                : "No progress updates";
            return $"{latency} · {rate} · {UpdateCount} updates";
        }
    }
}
