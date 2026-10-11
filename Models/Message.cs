using System;
using System.ComponentModel;
using System.Runtime.CompilerServices;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;

namespace AionInstructPreview.Chat.Models;

// One chat entry in the transcript.
//
// For user-sent entries: Text + Status (=Complete) are set at construction
// and never mutated. For Aion Instruct Preview-generated entries: Status starts Streaming,
// Text grows chunk-by-chunk via the Progress callback, and Status finalizes
// to Complete or Error when the Aion Instruct Preview call returns.
public sealed class Message : INotifyPropertyChanged
{
    private string _text;
    private MessageStatus _status;
    private string? _statusDetail;
    private GenerationMetrics? _metrics;
    private ImageSource? _image;

    public Message(MessageRole role, string text, MessageStatus status, string? statusDetail = null)
    {
        Role = role;
        _text = text;
        _status = status;
        _statusDetail = statusDetail;
        CreatedAt = DateTimeOffset.UtcNow;

        // Resolve theme brushes once at construction. Theme switching mid-
        // session would require rebinding; acceptable trade-off for a sample
        // (and avoids resource-key indirection in XAML, which x:Bind doesn't
        // do natively).
        var resources = Application.Current.Resources;
        BubbleBrush = (Brush)resources[role == MessageRole.User
            ? "AccentFillColorDefaultBrush"
            : "ControlFillColorDefaultBrush"];
        ForegroundBrush = (Brush)resources[role == MessageRole.User
            ? "TextOnAccentFillColorPrimaryBrush"
            : "TextFillColorPrimaryBrush"];
    }

    public MessageRole Role { get; }

    public DateTimeOffset CreatedAt { get; }

    public string Text
    {
        get => _text;
        set
        {
            if (_text == value) return;
            _text = value;
            Raise();
            // Typing dots are shown when streaming + empty; toggling Text
            // affects that derived visibility.
            Raise(nameof(TypingVisibility));
            Raise(nameof(TextVisibility));
        }
    }

    public MessageStatus Status
    {
        get => _status;
        set
        {
            if (_status == value) return;
            _status = value;
            Raise();
            Raise(nameof(IsErrored));
            Raise(nameof(ErrorVisibility));
            Raise(nameof(StatusDetailBrush));
            Raise(nameof(IsUser));
            Raise(nameof(IsAion));
            Raise(nameof(BubbleAlignment));
            Raise(nameof(TypingVisibility));
            Raise(nameof(TextVisibility));
        }
    }

    public string? StatusDetail
    {
        get => _statusDetail;
        set
        {
            if (_statusDetail == value) return;
            _statusDetail = value;
            Raise();
            Raise(nameof(StatusDetailVisibility));
        }
    }

    // Populated for Aion Instruct Preview-generated entries when the streaming call
    // completes. Drives the small caption shown under the bubble.
    public GenerationMetrics? Metrics
    {
        get => _metrics;
        set
        {
            if (ReferenceEquals(_metrics, value)) return;
            _metrics = value;
            Raise();
            Raise(nameof(MetricsText));
            Raise(nameof(MetricsVisibility));
        }
    }

    public string MetricsText => _metrics?.DisplayText ?? string.Empty;
    public Visibility MetricsVisibility =>
        _metrics is not null ? Visibility.Visible : Visibility.Collapsed;

    // Set on a user entry that attached an image for description. The transcript
    // shows a thumbnail above the text so the description has visible context.
    public ImageSource? Image
    {
        get => _image;
        set
        {
            if (ReferenceEquals(_image, value)) return;
            _image = value;
            Raise();
            Raise(nameof(ImageVisibility));
        }
    }

    public Visibility ImageVisibility =>
        _image is not null ? Visibility.Visible : Visibility.Collapsed;

    // Helpers for the DataTemplate. Pre-computed so XAML doesn't need
    // method bindings or converters.
    public bool IsErrored => _status == MessageStatus.Error;
    public Visibility ErrorVisibility =>
        _status == MessageStatus.Error ? Visibility.Visible : Visibility.Collapsed;

    // StatusDetail carries both failure text and in-progress hints (e.g. "loading the
    // vision models"), so it is shown whenever it is set -- not only on error -- and
    // takes its colour from the status instead.
    public Visibility StatusDetailVisibility =>
        !string.IsNullOrEmpty(_statusDetail) ? Visibility.Visible : Visibility.Collapsed;

    public Brush StatusDetailBrush => (Brush)Application.Current.Resources[
        _status == MessageStatus.Error
            ? "SystemFillColorCriticalBrush"
            : "TextFillColorTertiaryBrush"];

    public bool IsUser => Role == MessageRole.User;
    public bool IsAion => Role == MessageRole.Aion;

    public HorizontalAlignment BubbleAlignment =>
        Role == MessageRole.User ? HorizontalAlignment.Right : HorizontalAlignment.Left;

    // Direct Brush bindings so XAML can use {x:Bind} without a converter.
    public Brush BubbleBrush { get; }
    public Brush ForegroundBrush { get; }

    // "Aion Instruct Preview is thinking" dots: shown when the bubble is a streaming Aion Instruct Preview
    // reply that hasn't produced any text yet. Once the first text chunk arrives,
    // dots collapse and the streaming text takes over.
    public Visibility TypingVisibility =>
        (Role == MessageRole.Aion && _status == MessageStatus.Streaming && _text.Length == 0)
            ? Visibility.Visible : Visibility.Collapsed;

    public Visibility TextVisibility =>
        TypingVisibility == Visibility.Visible ? Visibility.Collapsed : Visibility.Visible;

    public event PropertyChangedEventHandler? PropertyChanged;

    private void Raise([CallerMemberName] string? name = null) =>
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
}
