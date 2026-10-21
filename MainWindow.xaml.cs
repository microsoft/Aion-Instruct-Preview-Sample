using System.Collections.Specialized;
using System.ComponentModel;
using Microsoft.UI.Input;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Automation.Peers;
using AionInstructPreview.Chat.Models;
using AionInstructPreview.Chat.ViewModels;
using Windows.System;
using Windows.UI.Core;
using Windows.ApplicationModel.DataTransfer;

namespace AionInstructPreview.Chat;

public sealed partial class MainWindow : Window
{
    // Mirrors the "Render replies as Markdown" switch, so new replies follow it too.
    private bool _renderMarkdown = true;
    private bool _textUiReady;
    private Button? _lastTextAction;

    public ChatViewModel ViewModel { get; }

    public MainWindow()
    {
        ViewModel = new ChatViewModel();
        this.InitializeComponent();
        _textUiReady = true;
        UpdateTextTaskUi();
        TextIntelligenceView.PreviewKeyDown += OnTextToolsKeyDown;
        LoRAView.PreviewKeyDown += OnTextToolsKeyDown;
        this.Title = "Aion Instruct Preview Chat";

        // Mica backdrop: translucent material that picks up the desktop wallpaper tint.
        this.SystemBackdrop = new MicaBackdrop();

        // Custom title bar: hide the system chrome, hand the AppTitleBar
        // grid to the window so dragging works and caption buttons sit
        // over our content correctly.
        this.ExtendsContentIntoTitleBar = true;
        this.SetTitleBar(AppTitleBar);

        // Listen to handled Enter key events so plain Enter sends the prompt,
        // while Shift+Enter can still insert a newline.
        PromptBox.AddHandler(
            UIElement.KeyDownEvent,
            new KeyEventHandler(PromptBox_KeyDown),
            handledEventsToo: true);

        ViewModel.Messages.CollectionChanged += OnMessagesChanged;
        ViewModel.ImageMessages.CollectionChanged += OnMessagesChanged;
        ViewModel.PropertyChanged += OnViewModelPropertyChanged;

        // Messages resolve their brushes in code, so refresh them when the theme changes.
        var root = (FrameworkElement)this.Content;
        root.ActualThemeChanged += OnActualThemeChanged;

        this.Closed += (_, _) =>
        {
            _textUiReady = false;
            ViewModel.Messages.CollectionChanged -= OnMessagesChanged;
            ViewModel.ImageMessages.CollectionChanged -= OnMessagesChanged;
            ViewModel.PropertyChanged -= OnViewModelPropertyChanged;
            root.ActualThemeChanged -= OnActualThemeChanged;
            ViewModel.Dispose();
        };
    }

    private void OnActualThemeChanged(FrameworkElement sender, object args)
    {
        foreach (Message m in ViewModel.Messages.Concat(ViewModel.ImageMessages))
        {
            m.RefreshThemeBrushes();
        }
    }

    // Return focus to the prompt box whenever input becomes enabled again --
    // most notably right after a response finishes streaming (Generating ->
    // Ready), so the user can keep typing without re-clicking the box. Also
    // covers the initial model-ready transition. Marshalled through the
    // dispatcher so the IsEnabled binding has applied before we call Focus
    // (Focus is a no-op on a still-disabled control).
    private void OnViewModelPropertyChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (_textUiReady) { UpdateTextTaskUi(); }
        FrameworkElement? announcement = e.PropertyName switch
        {
            nameof(ChatViewModel.TextIntelligenceStatus) => SkillResultStatus,
            nameof(ChatViewModel.BaseStatus) => BaseResultStatus,
            nameof(ChatViewModel.AdaptedStatus) => AdaptedResultStatus,
            nameof(ChatViewModel.AdapterFeedback) => AdapterFeedbackText,
            nameof(ChatViewModel.AdapterWarningMessage) => AdapterCompatibilityWarning,
            _ => null
        };
        if (_textUiReady && announcement is not null)
        {
            Announce(announcement);
        }
        if (e.PropertyName == nameof(ChatViewModel.CanCancelTextIntelligence))
        {
            DispatcherQueue.TryEnqueue(() =>
            {
                if (!_textUiReady) { return; }
                if (ViewModel.CanCancelTextIntelligence)
                {
                    var cancel = LoRAView.Visibility == Visibility.Visible ? CancelComparisonButton : CancelTextButton;
                    cancel.Focus(FocusState.Programmatic);
                }
            });
        }
        if (e.PropertyName == nameof(ChatViewModel.TextToolsEnabled) && ViewModel.TextToolsEnabled &&
            _lastTextAction is { } action)
        {
            _lastTextAction = null;
            DispatcherQueue.TryEnqueue(() => { if (_textUiReady) { action.Focus(FocusState.Programmatic); } });
        }
        if (e.PropertyName == nameof(ChatViewModel.InputEnabled) && ViewModel.InputEnabled)
        {
            DispatcherQueue.TryEnqueue(() =>
            {
                if (_textUiReady && ChatView.Visibility == Visibility.Visible) { PromptBox.Focus(FocusState.Programmatic); }
            });
        }
    }

    private void OnMessagesChanged(object? sender, NotifyCollectionChangedEventArgs e)
    {
        if (e.Action == NotifyCollectionChangedAction.Add && e.NewItems is not null)
        {
            foreach (Message m in e.NewItems)
            {
                m.RenderMarkdown = _renderMarkdown;
                m.PropertyChanged += OnMessageChanged;
            }
        }
        ScrollToBottom();
    }

    // The "Render replies as Markdown" switch: applies to every reply, in both tabs, and to
    // replies that arrive later.
    private void OnRenderMarkdownToggled(object sender, RoutedEventArgs e)
    {
        _renderMarkdown = ((CheckBox)sender).IsChecked == true;
        foreach (Message m in ViewModel.Messages.Concat(ViewModel.ImageMessages))
        {
            m.RenderMarkdown = _renderMarkdown;
        }
    }

    private void OnMessageChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(Message.Text))
        {
            ScrollToBottom();
        }
    }

    // Scrolls whichever transcript is currently on screen. Both collections funnel
    // through the same handlers, and only one view is visible at a time.
    private void ScrollToBottom()
    {
        DispatcherQueue.TryEnqueue(() =>
        {
            var scroller = ImageView.Visibility == Visibility.Visible
                ? ImageTranscriptScroller
                : TranscriptScroller;
            scroller?.ChangeView(null, scroller.ScrollableHeight, null, disableAnimation: false);
        });
    }

    // Toggles the feature views. They are siblings in the same Grid rather than
    // separate Pages so the ViewModel, model client, and conversation context all stay
    // alive when switching (re-creating them would reload the model).
    private void OnNavSelectionChanged(
        NavigationView sender,
        NavigationViewSelectionChangedEventArgs args)
    {
        if (args.SelectedItem is not NavigationViewItem item)
        {
            return;
        }

        bool isChat = (item.Tag as string) == "chat";
        bool isImage = (item.Tag as string) == "image";
        ChatView.Visibility = isChat ? Visibility.Visible : Visibility.Collapsed;
        ImageView.Visibility = isImage ? Visibility.Visible : Visibility.Collapsed;
        TextIntelligenceView.Visibility = (item.Tag as string) == "text" ? Visibility.Visible : Visibility.Collapsed;
        LoRAView.Visibility = (item.Tag as string) == "lora" ? Visibility.Visible : Visibility.Collapsed;

        if (isChat && ViewModel.InputEnabled)
        {
            DispatcherQueue.TryEnqueue(() => PromptBox.Focus(FocusState.Programmatic));
        }
    }

    private async void OnLoadLoRAClick(object sender, RoutedEventArgs e)
    {
        try
        {
            var picker = new Windows.Storage.Pickers.FileOpenPicker();
            picker.FileTypeFilter.Add(".safetensors");
            WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(this));
            var file = await picker.PickSingleFileAsync();
            if (file is not null)
            {
                _lastTextAction = LoadAdapterButton;
                await ViewModel.LoadLoRAAsync(file.Path);
            }
        }
        catch (Exception error)
        {
            var dialog = new ContentDialog
            {
                Title = "Couldn't open the LoRA",
                Content = $"The LoRA picker failed (0x{error.HResult:X8}). Try again.",
                CloseButtonText = "OK",
                XamlRoot = Content.XamlRoot
            };
            await dialog.ShowAsync();
        }
    }
    private void OnUnloadLoRAClick(object sender, RoutedEventArgs e)
    {
        ViewModel.UnloadLoRA();
        LoadAdapterButton.Focus(FocusState.Programmatic);
    }
    private void OnCancelTextIntelligenceClick(object sender, RoutedEventArgs e) => ViewModel.CancelTextIntelligence();

    private TextOperation SelectedTextTask => Enum.Parse<TextOperation>(
        (string)((ComboBoxItem)TextOperationBox.SelectedItem).Tag);

    private void OnTextLayoutSizeChanged(object sender, SizeChangedEventArgs e)
    {
        if (!_textUiReady) { return; }
        TextTaskOptions.Orientation = e.NewSize.Width < 640 ? Orientation.Vertical : Orientation.Horizontal;
    }

    private void OnLoRALayoutSizeChanged(object sender, SizeChangedEventArgs e)
    {
        if (!_textUiReady) { return; }
        var stacked = e.NewSize.Width < 900;
        Grid.SetColumn(AdaptedResultCard, stacked ? 0 : 1);
        Grid.SetRow(AdaptedResultCard, stacked ? 1 : 0);
        ComparisonSecondColumn.Width = stacked ? new GridLength(0) : new GridLength(1, GridUnitType.Star);
        var orientation = e.NewSize.Width < 640 ? Orientation.Vertical : Orientation.Horizontal;
        CompareActions.Orientation = orientation;
    }

    private void OnTextTaskChanged(object sender, SelectionChangedEventArgs e) => OnSkillSettingsChanged();
    private void OnSkillInputChanged(object sender, TextChangedEventArgs e) => OnSkillSettingsChanged();
    private void OnSummaryPointsChanged(NumberBox sender, NumberBoxValueChangedEventArgs e) => OnSkillSettingsChanged();
    private void OnSummaryOptionsChanged(object sender, RoutedEventArgs e) => OnSkillSettingsChanged();

    private void OnSkillSettingsChanged()
    {
        if (!_textUiReady) { return; }
        if (ViewModel.TextToolsEnabled) { ViewModel.ClearSkillResult(); }
        UpdateTextTaskUi();
    }

    private void OnComparisonPromptChanged(object sender, TextChangedEventArgs e)
    {
        if (!_textUiReady) { return; }
        ViewModel.MarkComparisonOutOfDate();
        UpdateTextTaskUi();
    }

    private void UpdateTextTaskUi()
    {
        var operation = SelectedTextTask;
        var conversation = operation == TextOperation.SummarizeConversation;
        RewriteToneBox.Visibility = operation == TextOperation.Rewrite ? Visibility.Visible : Visibility.Collapsed;
        CustomRewriteInstruction.Visibility = operation == TextOperation.RewriteCustom ? Visibility.Visible : Visibility.Collapsed;
        ConversationSettings.Visibility = conversation ? Visibility.Visible : Visibility.Collapsed;
        TextSkillInput.Header = conversation ? "Conversation (JSON array)" : "Text";
        TextSkillInput.PlaceholderText = conversation
            ? "Try an example, or enter participant/message objects."
            : operation == TextOperation.TextToTable ? "Paste text containing the data for your table." : "Paste the text to process.";
        RunTextSkillButton.Content = operation switch
        {
            TextOperation.Summarize or TextOperation.SummarizeConversation => "Summarize",
            TextOperation.TextToTable => "Create table",
            _ => "Rewrite"
        };
        var validation = ValidateSkillInput();
        SetValidationMessage(SkillValidationMessage, validation);
        RunTextSkillButton.IsEnabled = ViewModel.TextToolsEnabled && validation.Length == 0;
        var hasPrompt = !string.IsNullOrWhiteSpace(ComparisonPromptInput.Text);
        CompareButton.IsEnabled = AdaptedOnlyButton.IsEnabled = ViewModel.TextToolsEnabled && hasPrompt && ViewModel.HasCustomAdapter;
        BaseOnlyButton.IsEnabled = ViewModel.TextToolsEnabled && hasPrompt;
        SetValidationMessage(CompareValidationMessage,
            !ViewModel.HasCustomAdapter ? "Load a LoRA to compare it with the base model." :
            !hasPrompt ? "Enter the prompt you used during training." : string.Empty);
        CopySkillButton.IsEnabled = ViewModel.TextIntelligenceOutput.Length > 0 || ViewModel.TableHeader.Count > 0;
        CopyBaseButton.IsEnabled = ViewModel.BaseOutput.Length > 0;
        CopyAdapterButton.IsEnabled = ViewModel.AdaptedOutput.Length > 0;
    }

    private void SetValidationMessage(TextBlock element, string message)
    {
        if (element.Text == message) { return; }
        element.Text = message;
        Announce(element);
    }

    private void Announce(FrameworkElement element)
    {
        DispatcherQueue.TryEnqueue(() =>
        {
            if (!_textUiReady) { return; }
            var peer = FrameworkElementAutomationPeer.FromElement(element) ??
                FrameworkElementAutomationPeer.CreatePeerForElement(element);
            peer?.RaiseAutomationEvent(AutomationEvents.LiveRegionChanged);
        });
    }

    private string ValidateSkillInput()
    {
        if (string.IsNullOrWhiteSpace(TextSkillInput.Text)) { return "Enter text or try an example."; }
        if (SelectedTextTask == TextOperation.RewriteCustom && string.IsNullOrWhiteSpace(CustomRewriteInstruction.Text))
        {
            return "Describe how you want the text rewritten.";
        }
        if (SelectedTextTask == TextOperation.SummarizeConversation &&
            (!double.IsFinite(MaxSummaryPoints.Value) || MaxSummaryPoints.Value < 1 ||
             MaxSummaryPoints.Value > 100 || MaxSummaryPoints.Value != Math.Truncate(MaxSummaryPoints.Value)))
        {
            return "Use a whole number from 1 to 100 for max key points.";
        }
        try
        {
            AionTextIntelligenceClient.ValidateInput(SelectedTextTask, TextSkillInput.Text, CustomRewriteInstruction.Text);
            return string.Empty;
        }
        catch (System.Text.Json.JsonException)
        {
            return "Enter a valid JSON array. Try the example to see the format.";
        }
        catch (TextInputValidationException error) { return error.Message; }
    }

    private void OnInsertTextExampleClick(object sender, RoutedEventArgs e)
    {
        TextSkillInput.Text = SelectedTextTask switch
        {
            TextOperation.SummarizeConversation => "[\n  { \"participant\": \"Alex\", \"message\": \"The meeting is Tuesday at ten.\" },\n  { \"participant\": \"Robin\", \"message\": \"I will bring the project schedule.\" }\n]",
            TextOperation.TextToTable => "Apples cost 3 dollars and weigh 1 kilogram. Pears cost 4 dollars and weigh 2 kilograms.",
            TextOperation.Rewrite or TextOperation.RewriteCustom => "I will send you the meeting notes tomorrow. Please let me know if you have any questions.",
            _ => "The public library reopened on Monday after a renovation. It now has new reading rooms and more study desks. Visitors can borrow books and use free internet access."
        };
        if (SelectedTextTask == TextOperation.RewriteCustom && string.IsNullOrWhiteSpace(CustomRewriteInstruction.Text))
        {
            CustomRewriteInstruction.Text = "Make this shorter while preserving the meaning.";
        }
    }

    private async void OnRunTextIntelligenceClick(object sender, RoutedEventArgs e)
    {
        if (!ViewModel.TextToolsEnabled || ValidateSkillInput().Length != 0) { return; }
        var options = new global::AionInstructPreview.Text.ConversationSummaryOptions();
        if (SelectedTextTask == TextOperation.SummarizeConversation)
        {
            options.InputKind = ConversationInputKind.SelectedIndex == 0
                ? global::AionInstructPreview.Text.InputKind.Email : global::AionInstructPreview.Text.InputKind.GeneralConversation;
            options.MaxKeyPoints = (uint)MaxSummaryPoints.Value;
            options.IncludeMessageCitations = SummaryCitations.IsChecked == true;
            options.IncludeParticipantAttribution = SummaryAttribution.IsChecked == true;
            options.Language = SummaryLanguage.Text;
        }
        _lastTextAction = RunTextSkillButton;
        await ViewModel.RunTextIntelligenceAsync(
            SelectedTextTask, TextSkillInput.Text,
            (global::AionInstructPreview.Text.TextRewriteTone)RewriteToneBox.SelectedItem,
            CustomRewriteInstruction.Text, options);
    }

    private async void OnRunComparisonClick(object sender, RoutedEventArgs e)
    {
        var button = (Button)sender;
        var tag = (string)button.Tag;
        if (!ViewModel.TextToolsEnabled || string.IsNullOrWhiteSpace(ComparisonPromptInput.Text) ||
            (tag != "base" && !ViewModel.HasCustomAdapter))
        {
            UpdateTextTaskUi();
            return;
        }
        _lastTextAction = button;
        await ViewModel.RunComparisonAsync(ComparisonPromptInput.Text, tag != "adapter", tag != "base");
    }

    private void OnTextToolsKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key == VirtualKey.Escape &&
            ((TextIntelligenceView.Visibility == Visibility.Visible && ViewModel.IsSkillRunning) ||
             (LoRAView.Visibility == Visibility.Visible && ViewModel.IsComparisonRunning)))
        {
            ViewModel.CancelTextIntelligence();
            e.Handled = true;
        }
        else if (e.Key == VirtualKey.Enter &&
            (InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Control) & CoreVirtualKeyStates.Down) != 0)
        {
            e.Handled = true;
            if (TextIntelligenceView.Visibility == Visibility.Visible)
            {
                OnRunTextIntelligenceClick(RunTextSkillButton, new RoutedEventArgs());
            }
            else if (LoRAView.Visibility == Visibility.Visible)
            {
                OnRunComparisonClick(CompareButton, new RoutedEventArgs());
            }
        }
    }

    private async void OnCopyTextResultClick(object sender, RoutedEventArgs e)
    {
        var text = ((Button)sender).Tag switch
        {
            "base" => ViewModel.BaseOutput,
            "adapter" => ViewModel.AdaptedOutput,
            _ => ViewModel.TableHeader.Count > 0
                ? string.Join(Environment.NewLine,
                    new[] { ViewModel.TableHeader }.Concat(ViewModel.TableRows.Select(row => row.Columns))
                        .Select(row => string.Join(",", row.Select(cell => $"\"{cell.Replace("\"", "\"\"")}\""))))
                : ViewModel.TextIntelligenceOutput
        };
        try
        {
            var package = new DataPackage();
            package.SetText(text);
            Clipboard.SetContent(package);
        }
        catch (Exception error)
        {
            await new ContentDialog
            {
                Title = "Couldn't copy the result",
                Content = $"Couldn't access the clipboard (0x{error.HResult:X8}). Try again.",
                CloseButtonText = "OK", XamlRoot = Content.XamlRoot
            }.ShowAsync();
        }
    }

    // File pickers in WinUI 3 are unpackaged-safe only after being associated with
    // the window's HWND -- without InitializeWithWindow the picker throws or never
    // shows. Kept in the view because it needs the window handle.
    private async void OnAttachImageClick(object sender, RoutedEventArgs e)
    {
        try
        {
            var picker = new Windows.Storage.Pickers.FileOpenPicker();
            picker.ViewMode = Windows.Storage.Pickers.PickerViewMode.Thumbnail;
            picker.SuggestedStartLocation = Windows.Storage.Pickers.PickerLocationId.PicturesLibrary;
            picker.FileTypeFilter.Add(".jpg");
            picker.FileTypeFilter.Add(".jpeg");
            picker.FileTypeFilter.Add(".png");
            picker.FileTypeFilter.Add(".bmp");
            picker.FileTypeFilter.Add(".gif");
            picker.FileTypeFilter.Add(".tif");
            picker.FileTypeFilter.Add(".tiff");

            nint hwnd = WinRT.Interop.WindowNative.GetWindowHandle(this);
            WinRT.Interop.InitializeWithWindow.Initialize(picker, hwnd);

            var file = await picker.PickSingleFileAsync();
            if (file is not null)
            {
                await ViewModel.DescribeImageAsync(file);
            }
        }
        catch (Exception ex)
        {
            var dialog = new ContentDialog
            {
                Title = "Couldn't open the image",
                Content = $"The image picker failed (0x{ex.HResult:X8}). Try again.",
                CloseButtonText = "OK",
                XamlRoot = Content.XamlRoot,
            };
            await dialog.ShowAsync();
        }
    }

    private void PromptBox_KeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key != VirtualKey.Enter)
        {
            return;
        }

        // Shift+Enter inserts a newline (the TextBox handles it natively
        // because AcceptsReturn=True). Plain Enter submits.
        var shift = InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Shift);
        if ((shift & CoreVirtualKeyStates.Down) == CoreVirtualKeyStates.Down)
        {
            return;
        }

        if (ViewModel.SendEnabled)
        {
            e.Handled = true;
            ViewModel.SendCommand.Execute(null);
        }
    }
}
