using System.Collections.Specialized;
using System.ComponentModel;
using Microsoft.UI.Input;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using AionInstructPreview.Chat.Models;
using AionInstructPreview.Chat.ViewModels;
using Windows.System;
using Windows.UI.Core;

namespace AionInstructPreview.Chat;

public sealed partial class MainWindow : Window
{
    public ChatViewModel ViewModel { get; }

    public MainWindow()
    {
        ViewModel = new ChatViewModel();
        this.InitializeComponent();
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

        this.Closed += (_, _) =>
        {
            ViewModel.Messages.CollectionChanged -= OnMessagesChanged;
            ViewModel.ImageMessages.CollectionChanged -= OnMessagesChanged;
            ViewModel.PropertyChanged -= OnViewModelPropertyChanged;
            ViewModel.Dispose();
        };
    }

    // Return focus to the prompt box whenever input becomes enabled again --
    // most notably right after a response finishes streaming (Generating ->
    // Ready), so the user can keep typing without re-clicking the box. Also
    // covers the initial model-ready transition. Marshalled through the
    // dispatcher so the IsEnabled binding has applied before we call Focus
    // (Focus is a no-op on a still-disabled control).
    private void OnViewModelPropertyChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(ChatViewModel.InputEnabled) && ViewModel.InputEnabled)
        {
            DispatcherQueue.TryEnqueue(() => PromptBox.Focus(FocusState.Programmatic));
        }
    }

    private void OnMessagesChanged(object? sender, NotifyCollectionChangedEventArgs e)
    {
        if (e.Action == NotifyCollectionChangedAction.Add && e.NewItems is not null)
        {
            foreach (Message m in e.NewItems)
            {
                m.PropertyChanged += OnMessageChanged;
            }
        }
        ScrollToBottom();
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

    // Toggles the two feature views. They are siblings in the same Grid rather than
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
        ChatView.Visibility = isChat ? Visibility.Visible : Visibility.Collapsed;
        ImageView.Visibility = isChat ? Visibility.Collapsed : Visibility.Visible;

        if (isChat && ViewModel.InputEnabled)
        {
            DispatcherQueue.TryEnqueue(() => PromptBox.Focus(FocusState.Programmatic));
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
