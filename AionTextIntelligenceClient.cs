using System.Text.Json;
using System.Text.Json.Serialization;
using global::AionInstructPreview.Text;

namespace AionInstructPreview.Chat;

public enum TextOperation
{
    Summarize,
    SummarizeConversation,
    Rewrite,
    RewriteCustom,
    TextToTable,
    GenerateWithLoRA,
    GenerateBase
}

public sealed record TextIntelligenceOutput(
    LanguageModelResponseStatus Status, string Text, IReadOnlyList<TextIntelligenceTableRow> Rows);

public sealed record TextIntelligenceTableRow(IReadOnlyList<string> Columns)
{
    public string AccessibleName => string.Join(", ", Columns);
}

// Only messages authored by our input validation are safe to show verbatim.
public sealed class TextInputValidationException(string message) : ArgumentException(message);

public sealed class AdapterLoadException : Exception
{
    public LanguageModelLowRankAdapterStatus Status { get; }
    public string SdkLoadMessage { get; }

    public AdapterLoadException(LanguageModelLowRankAdapterStatus status, Exception? error, string sdkLoadMessage)
        : base("The adapter could not be loaded.", error)
    {
        Status = status;
        SdkLoadMessage = sdkLoadMessage;
        HResult = error?.HResult ?? unchecked((int)0x8000FFFF);
    }
}

public sealed class AionTextIntelligenceClient(LanguageModel model) : IDisposable
{
    private LanguageModelLowRankAdapter? _adapter;
    private bool _disposed;

    public string? AdapterPath { get; private set; }
    public LanguageModelLowRankAdapterStatus? AdapterLoadStatus => _adapter?.LoadStatus;
    public string AdapterLoadMessage => _adapter?.LoadMessage ?? string.Empty;

    public static void ValidateInput(TextOperation operation, string text, string instruction)
    {
        if (string.IsNullOrWhiteSpace(text)) { throw new TextInputValidationException("Enter text before running."); }
        if (operation == TextOperation.SummarizeConversation) { ParseConversation(text); }
        if (operation == TextOperation.RewriteCustom && string.IsNullOrWhiteSpace(instruction))
        {
            throw new TextInputValidationException("Describe how you want the text rewritten.");
        }
    }

    public static string ErrorDetail(Exception error) => error switch
    {
        TextInputValidationException => error.Message,
        JsonException => "Enter a valid JSON array. Each item needs a participant and message. Try the example.",
        _ => $"The operation failed (0x{error.HResult:X8}). This is not a moderation decision."
    };

    public static string AdapterErrorDetail(Exception error)
    {
        if (error is not AdapterLoadException load) { return ErrorDetail(error); }
        var reason = load.Status switch
        {
            LanguageModelLowRankAdapterStatus.Incompatible =>
                "AdapterIncompatibleRetrainRequired: retrain or export an adapter compatible with this Aion Instruct base model",
            LanguageModelLowRankAdapterStatus.InvalidAdapter =>
                "The adapter contents, format, metadata or tensor layout are invalid",
            _ => "The adapter could not be loaded"
        };
        return $"{reason} ({load.Status}, HRESULT=0x{error.HResult:X8}). {load.SdkLoadMessage}".TrimEnd();
    }

    public async Task LoadAdapterAsync(string path)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        // Keep the old adapter if loading the replacement fails.
        var result = await LanguageModelLowRankAdapter.CreateFromPathAsync(model, path);
        if (result.ExtendedError is { } error) { throw new AdapterLoadException(result.Status, error, result.LoadMessage); }
        var loaded = result.LowRankAdapter
            ?? throw new AdapterLoadException(result.Status, null, result.LoadMessage);
        if (_disposed)
        {
            ((IDisposable)loaded).Dispose();
            throw new ObjectDisposedException(nameof(AionTextIntelligenceClient));
        }
        var old = _adapter;
        _adapter = loaded;
        AdapterPath = path;
        (old as IDisposable)?.Dispose();
    }

    public void UnloadAdapter()
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        (_adapter as IDisposable)?.Dispose();
        _adapter = null;
        AdapterPath = null;
    }

    public async Task<TextIntelligenceOutput> RunAsync(
        TextOperation operation, string text, TextRewriteTone tone, string instruction,
        ConversationSummaryOptions conversationOptions, CancellationToken cancellationToken)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        ValidateInput(operation, text, instruction);
        if (operation == TextOperation.TextToTable)
        {
            var converter = new TextToTableConverter(model);
            var result = await converter.ConvertAsync(text).AsTask(cancellationToken);
            if (result.ExtendedError is { } error)
            {
                throw error;
            }
            var rows = result.Status == LanguageModelResponseStatus.Complete
                ? result.GetRows().Select(row => new TextIntelligenceTableRow(row.GetColumns())).ToArray()
                : [];
            return new(result.Status, string.Empty, rows);
        }

        Windows.Foundation.IAsyncOperationWithProgress<LanguageModelResponseResult, string> pending;
        switch (operation)
        {
            case TextOperation.Summarize:
                pending = new TextSummarizer(model).SummarizeParagraphAsync(text);
                break;
            case TextOperation.SummarizeConversation:
                var input = ParseConversation(text);
                var messages = input.Select(item => new ConversationItem
                {
                    Participant = item.Participant, Message = item.Message
                }).ToArray();
                pending = new TextSummarizer(model).SummarizeConversationAsync(messages, conversationOptions);
                break;
            case TextOperation.Rewrite:
                pending = new TextRewriter(model).RewriteAsync(text, tone);
                break;
            case TextOperation.RewriteCustom:
                pending = new TextRewriter(model).RewriteCustomAsync(text, instruction);
                break;
            case TextOperation.GenerateWithLoRA:
                if (_adapter is null) { throw new InvalidOperationException("Load an Aion Instruct-compatible LoRA first."); }
                pending = model.GenerateResponseAsync(text, new LanguageModelOptions { LowRankAdapter = _adapter });
                break;
            case TextOperation.GenerateBase:
                pending = model.GenerateResponseAsync(text, new LanguageModelOptions());
                break;
            default:
                throw new ArgumentOutOfRangeException(nameof(operation));
        }
        var response = await pending.AsTask(cancellationToken);
        return new(response.Status, response.Status == LanguageModelResponseStatus.Complete ? response.Text : string.Empty, []);
    }

    public void Dispose()
    {
        if (_disposed) { return; }
        _disposed = true;
        (_adapter as IDisposable)?.Dispose();
        _adapter = null;
    }

    private sealed record ConversationMessage(
        [property: JsonPropertyName("participant")] string Participant,
        [property: JsonPropertyName("message")] string Message);

    private static ConversationMessage[] ParseConversation(string text)
    {
        var input = JsonSerializer.Deserialize<ConversationMessage[]>(text)
            ?? throw new TextInputValidationException("Enter a JSON array of participant/message objects.");
        if (input.Any(item => item is null || item.Participant is null || item.Message is null))
        {
            throw new TextInputValidationException("Each conversation item needs participant and message strings. Empty strings are skipped.");
        }
        if (input.Any(item => item.Participant.IndexOfAny(['\r', '\n']) >= 0 ||
            item.Participant.Contains("MessageId:", StringComparison.Ordinal) ||
            item.Message.Contains("MessageId:", StringComparison.Ordinal) ||
            item.Participant.Contains('\0') || item.Message.Contains('\0')))
        {
            throw new TextInputValidationException("Participants must be single-line. Neither field may contain null characters or the reserved MessageId: marker.");
        }
        return input;
    }
}
