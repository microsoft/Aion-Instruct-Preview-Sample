using System;
using System.IO;
using System.Text;
using System.Threading.Tasks;
using AionInstructPreview.Text;
using AionInstructPreview.Chat.ConsoleApp;
using AionInstructPreview.Chat;

// Unpackaged console harness for the Aion Instruct Preview SDK.
//
// Streams one prompt response to stdout so the sample can be run or captured
// from a terminal.

string prompt = args.Length > 0
    ? string.Join(' ', args)
    : "In one short sentence, what is Aion Instruct Preview?";

// Take the runtime dependency on the installed framework package (no MSIX
// identity for an unpackaged app), same as the WPF sample.
try
{
    FrameworkDependency.EnsureLoaded();
}
catch (Exception ex)
{
    Console.Error.WriteLine($"[Aion Instruct Preview-console] Framework initialization failed: {ex.Message}");
    return 1;
}

Console.OutputEncoding = new UTF8Encoding(false);

static void RefreshConsoleWriters()
{
    Console.SetOut(new StreamWriter(Console.OpenStandardOutput(), new UTF8Encoding(false)) { AutoFlush = true });
    Console.SetError(new StreamWriter(Console.OpenStandardError(), new UTF8Encoding(false)) { AutoFlush = true });
}

static async Task<LanguageModel> LoadModelAsync()
{
    Console.Error.WriteLine("[Aion Instruct Preview-console] Loading model (first run may take several minutes)...");
    try
    {
        return await LanguageModel.CreateAsync();
    }
    finally
    {
        // Native initialization can replace the standard handles; refresh before reporting any result.
        RefreshConsoleWriters();
    }
}

// --text-intelligence <operation> <text-file> [adapter.safetensors] [tone/custom instruction]
// Skill output is printed only after final moderation; unlike chat it is not streamed.
if (args.Length > 0 && args[0] == "--text-intelligence")
{
    try
    {
        if (args.Length is < 3 or > 5 ||
            !Enum.TryParse<AionInstructPreview.Chat.TextOperation>(args[1], out var operation) ||
            !Enum.IsDefined(operation))
        {
            throw new TextInputValidationException("Usage: --text-intelligence <operation> <text-file> [adapter-path or -] [tone/custom instruction]");
        }
        var hasAdapterPath = args.Length >= 4 && args[3] != "-";
        if (hasAdapterPath && operation != AionInstructPreview.Chat.TextOperation.GenerateWithLoRA)
        {
            throw new TextInputValidationException("Adapter paths are only used with GenerateWithLoRA. Text intelligence uses its built-in task adapters.");
        }
        if (operation == AionInstructPreview.Chat.TextOperation.GenerateWithLoRA && !hasAdapterPath)
        {
            throw new TextInputValidationException("GenerateWithLoRA requires an adapter path.");
        }
        var tone = TextRewriteTone.Default;
        var instruction = args.Length == 5 ? args[4] : string.Empty;
        if (operation == TextOperation.Rewrite && args.Length == 5 &&
            (!Enum.TryParse(instruction, out tone) || !Enum.IsDefined(tone)))
        {
            throw new TextInputValidationException("Unknown rewrite tone.");
        }
        var text = await File.ReadAllTextAsync(args[2]);
        AionTextIntelligenceClient.ValidateInput(operation, text, instruction);
        using var skillModel = await LoadModelAsync();
        using var client = new AionInstructPreview.Chat.AionTextIntelligenceClient(skillModel);
        if (hasAdapterPath)
        {
            try { await client.LoadAdapterAsync(Path.GetFullPath(args[3])); }
            catch (Exception error)
            {
                Console.Error.WriteLine(AionTextIntelligenceClient.AdapterErrorDetail(error));
                return 1;
            }
            if (client.AdapterLoadStatus != LanguageModelLowRankAdapterLoadStatus.Loaded)
            {
                Console.Error.WriteLine($"Adapter loaded with warning: {client.AdapterLoadMessage}");
            }
        }
        var result = await client.RunAsync(operation, text, tone, instruction,
            new ConversationSummaryOptions(), CancellationToken.None);
        Console.Error.WriteLine($"Text intelligence status: {result.Status}");
        if (result.Status != LanguageModelResponseStatus.Complete) { return 1; }
        Console.WriteLine(result.Text);
        foreach (var row in result.Rows) { Console.WriteLine(string.Join(" | ", row.Columns)); }
        return 0;
    }
    catch (Exception error)
    {
        // The using scopes above dispose the native model before this diagnostic.
        RefreshConsoleWriters();
        Console.Error.WriteLine(AionTextIntelligenceClient.ErrorDetail(error));
        return 1;
    }
}

LanguageModel model;
try
{
    model = await LoadModelAsync();
}
catch (Exception ex)
{
    Console.Error.WriteLine($"[Aion Instruct Preview-console] Model loading failed (0x{ex.HResult:X8}).");
    return 1;
}
Console.WriteLine("[Aion Instruct Preview-console] Model ready.");
object outputLock = new();
bool acceptingUpdates = true;
try
{
    using var context = model.CreateContext();
    Console.WriteLine($"You: {prompt}");
    Console.Error.WriteLine("Streamed updates passed their current moderation checks, but a later check can block the result. Already printed text cannot be retracted.");
    Console.Write("Aion Instruct Preview: ");

    // Preserve the sample's sampling settings from before options were exposed.
    var options = new LanguageModelOptions { Temperature = 0.5f, TopP = 0.9f, TopK = 40 };
    var op = model.GenerateResponseAsync(context, prompt, options);
    op.Progress = (_, delta) =>
    {
        lock (outputLock)
        {
            if (acceptingUpdates) Console.Write(delta);
        }
    };

    var result = await op;
    lock (outputLock)
    {
        acceptingUpdates = false;
        Console.WriteLine();
    }
    if (result.Status == LanguageModelResponseStatus.Complete)
    {
        Console.Error.WriteLine("[Aion Instruct Preview-console] Complete.");
        return 0;
    }

    Console.Error.WriteLine(result.Status switch
    {
        LanguageModelResponseStatus.PromptBlockedByContentModeration =>
            "The prompt was blocked by content moderation.",
        LanguageModelResponseStatus.ResponseBlockedByContentModeration =>
            "The response was blocked by content moderation.",
        LanguageModelResponseStatus.BlockedByPolicy =>
            "This request was blocked by the preview's content policy.",
        LanguageModelResponseStatus.PromptLargerThanContext =>
            "The prompt exceeded the context limit.",
        _ => "Generation failed. This is an operational failure, not a moderation decision.",
    });
    Console.Error.WriteLine("No final response is available. Disregard any earlier streamed text; it cannot be retracted from the terminal or redirected output.");
    return 1;
}
catch (Exception ex)
{
    lock (outputLock)
    {
        acceptingUpdates = false;
        Console.WriteLine();
    }
    Console.Error.WriteLine(ex.HResult == unchecked((int)0x8A1F0202)
        ? "Content moderation blocked this request."
        : $"Generation failed (0x{ex.HResult:X8}). This is not a moderation decision.");
    Console.Error.WriteLine("No final response is available. Disregard any earlier streamed text; it cannot be retracted.");
    return 1;
}
finally
{
    model.Dispose();
}
