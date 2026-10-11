using System;
using System.Diagnostics;
using System.Threading.Tasks;
using global::AionInstructPreview.Text;
using AionInstructPreview.Chat.Models;

namespace AionInstructPreview.Chat;

// Bundles the underlying Aion Instruct Preview result with timing metrics collected during
// the streaming call. First-update latency and updates/s are computed off the Progress callback
// stream; see GenerationMetrics for the conventions.
public sealed record AionGenerationResult(
    LanguageModelResponseResult Response,
    GenerationMetrics Metrics);

// Thin async wrapper around the AionInstructPreview.Text.LanguageModel runtimeclass.
// Hides the WinRT projection and Progress-callback mechanics from the
// viewmodel. Callers should marshal onUpdate back to the UI thread when needed.
//
// A AionInstructClient owns one LanguageModelContext that carries the in-process
// conversation history. Every GenerateAsync routes through that context, so
// Aion Instruct Preview recalls previous turns. The viewmodel discards a AionInstructClient and
// creates a new one (or calls StartNewConversation) when it wants a fresh
// chat — for example after PromptLargerThanContext fires.
public sealed class AionInstructClient : IDisposable
{
    private readonly LanguageModel _model;
    private LanguageModelContext _context;
    private bool _disposed;

    private AionInstructClient(LanguageModel model, LanguageModelContext context)
    {
        _model = model;
        _context = context;
    }

    // Loads the underlying Aion Instruct Preview model. On first launch per process this
    // can take 4-5 minutes while QNN compiles the QDQ ONNX models to the
    // Snapdragon NPU. Callers must keep their loading UI up until this
    // completes.
    public static async Task<AionInstructClient> CreateAsync()
    {
        var model = await LanguageModel.CreateAsync();
        var context = model.CreateContext();
        return new AionInstructClient(model, context);
    }

    // Discard the current conversation context and open a fresh one. Use
    // this after a PromptLargerThanContext result, or whenever the user
    // hits "New conversation" in the UI. Cheap — synchronous + ~ms.
    //
    // When systemPrompt is null or empty the model runs under the stack's stock
    // assistant prompt; otherwise it uses the CreateContext(String) overload, which
    // mirrors Microsoft.Windows.AI.Text.LanguageModel exactly.
    public void StartNewConversation(string? systemPrompt = null)
    {
        ThrowIfDisposed();
        var old = _context;
        _context = string.IsNullOrWhiteSpace(systemPrompt)
            ? _model.CreateContext()
            : _model.CreateContext(systemPrompt);
        ((IDisposable)old).Dispose();
    }

    // Runs one prompt against the session context. Each new text delta
    // from Aion Instruct Preview invokes onUpdate; the returned task completes with the
    // final accumulated result. The caller is responsible for cross-thread
    // marshalling — onUpdate fires on whatever thread WinRT picks for the
    // Progress callback.
    //
    // The SDK manages multi-turn history. Reuse the context after a blocked turn;
    // do not assume a failed operation left its history unchanged.
    public async Task<AionGenerationResult> GenerateAsync(
        string prompt,
        Action<string> onUpdate)
    {
        ArgumentNullException.ThrowIfNull(prompt);
        ArgumentNullException.ThrowIfNull(onUpdate);
        ThrowIfDisposed();

        var stopwatch = Stopwatch.StartNew();
        long firstUpdateTicks = 0;
        int updateCount = 0;

        // Preserve the sample's sampling settings from before options were exposed.
        var options = new LanguageModelOptions { Temperature = 0.5f, TopP = 0.9f, TopK = 40 };
        var op = _model.GenerateResponseAsync(_context, prompt, options);
        op.Progress = (_, delta) =>
        {
            if (updateCount == 0)
            {
                firstUpdateTicks = stopwatch.ElapsedTicks;
            }
            updateCount++;
            onUpdate(delta);
        };

        var response = await op;
        stopwatch.Stop();

        double totalMs = stopwatch.Elapsed.TotalMilliseconds;
        double? firstUpdateMs = updateCount == 0
            ? null
            : firstUpdateTicks * 1000.0 / Stopwatch.Frequency;
        double? afterFirstUpdateMs = totalMs - firstUpdateMs;
        double? updatesPerSecond = (updateCount > 1 && afterFirstUpdateMs > 0)
            ? (updateCount - 1) * 1000.0 / afterFirstUpdateMs
            : (double?)null;

        var metrics = new GenerationMetrics(firstUpdateMs, afterFirstUpdateMs, totalMs, updateCount, updatesPerSecond);
        return new AionGenerationResult(response, metrics);
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        // IClosable.Close() projects to IDisposable.Dispose() in C#.
        ((IDisposable)_context).Dispose();
        ((IDisposable)_model).Dispose();
    }

    private void ThrowIfDisposed()
    {
        if (_disposed)
        {
            throw new ObjectDisposedException(nameof(AionInstructClient));
        }
    }
}
