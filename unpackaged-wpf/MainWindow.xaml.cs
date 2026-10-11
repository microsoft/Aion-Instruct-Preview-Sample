using System;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Input;
using AionInstructPreview.Text;

namespace AionInstructPreview.Chat.Wpf;

public partial class MainWindow : Window
{
    private LanguageModel? _model;
    private LanguageModelContext? _context;

    public MainWindow()
    {
        InitializeComponent();
        Loaded += OnLoaded;
        Closed += OnWindowClosed;
    }

    private async void OnLoaded(object sender, RoutedEventArgs e)
    {
        // CreateAsync initializes the model. The first run can take several minutes
        // while the NPU context cache is prepared; later runs are faster.
        StatusText.Text = "Loading model (first run may take several minutes)...";
        try
        {
            _model = await LanguageModel.CreateAsync();
            _context = _model.CreateContext();
        }
        catch (Exception ex)
        {
            StatusText.Text = "Failed to load the model.";
            MessageBox.Show($"Model loading failed (0x{ex.HResult:X8}).", "Aion Instruct Preview: model load failed",
                MessageBoxButton.OK, MessageBoxImage.Error);
            return;
        }

        StatusText.Text = "Ready. Type a message and press Enter (or Send).";
        InputBox.IsEnabled = true;
        SendButton.IsEnabled = true;
        InputBox.Focus();
    }

    private void SendButton_Click(object sender, RoutedEventArgs e) => _ = SendAsync();

    private void InputBox_KeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Enter && SendButton.IsEnabled)
        {
            e.Handled = true;
            _ = SendAsync();
        }
    }

    private async Task SendAsync()
    {
        if (_model is null || _context is null)
        {
            return;
        }

        string prompt = InputBox.Text.Trim();
        if (prompt.Length == 0)
        {
            return;
        }

        InputBox.Clear();
        SetBusy(true);
        AppendLine($"You: {prompt}");
        Append("Aion Instruct Preview: ");
        int responseStart = ConversationBox.Text.Length;
        bool acceptingUpdates = true;

        try
        {
            // Preserve the sample's sampling settings from before options were exposed.
            var options = new LanguageModelOptions { Temperature = 0.5f, TopP = 0.9f, TopK = 40 };
            var op = _model.GenerateResponseAsync(_context, prompt, options);

            // Progress delivers text deltas on a background thread; marshal each
            // delta back to the UI thread before updating the transcript.
            op.Progress = (_, delta) => Dispatcher.BeginInvoke(new Action(() =>
            {
                if (acceptingUpdates)
                {
                    Append(delta);
                }
            }));

            LanguageModelResponseResult result = await op;
            acceptingUpdates = false;
            ConversationBox.Text = ConversationBox.Text[..responseStart];
            if (result.Status == LanguageModelResponseStatus.Complete)
            {
                AppendLine(result.Text);
            }
            else
            {
                AppendLine(result.Status switch
                {
                    LanguageModelResponseStatus.PromptBlockedByContentModeration =>
                        "[The prompt was blocked by content moderation. Try a different prompt.]",
                    LanguageModelResponseStatus.ResponseBlockedByContentModeration =>
                        "[The response was blocked by content moderation. No final response is available.]",
                    LanguageModelResponseStatus.BlockedByPolicy =>
                        "[This request was blocked by the preview's content policy.]",
                    LanguageModelResponseStatus.PromptLargerThanContext =>
                        "[The conversation reached the context limit. Restart the app to start a new conversation.]",
                    _ => "[Generation failed. This is an operational failure, not a moderation decision.]",
                });
            }
            AppendLine(string.Empty);
        }
        catch (Exception ex)
        {
            acceptingUpdates = false;
            ConversationBox.Text = ConversationBox.Text[..responseStart];
            AppendLine(ex.HResult == unchecked((int)0x8A1F0202)
                ? "[Content moderation blocked this request. Try different input.]"
                : $"[Generation failed (0x{ex.HResult:X8}). This is not a moderation decision.]");
            AppendLine(string.Empty);
        }
        finally
        {
            SetBusy(false);
            InputBox.Focus();
        }
    }

    private void SetBusy(bool busy)
    {
        InputBox.IsEnabled = !busy;
        SendButton.IsEnabled = !busy;
        StatusText.Text = busy ? "Generating..." : "Ready.";
    }

    private void Append(string text)
    {
        ConversationBox.AppendText(text);
        ConversationBox.ScrollToEnd();
    }

    private void AppendLine(string text) => Append(text + Environment.NewLine);

    private void OnWindowClosed(object? sender, EventArgs e)
    {
        // Dispose the context before the model to release native resources cleanly.
        _context?.Dispose();
        _model?.Dispose();
    }
}
