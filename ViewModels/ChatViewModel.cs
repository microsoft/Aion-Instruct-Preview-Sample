using System;
using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Runtime.CompilerServices;
using System.Text.Json;
using System.Threading.Tasks;
using System.Windows.Input;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using AionInstructPreview.Chat.Models;
using global::AionInstructPreview.Text;
using global::AionInstructPreview.Imaging;
using Windows.Storage;

namespace AionInstructPreview.Chat.ViewModels;

// Owns: the conversation transcript (ObservableCollection<Message>),
// the Aion Instruct Preview model client (loaded asynchronously in the ctor), the model
// state machine, and the Send + NewConversation commands.
//
// Threading: captures the UI-thread DispatcherQueue at construction time;
// every UI-bound state change funnels through TryEnqueue. The Aion Instruct Preview
// Progress callbacks fire on a background thread and are marshalled back to the UI thread.
public sealed class ChatViewModel : INotifyPropertyChanged, IDisposable
{
    private readonly DispatcherQueue _dispatcher;
    private AionInstructClient? _aionClient;
    private AionImageDescriptionClient? _descriptionClient;
    private AionTextIntelligenceClient? _textIntelligenceClient;
    private CancellationTokenSource? _textCancellation;
    private bool _runningComparison;
    private string _textIntelligenceOutput = string.Empty;
    private string _textIntelligenceStatus = "Results appear here.";
    private string _baseStatus = "Base model results appear here.";
    private string _adaptedStatus = "Load a LoRA to compare its output.";

    public TextRewriteTone[] RewriteTones { get; } = Enum.GetValues<TextRewriteTone>();
    public ObservableCollection<TextIntelligenceTableRow> TableRows { get; } = [];
    public IReadOnlyList<string> TableHeader { get; private set; } = [];
    public string TextResultProvenance { get; private set; } = string.Empty;
    public string AdapterFeedback { get; private set; } = string.Empty;
    public Visibility AdapterFeedbackVisibility => AdapterFeedback.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
    public Visibility SkillProvenanceVisibility => TextResultProvenance.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
    public Visibility SkillOutputVisibility => TextIntelligenceOutput.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
    public Visibility ComparisonDetailsVisibility => ComparisonPrompt.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
    public string BaseOutput { get; private set; } = string.Empty;
    public string BaseStatus
    {
        get => _baseStatus;
        private set
        {
            if (_baseStatus == value) { return; }
            _baseStatus = value;
            Raise();
        }
    }
    public string AdaptedOutput { get; private set; } = string.Empty;
    public string AdaptedStatus
    {
        get => _adaptedStatus;
        private set
        {
            if (_adaptedStatus == value) { return; }
            _adaptedStatus = value;
            Raise();
        }
    }
    public string ComparisonProvenance { get; private set; } = string.Empty;
    public string ComparisonPrompt { get; private set; } = string.Empty;
    public bool ComparisonOutOfDate { get; private set; }
    public Visibility ComparisonStaleVisibility => ComparisonOutOfDate ? Visibility.Visible : Visibility.Collapsed;
    public Visibility TableVisibility => TableHeader.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
    public string TextIntelligenceOutput
    {
        get => _textIntelligenceOutput;
        private set { _textIntelligenceOutput = value; Raise(); Raise(nameof(SkillOutputVisibility)); }
    }
    public string TextIntelligenceStatus
    {
        get => _textIntelligenceStatus;
        private set
        {
            if (_textIntelligenceStatus == value) { return; }
            _textIntelligenceStatus = value;
            Raise();
        }
    }
    public bool HasCustomAdapter => _textIntelligenceClient?.AdapterPath is not null;
    public string AdapterPath => _textIntelligenceClient?.AdapterPath ?? string.Empty;
    public string AdapterName => HasCustomAdapter ? System.IO.Path.GetFileName(AdapterPath) : "No custom LoRA loaded";
    public string AdapterStatus => $"Adapter: {AdapterName}";
    public bool HasAdapterWarning => _textIntelligenceClient?.AdapterLoadStatus is
        LanguageModelLowRankAdapterStatus.RevalidationRecommended or LanguageModelLowRankAdapterStatus.DeprecatedFormat;
    public string AdapterWarningMessage => _textIntelligenceClient?.AdapterLoadStatus switch
    {
        LanguageModelLowRankAdapterStatus.RevalidationRecommended =>
            "The adapter loaded, but its declared base model version differs. Revalidate its accuracy against this Aion Instruct model and retrain if needed.",
        LanguageModelLowRankAdapterStatus.DeprecatedFormat =>
            "The adapter loaded using a deprecated format. Re-export it using the current supported format.",
        _ => string.Empty
    };
    public string AdapterLoadDetails => _textIntelligenceClient?.AdapterLoadMessage ?? string.Empty;
    public string AdapterScope => "Custom adapters are used only for language-model generation on this tab. Text intelligence uses its built-in task adapters; Chat and image description are unchanged.";
    public string LoadAdapterLabel => HasCustomAdapter ? "Replace LoRA..." : "Load LoRA...";
    public Visibility UnloadAdapterVisibility => HasCustomAdapter ? Visibility.Visible : Visibility.Collapsed;
    public bool CanCancelTextIntelligence => _textCancellation is not null;
    public bool IsComparisonRunning => CanCancelTextIntelligence && _runningComparison;
    public bool IsSkillRunning => CanCancelTextIntelligence && !_runningComparison;
    public bool TextToolsEnabled => _state == ModelState.Ready;
    public Visibility SkillRunningVisibility => CanCancelTextIntelligence && !_runningComparison ? Visibility.Visible : Visibility.Collapsed;
    public Visibility ComparisonRunningVisibility => CanCancelTextIntelligence && _runningComparison ? Visibility.Visible : Visibility.Collapsed;
    public bool IsLoadingAdapter { get; private set; }
    public Visibility AdapterLoadingVisibility => IsLoadingAdapter ? Visibility.Visible : Visibility.Collapsed;

    private ModelState _state = ModelState.Loading;
    private string _promptText = string.Empty;
    private string? _errorMessage;
    private bool _isContextFull;
    private bool _disposed;
    private string _systemPrompt = string.Empty;

    // The system prompt baked into the live LanguageModelContext. A context is immutable
    // once created, so a changed prompt only takes effect on the next CreateContext.
    private string _appliedSystemPrompt = string.Empty;
    private bool _hasConversationTurns;
    private ImageDescriptionKind _selectedImageKind = ImageDescriptionKind.DetailedDescription;

    public ChatViewModel()
    {
        _dispatcher = DispatcherQueue.GetForCurrentThread()
            ?? throw new InvalidOperationException(
                "ChatViewModel must be constructed on a UI thread that has a DispatcherQueue.");

        Messages = new ObservableCollection<Message>();
        ImageMessages = new ObservableCollection<Message>();
        SendCommand = new RelayCommand(_ => _ = SendAsync(), _ => CanSend);
        NewConversationCommand = new RelayCommand(
            _ => StartNewConversation(),
            _ => CanStartNewConversation);

        _ = LoadModelAsync();
    }

    public ObservableCollection<Message> Messages { get; }

    // Image description keeps its own transcript. The two features are independent:
    // describing an image neither reads nor extends the chat conversation context.
    public ObservableCollection<Message> ImageMessages { get; }

    // Applied when a new conversation is started, via CreateContext(String systemPrompt).
    // Empty means "use the stack's default assistant prompt".
    public string SystemPrompt
    {
        get => _systemPrompt;
        set
        {
            if (_systemPrompt == value) return;
            _systemPrompt = value;
            Raise();
            Raise(nameof(SystemPromptPendingVisibility));
        }
    }

    // Shown when the typed system prompt differs from the one the live context was
    // built with AND there is history worth preserving. Before the first turn the
    // prompt is applied silently on the next send, so no nag is needed.
    public Visibility SystemPromptPendingVisibility =>
        (_systemPrompt != _appliedSystemPrompt && _hasConversationTurns)
            ? Visibility.Visible : Visibility.Collapsed;

    public ICommand SendCommand { get; }
    public ICommand NewConversationCommand { get; }

    // The four description styles the SDK supports, in enum order. Bound to the
    // ComboBox next to the attach-image button.
    public ImageDescriptionKind[] ImageKinds { get; } =
    {
        ImageDescriptionKind.BriefDescription,
        ImageDescriptionKind.DetailedDescription,
        ImageDescriptionKind.DiagramDescription,
        ImageDescriptionKind.AccessibleDescription,
    };

    public ImageDescriptionKind SelectedImageKind
    {
        get => _selectedImageKind;
        set
        {
            if (_selectedImageKind == value) return;
            _selectedImageKind = value;
            Raise();
        }
    }

    // The vision models load lazily on first use, so the attach button stays
    // enabled whenever the model is idle. Describing sets State to Generating,
    // which also disables the chat input -- both features share one model.
    public bool DescribeEnabled => _state == ModelState.Ready;

    public string PromptText
    {
        get => _promptText;
        set
        {
            if (_promptText == value) return;
            _promptText = value;
            Raise();
            // SendEnabled depends on PromptText.
            Raise(nameof(SendEnabled));
            (SendCommand as RelayCommand)?.RaiseCanExecuteChanged();
        }
    }

    public ModelState State
    {
        get => _state;
        private set
        {
            if (_state == value) return;
            _state = value;
            Raise();
            Raise(nameof(LoadingVisibility));
            Raise(nameof(ErrorVisibility));
            Raise(nameof(ChatVisibility));
            Raise(nameof(InputEnabled));
            Raise(nameof(SendEnabled));
            Raise(nameof(CanStartNewConversation));
            Raise(nameof(NewConversationButtonEnabled));
            Raise(nameof(DescribeEnabled));
            Raise(nameof(TextToolsEnabled));
            (SendCommand as RelayCommand)?.RaiseCanExecuteChanged();
            (NewConversationCommand as RelayCommand)?.RaiseCanExecuteChanged();
        }
    }

    public string? ErrorMessage
    {
        get => _errorMessage;
        private set
        {
            if (_errorMessage == value) return;
            _errorMessage = value;
            Raise();
        }
    }

    // True when the latest GenerateResponseAsync returned
    // PromptLargerThanContext. Drives the "context full" banner + the
    // primary positioning of the New conversation affordance.
    public bool IsContextFull
    {
        get => _isContextFull;
        private set
        {
            if (_isContextFull == value) return;
            _isContextFull = value;
            Raise();
            Raise(nameof(ContextFullBannerVisibility));
            Raise(nameof(InputEnabled));
            Raise(nameof(SendEnabled));
            (SendCommand as RelayCommand)?.RaiseCanExecuteChanged();
        }
    }

    // UI-facing bindings. Visibility-typed properties avoid the need for a
    // BoolToVisibilityConverter in XAML.
    public Visibility LoadingVisibility =>
        _state == ModelState.Loading ? Visibility.Visible : Visibility.Collapsed;
    public Visibility ErrorVisibility =>
        _state == ModelState.Error ? Visibility.Visible : Visibility.Collapsed;
    public Visibility ChatVisibility =>
        (_state == ModelState.Ready || _state == ModelState.Generating)
            ? Visibility.Visible : Visibility.Collapsed;
    public Visibility ContextFullBannerVisibility =>
        _isContextFull ? Visibility.Visible : Visibility.Collapsed;

    // Input + Send are disabled when the conversation is full — the user
    // must start a new conversation before sending another prompt. The
    // banner explains why.
    public bool InputEnabled => _state == ModelState.Ready && !_isContextFull;
    public bool SendEnabled => InputEnabled && !string.IsNullOrWhiteSpace(_promptText);
    public bool CanSend => SendEnabled;

    // New conversation is available whenever the model is loaded, except during generation.
    public bool CanStartNewConversation =>
        _aionClient is not null && _state != ModelState.Loading && _state != ModelState.Generating;
    public bool NewConversationButtonEnabled => CanStartNewConversation;

    public event PropertyChangedEventHandler? PropertyChanged;

    private async Task LoadModelAsync()
    {
        try
        {
            var client = await AionInstructClient.CreateAsync().ConfigureAwait(true);
            if (_disposed)
            {
                client.Dispose();
                return;
            }
            _aionClient = client;
            _textIntelligenceClient = new AionTextIntelligenceClient(client.Model);
            State = ModelState.Ready;
            Raise(nameof(CanStartNewConversation));
            Raise(nameof(NewConversationButtonEnabled));
            (NewConversationCommand as RelayCommand)?.RaiseCanExecuteChanged();
        }
        catch (Exception ex)
        {
            ErrorMessage =
                $"Aion Instruct Preview couldn't load (0x{ex.HResult:X8}).{Environment.NewLine}" +
                "Make sure the Aion framework and a compatible NPU execution provider are installed -- run Bootstrap.ps1, or scripts\\Diagnose-AionInstructPreview.ps1 to check every prerequisite.";
            State = ModelState.Error;
        }
    }

    public async Task LoadLoRAAsync(string path)
    {
        if (_state != ModelState.Ready || _textIntelligenceClient is null || _disposed) { return; }
        State = ModelState.Generating;
        ClearComparisonResults();
        IsLoadingAdapter = true;
        Raise(nameof(IsLoadingAdapter));
        Raise(nameof(AdapterLoadingVisibility));
        AdapterFeedback = "Loading and validating adapter...";
        Raise(nameof(AdapterFeedback));
        Raise(nameof(AdapterFeedbackVisibility));
        try
        {
            await _textIntelligenceClient.LoadAdapterAsync(path);
            if (!_disposed)
            {
                AdaptedStatus = "LoRA results appear here.";
                AdapterFeedback = HasAdapterWarning ? $"Loaded {AdapterName} with a compatibility warning." :
                    $"Loaded {AdapterName}. Compatibility validated; quality and safety still need evaluation.";
            }
        }
        catch (Exception error)
        {
            if (!_disposed)
            {
                AdapterFeedback = HasCustomAdapter
                    ? $"Replacement failed; still using {AdapterName}. {AionTextIntelligenceClient.AdapterErrorDetail(error)}"
                    : $"Adapter could not be loaded. {AionTextIntelligenceClient.AdapterErrorDetail(error)}";
            }
        }
        finally
        {
            if (!_disposed)
            {
                IsLoadingAdapter = false;
                Raise(nameof(IsLoadingAdapter));
                Raise(nameof(AdapterLoadingVisibility));
                RaiseAdapterState();
                State = ModelState.Ready;
            }
        }
    }

    public void UnloadLoRA()
    {
        if (_state != ModelState.Ready || _textIntelligenceClient is null || _disposed) { return; }
        _textIntelligenceClient.UnloadAdapter();
        ClearComparisonResults();
        AdapterFeedback = "LoRA unloaded. Text intelligence, chat and image description are unchanged.";
        RaiseAdapterState();
    }

    private void RaiseAdapterState()
    {
        foreach (var name in new[] { nameof(HasCustomAdapter), nameof(AdapterName), nameof(AdapterPath),
            nameof(AdapterStatus), nameof(AdapterScope), nameof(LoadAdapterLabel),
            nameof(UnloadAdapterVisibility), nameof(AdapterFeedback), nameof(AdapterFeedbackVisibility),
            nameof(HasAdapterWarning), nameof(AdapterWarningMessage), nameof(AdapterLoadDetails) }) { Raise(name); }
    }

    public void ClearSkillResult()
    {
        TextIntelligenceOutput = string.Empty;
        TextIntelligenceStatus = "Results appear here.";
        TextResultProvenance = string.Empty;
        TableRows.Clear();
        TableHeader = [];
        Raise(nameof(TableHeader));
        Raise(nameof(TableVisibility));
        Raise(nameof(TextResultProvenance));
        Raise(nameof(SkillProvenanceVisibility));
    }

    private void ClearComparisonResults()
    {
        BaseOutput = AdaptedOutput = ComparisonProvenance = ComparisonPrompt = string.Empty;
        BaseStatus = "Base model results appear here.";
        AdaptedStatus = HasCustomAdapter ? "LoRA results appear here." : "Load a LoRA to compare its output.";
        ComparisonOutOfDate = false;
        RaiseComparisonResults();
    }

    public void MarkComparisonOutOfDate()
    {
        if (CanCancelTextIntelligence || ComparisonProvenance.Length == 0 || ComparisonOutOfDate) { return; }
        ComparisonOutOfDate = true;
        Raise(nameof(ComparisonOutOfDate));
        Raise(nameof(ComparisonStaleVisibility));
    }

    private void RaiseComparisonResults()
    {
        foreach (var name in new[] { nameof(BaseOutput), nameof(AdaptedOutput),
            nameof(ComparisonProvenance), nameof(ComparisonPrompt),
            nameof(ComparisonOutOfDate), nameof(ComparisonStaleVisibility), nameof(ComparisonDetailsVisibility) }) { Raise(name); }
    }

    private void RaiseTextRunning()
    {
        Raise(nameof(CanCancelTextIntelligence));
        Raise(nameof(SkillRunningVisibility));
        Raise(nameof(ComparisonRunningVisibility));
        Raise(nameof(IsComparisonRunning));
        Raise(nameof(IsSkillRunning));
    }

    public void CancelTextIntelligence() => _textCancellation?.Cancel();

    public async Task RunTextIntelligenceAsync(TextOperation operation, string text, TextRewriteTone tone,
        string instruction, ConversationSummaryOptions conversationOptions)
    {
        if (_state != ModelState.Ready || _textIntelligenceClient is null || _disposed) { return; }
        State = ModelState.Generating;
        ClearSkillResult();
        TextResultProvenance = $"{TaskLabel(operation)} · {(operation == TextOperation.RewriteCustom ? "Built-in model" : "Built-in task adapter")}";
        Raise(nameof(TextResultProvenance));
        Raise(nameof(SkillProvenanceVisibility));
        TextIntelligenceStatus = "Working - results appear after moderation.";
        using var cancellation = new CancellationTokenSource();
        _runningComparison = false;
        _textCancellation = cancellation;
        RaiseTextRunning();
        try
        {
            var output = await _textIntelligenceClient.RunAsync(operation, text, tone, instruction,
                conversationOptions, cancellation.Token);
            if (_disposed) { return; }
            TextIntelligenceStatus = ResultStatus(output.Status);
            if (output.Status == LanguageModelResponseStatus.Complete)
            {
                TextIntelligenceOutput = output.Text;
                if (output.Rows.Count > 0)
                {
                    TableHeader = output.Rows[0].Columns;
                    foreach (var row in output.Rows.Skip(1)) { TableRows.Add(row); }
                    Raise(nameof(TableHeader));
                    Raise(nameof(TableVisibility));
                }
            }
        }
        catch (OperationCanceledException)
        {
            if (!_disposed) { TextIntelligenceStatus = "Cancelled."; }
        }
        catch (Exception error)
        {
            if (!_disposed) { TextIntelligenceStatus = FriendlyError(error); }
        }
        finally
        {
            _textCancellation = null;
            if (!_disposed) { RaiseTextRunning(); State = ModelState.Ready; }
        }
    }

    public async Task RunComparisonAsync(string prompt, bool runBase, bool runAdapter)
    {
        if (_state != ModelState.Ready || _textIntelligenceClient is null || _disposed) { return; }
        var client = _textIntelligenceClient;
        if (string.IsNullOrWhiteSpace(prompt) || (!runBase && !runAdapter) || (runAdapter && !HasCustomAdapter))
        {
            ClearComparisonResults();
            var detail = string.IsNullOrWhiteSpace(prompt) ? "Enter a prompt before running." :
                !runBase && !runAdapter ? "Select a comparison run." : string.Empty;
            BaseStatus = runBase
                ? detail.Length > 0 ? detail : "Comparison not run. Load a LoRA or choose base only."
                : "Not run.";
            AdaptedStatus = runAdapter
                ? detail.Length > 0 ? detail : "Load a LoRA before running it."
                : !runBase ? detail : "Not run.";
            RaiseComparisonResults();
            return;
        }
        State = ModelState.Generating;
        BaseOutput = AdaptedOutput = string.Empty;
        BaseStatus = runBase ? "Waiting..." : "Not run.";
        AdaptedStatus = runAdapter ? "Waiting..." : "Not run.";
        ComparisonPrompt = prompt;
        ComparisonProvenance = runBase && runAdapter
            ? $"Adapter: {AdapterName} · Same prompt and default sampling · Independent single-turn calls"
            : runBase ? "Base model only · Default sampling · No LoRA used"
            : $"LoRA only: {AdapterName} · Default sampling · Single-turn call";
        ComparisonOutOfDate = false;
        using var cancellation = new CancellationTokenSource();
        _runningComparison = true;
        _textCancellation = cancellation;
        RaiseTextRunning();
        RaiseComparisonResults();
        try
        {
            if (runBase) { await RunPaneAsync(TextOperation.GenerateBase, true); }
            if (runAdapter)
            {
                if (cancellation.IsCancellationRequested) { AdaptedStatus = "Cancelled before starting."; }
                else { await RunPaneAsync(TextOperation.GenerateWithLoRA, false); }
            }
        }
        finally
        {
            _textCancellation = null;
            if (!_disposed)
            {
                RaiseComparisonResults();
                RaiseTextRunning();
                State = ModelState.Ready;
            }
        }

        async Task RunPaneAsync(TextOperation operation, bool basePane)
        {
            string status;
            string output = string.Empty;
            if (basePane) { BaseStatus = "Working - results appear after moderation."; }
            else { AdaptedStatus = "Working - results appear after moderation."; }
            RaiseComparisonResults();
            try
            {
                var result = await client.RunAsync(operation, prompt, TextRewriteTone.Default,
                    string.Empty, new ConversationSummaryOptions(), cancellation.Token);
                status = ResultStatus(result.Status);
                if (result.Status == LanguageModelResponseStatus.Complete) { output = result.Text; }
            }
            catch (OperationCanceledException) { status = "Cancelled."; }
            catch (Exception error) { status = FriendlyError(error); }
            if (_disposed) { return; }
            if (basePane) { BaseOutput = output; BaseStatus = status; }
            else { AdaptedOutput = output; AdaptedStatus = status; }
            RaiseComparisonResults();
        }
    }

    public static string TaskLabel(TextOperation operation) => operation switch
    {
        TextOperation.Summarize => "Summarize text",
        TextOperation.SummarizeConversation => "Summarize conversation",
        TextOperation.Rewrite => "Rewrite",
        TextOperation.RewriteCustom => "Rewrite with custom instruction",
        TextOperation.TextToTable => "Convert text to table",
        _ => "Generate"
    };

    private static string ResultStatus(LanguageModelResponseStatus status) => status switch
    {
        LanguageModelResponseStatus.Complete => "Complete.",
        LanguageModelResponseStatus.PromptBlockedByContentModeration => "Input blocked by moderation. Try different text or options.",
        LanguageModelResponseStatus.ResponseBlockedByContentModeration => "Output blocked by moderation. No result is available.",
        LanguageModelResponseStatus.BlockedByPolicy => "Blocked by the preview content policy.",
        LanguageModelResponseStatus.PromptLargerThanContext => "Input is too long. Shorten it and try again.",
        _ => "The model could not complete this request. No result is available."
    };

    private static string FriendlyError(Exception error) => AionTextIntelligenceClient.ErrorDetail(error);

    public async Task SendAsync()
    {
        if (!CanSend) return;
        if (_aionClient == null) return;

        var prompt = _promptText.Trim();
        if (prompt.Length == 0) return;

        // Snapshot + clear before the await so the input box empties immediately.
        PromptText = string.Empty;

        var aionMessage = new Message(MessageRole.Aion, string.Empty, MessageStatus.Streaming);
        State = ModelState.Generating;

        try
        {
            // Apply the first system prompt inside the error boundary: it can be blocked.
            if (_systemPrompt != _appliedSystemPrompt && !_hasConversationTurns)
            {
                _aionClient.StartNewConversation(_systemPrompt);
                _appliedSystemPrompt = _systemPrompt;
                Raise(nameof(SystemPromptPendingVisibility));
            }

            Messages.Add(new Message(MessageRole.User, prompt, MessageStatus.Complete));
            Messages.Add(aionMessage);
            _hasConversationTurns = true;

            var generation = await _aionClient.GenerateAsync(
                prompt,
                onUpdate: delta =>
                {
                    // Progress fires on a background thread; marshal to UI.
                    _dispatcher.TryEnqueue(() =>
                    {
                        if (aionMessage.Status == MessageStatus.Streaming)
                        {
                            aionMessage.Text += delta;
                        }
                    });
                }).ConfigureAwait(true);

            var result = generation.Response;
            aionMessage.Metrics = generation.Metrics;

            switch (result.Status)
            {
                case LanguageModelResponseStatus.Complete:
                    // Use the final accumulated text if it differs from the streamed text.
                    if (aionMessage.Text != result.Text)
                    {
                        aionMessage.Text = result.Text;
                    }
                    aionMessage.Status = MessageStatus.Complete;
                    break;

                case LanguageModelResponseStatus.PromptLargerThanContext:
                    // The conversation has filled Aion Instruct Preview's context window.
                    // Surface this as its own UX, distinct from Error — the
                    // user can recover with "New conversation".
                    aionMessage.Text = string.Empty;
                    aionMessage.StatusDetail =
                        "This conversation reached Aion Instruct Preview's context limit. " +
                        "Start a new conversation to keep chatting.";
                    aionMessage.Status = MessageStatus.Error;
                    IsContextFull = true;
                    break;

                case LanguageModelResponseStatus.PromptBlockedByContentModeration:
                    SetFailure(aionMessage, "The prompt was blocked by content moderation. Try a different prompt.");
                    break;

                case LanguageModelResponseStatus.ResponseBlockedByContentModeration:
                    SetFailure(aionMessage, "The response was blocked by content moderation. No final response is available.");
                    break;

                case LanguageModelResponseStatus.BlockedByPolicy:
                    SetFailure(aionMessage, "This request was blocked by the preview's content policy.");
                    break;

                default:
                    SetFailure(aionMessage, "Generation could not complete. This is an operational failure, not a moderation decision.");
                    break;
            }
        }
        catch (Exception ex)
        {
            if (!Messages.Contains(aionMessage))
            {
                PromptText = prompt;
                Messages.Add(aionMessage);
            }
            SetFailure(aionMessage, FailureDetail(ex));
        }
        finally
        {
            State = ModelState.Ready;
        }
    }

    // Describes a user-picked image and appends both the thumbnail entry and the
    // generated description to the transcript.
    //
    // The image description pipeline is independent of the chat context: it does not
    // read or extend the conversation history, and it mirrors the inbox
    // ImageDescriptionGenerator API exactly.
    public async Task DescribeImageAsync(StorageFile file)
    {
        if (_disposed || file is null) return;
        if (!DescribeEnabled) return;

        // Set before the first await so a second click can't slip through.
        State = ModelState.Generating;

        var kind = _selectedImageKind;

        var userMessage = new Message(
            MessageRole.User,
            $"Describe this image ({KindLabel(kind)})",
            MessageStatus.Complete);

        try
        {
            var bitmap = new Microsoft.UI.Xaml.Media.Imaging.BitmapImage();
            using (var thumbStream = await file.OpenReadAsync())
            {
                await bitmap.SetSourceAsync(thumbStream);
            }
            userMessage.Image = bitmap;
        }
        catch (Exception)
        {
            // A thumbnail is a nicety; a decode failure here must not block description.
        }

        if (_disposed) return;
        ImageMessages.Add(userMessage);

        var aionMessage = new Message(MessageRole.Aion, string.Empty, MessageStatus.Streaming);
        ImageMessages.Add(aionMessage);

        try
        {
            if (_descriptionClient is null)
            {
                aionMessage.StatusDetail =
                    "Loading the vision models (SigLIP2 + projector). First-run cache compilation may take several minutes.";
                var client = await AionImageDescriptionClient.CreateAsync().ConfigureAwait(true);
                if (_disposed)
                {
                    client.Dispose();
                    return;
                }
                _descriptionClient = client;
                aionMessage.StatusDetail = null;
            }

            if (_disposed) return;
            var generation = await _descriptionClient.DescribeAsync(
                file,
                kind,
                onUpdate: delta =>
                {
                    // Progress reports text deltas, exactly like the chat path
                    // (DescriptionSink::OnProcessingUpdate forwards only the new text).
                    // Append, don't assign.
                    _dispatcher.TryEnqueue(() =>
                    {
                        if (!_disposed && aionMessage.Status == MessageStatus.Streaming)
                        {
                            aionMessage.Text += delta;
                        }
                    });
                }).ConfigureAwait(true);

            if (_disposed) return;
            var result = generation.Response;
            aionMessage.Metrics = generation.Metrics;

            if (result.Status == ImageDescriptionResultStatus.Complete)
            {
                if (aionMessage.Text != result.Description)
                {
                    aionMessage.Text = result.Description;
                }
                aionMessage.Status = MessageStatus.Complete;
            }
            else
            {
                SetFailure(aionMessage, result.Status switch
                {
                    ImageDescriptionResultStatus.ImageBlockedByContentModeration =>
                        "The image was blocked by content moderation.",
                    ImageDescriptionResultStatus.TextInImageBlockedByContentModeration =>
                        "Text in the image was blocked by content moderation.",
                    ImageDescriptionResultStatus.DescriptionTextBlockedByContentModeration =>
                        "The description was blocked by content moderation. No final description is available.",
                    _ => "Image description could not complete. This is an operational failure, not a moderation decision.",
                });
            }
        }
        catch (Exception ex)
        {
            if (_disposed) return;
            SetFailure(aionMessage, FailureDetail(ex));
        }
        finally
        {
            if (!_disposed)
            {
                State = ModelState.Ready;
            }
        }
    }

    private static string KindLabel(ImageDescriptionKind kind) => kind switch
    {
        ImageDescriptionKind.BriefDescription => "brief",
        ImageDescriptionKind.DetailedDescription => "detailed",
        ImageDescriptionKind.DiagramDescription => "diagram",
        ImageDescriptionKind.AccessibleDescription => "accessible",
        _ => kind.ToString(),
    };

    // Discard the in-process LanguageModelContext (and its accumulated
    // conversation history) and open a fresh one. Clears the transcript
    // too so the UX matches the model state.
    public void StartNewConversation()
    {
        if (!CanStartNewConversation) return;
        if (_aionClient == null) return;

        try
        {
            _aionClient.StartNewConversation(_systemPrompt);
            _appliedSystemPrompt = _systemPrompt;
            _hasConversationTurns = false;
            Messages.Clear();
            IsContextFull = false;
            Raise(nameof(SystemPromptPendingVisibility));
        }
        catch (Exception ex)
        {
            Messages.Add(new Message(MessageRole.Aion, string.Empty, MessageStatus.Error, FailureDetail(ex)));
        }
    }

    private static void SetFailure(Message message, string detail)
    {
        // Queued UI callbacks check this status before appending any more text.
        message.Status = MessageStatus.Error;
        message.Text = string.Empty;
        message.StatusDetail = detail;
    }

    private static string FailureDetail(Exception exception) =>
        exception.HResult == unchecked((int)0x8A1F0202)
            ? "Content moderation blocked this request or system prompt. Try different input."
            : $"The operation failed (0x{exception.HResult:X8}). This is not a moderation decision.";

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        _textCancellation?.Cancel();
        _textIntelligenceClient?.Dispose();
        _textIntelligenceClient = null;
        _aionClient?.Dispose();
        _aionClient = null;
        _descriptionClient?.Dispose();
        _descriptionClient = null;
    }

    private void Raise([CallerMemberName] string? name = null) =>
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
}

// Minimal ICommand impl so we don't pull in CommunityToolkit.Mvvm.
internal sealed class RelayCommand : ICommand
{
    private readonly Action<object?> _execute;
    private readonly Predicate<object?>? _canExecute;

    public RelayCommand(Action<object?> execute, Predicate<object?>? canExecute = null)
    {
        _execute = execute;
        _canExecute = canExecute;
    }

    public bool CanExecute(object? parameter) => _canExecute?.Invoke(parameter) ?? true;
    public void Execute(object? parameter) => _execute(parameter);

    public event EventHandler? CanExecuteChanged;
    public void RaiseCanExecuteChanged() =>
        CanExecuteChanged?.Invoke(this, EventArgs.Empty);
}
