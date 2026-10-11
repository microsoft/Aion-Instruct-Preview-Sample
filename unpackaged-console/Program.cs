using System;
using System.IO;
using System.Text;
using System.Threading.Tasks;
using AionInstructPreview.Text;
using AionInstructPreview.Chat.ConsoleApp;

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

// Write model-load status to stderr so stdout remains dedicated to the streamed reply.
Console.Error.WriteLine("[Aion Instruct Preview-console] Loading model (first run may take several minutes)...");

LanguageModel model;
try
{
    model = await LanguageModel.CreateAsync();
}
catch (Exception ex)
{
    Console.Error.WriteLine($"[Aion Instruct Preview-console] Model loading failed (0x{ex.HResult:X8}).");
    return 1;
}
finally
{
    // Native initialization can replace the standard handles; refresh the cached writers.
    Console.SetOut(new StreamWriter(Console.OpenStandardOutput(), new UTF8Encoding(false)) { AutoFlush = true });
    Console.SetError(new StreamWriter(Console.OpenStandardError(), new UTF8Encoding(false)) { AutoFlush = true });
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
