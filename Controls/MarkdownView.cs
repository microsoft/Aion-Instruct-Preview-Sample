using System.Globalization;
using System.Text;
using Markdig;
using Markdig.Extensions.Tables;
using Markdig.Syntax;
using Markdig.Syntax.Inlines;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Documents;
using Microsoft.UI.Xaml.Media;
using MdBlock = Markdig.Syntax.Block;
using MdInline = Markdig.Syntax.Inlines.Inline;

namespace AionInstructPreview.Chat.Controls;

// Renders an Aion Instruct Preview reply as Markdown. The chat re-renders it on every
// streamed update, so it rebuilds its content from scratch each time Text changes.
//
// Two rules keep it honest about what the model wrote. Please keep them when changing it:
//
//   * It never drops content. Anything it doesn't style shows as its Markdown source, so
//     text missing on screen was never in the reply.
//   * It never touches the network. It creates no Hyperlink or Image elements and doesn't
//     render HTML, so a reply can't make the app fetch or open a URL the model wrote.
//     Link and image URLs show as text after the link text instead.
public sealed partial class MarkdownView : UserControl
{
    public static readonly DependencyProperty TextProperty = DependencyProperty.Register(
        nameof(Text), typeof(string), typeof(MarkdownView),
        new PropertyMetadata(string.Empty, (d, _) => ((MarkdownView)d).Render()));

    // DisableHtml shows HTML as typed. Pipe tables are the only extension: emphasis extras
    // would turn the single tildes in text like "~5 minutes" into subscript.
    private static readonly MarkdownPipeline Pipeline = new MarkdownPipelineBuilder()
        .UsePipeTables()
        .DisableHtml()
        .UsePreciseSourceLocation()
        .Build();

    private static readonly FontFamily Monospace = new("Cascadia Mono, Consolas");

    private readonly StackPanel _blocks = new() { Spacing = 8 };

    public MarkdownView()
    {
        Content = _blocks;

        // Brushes are looked up in code when the view renders, so render again when the theme
        // changes; otherwise replies on screen keep the old theme's colors.
        ActualThemeChanged += (_, _) => Render();
    }

    public string Text
    {
        get => (string)GetValue(TextProperty);
        set => SetValue(TextProperty, value);
    }

    private void Render()
    {
        _blocks.Children.Clear();
        string text = Text ?? string.Empty;
        new BlockWriter(text, _blocks).Write(Markdown.Parse(text, Pipeline), indent: 0);
    }

    private static Brush ThemeBrush(string key) => (Brush)Application.Current.Resources[key];

    // Writes Markdig blocks into a panel. Consecutive paragraphs, headings and list items
    // share one RichTextBlock, so they can be selected together. Code blocks, quotes, tables
    // and rules each get an element of their own.
    private sealed class BlockWriter(string source, Panel panel)
    {
        private const double ListIndent = 28;

        private RichTextBlock? _flow;

        public void Write(ContainerBlock container, double indent)
        {
            foreach (MdBlock block in container)
            {
                WriteBlock(block, indent);
            }
        }

        private void WriteBlock(MdBlock block, double indent)
        {
            switch (block)
            {
                case HeadingBlock heading:
                    Paragraph title = AddParagraph(heading.Inline, indent, marker: null, top: 12);
                    title.FontSize = heading.Level switch { 1 => 20, 2 => 18, 3 => 16, _ => 14 };
                    title.FontWeight = FontWeights.SemiBold;
                    break;
                case ParagraphBlock paragraph:
                    AddParagraph(paragraph.Inline, indent, marker: null, top: 8);
                    break;
                case ListBlock list:
                    WriteList(list, indent);
                    break;
                case CodeBlock code:
                    AddElement(CodeBox(code), indent);
                    break;
                case QuoteBlock quote:
                    AddElement(Quote(quote), indent);
                    break;
                case Table table:
                    AddElement(TableView(table), indent);
                    break;
                case ThematicBreakBlock:
                    AddElement(new Border { Height = 1, Background = ThemeBrush("DividerStrokeColorDefaultBrush") }, indent);
                    break;
                case LinkReferenceDefinitionGroup:
                    // Definitions aren't shown in Markdown; the links that use them show the URL.
                    break;
                case ContainerBlock other:
                    Write(other, indent);
                    break;
                default:
                    AddParagraph(null, indent, marker: null, top: 8).Inlines.Add(new Run { Text = SourceOf(block) });
                    break;
            }
        }

        private void WriteList(ListBlock list, double indent)
        {
            double itemIndent = indent + ListIndent;
            int number = list.IsOrdered
                && int.TryParse(list.OrderedStart, NumberStyles.Integer, CultureInfo.InvariantCulture, out int start)
                ? start : 1;

            foreach (MdBlock child in list)
            {
                if (child is not ListItemBlock item)
                {
                    WriteBlock(child, itemIndent);
                    continue;
                }

                string marker = list.IsOrdered
                    ? number++.ToString(CultureInfo.InvariantCulture) + list.OrderedDelimiter
                    : indent == 0 ? "\u2022" : "\u25E6";

                // The marker goes on the item's first paragraph, or on a line of its own when
                // the item starts with something else, such as a code block.
                bool markerWritten = false;
                foreach (MdBlock part in item)
                {
                    if (!markerWritten && part is ParagraphBlock first)
                    {
                        AddParagraph(first.Inline, itemIndent, marker, top: 4);
                    }
                    else
                    {
                        if (!markerWritten)
                        {
                            AddParagraph(null, itemIndent, marker, top: 4);
                        }
                        WriteBlock(part, itemIndent);
                    }
                    markerWritten = true;
                }

                if (!markerWritten)
                {
                    AddParagraph(null, itemIndent, marker, top: 4);
                }
            }
        }

        private Paragraph AddParagraph(ContainerInline? inlines, double indent, string? marker, double top)
        {
            _flow ??= AddToPanel(new RichTextBlock { IsTextSelectionEnabled = true, TextWrapping = TextWrapping.Wrap });

            var paragraph = new Paragraph
            {
                Margin = new Thickness(indent, _flow.Blocks.Count == 0 ? 0 : top, 0, 0),
            };
            if (marker is not null)
            {
                // Hanging indent: the marker sits in the gutter left of the indent, and the
                // tab moves the item's text to the indent.
                paragraph.TextIndent = -ListIndent;
                paragraph.Inlines.Add(new Run { Text = marker + "\t" });
            }
            WriteInlines(paragraph.Inlines, inlines);
            _flow.Blocks.Add(paragraph);
            return paragraph;
        }

        private void AddElement(FrameworkElement element, double indent)
        {
            element.Margin = new Thickness(indent, 0, 0, 0);
            AddToPanel(element);

            // Text after this element starts a new RichTextBlock below it.
            _flow = null;
        }

        private T AddToPanel<T>(T element) where T : UIElement
        {
            panel.Children.Add(element);
            return element;
        }

        private static FrameworkElement CodeBox(CodeBlock code)
        {
            var content = new StackPanel { Spacing = 4 };
            if (code is FencedCodeBlock { Info.Length: > 0 } fenced)
            {
                // The fence's info string, usually the language.
                content.Children.Add(new TextBlock
                {
                    Text = string.IsNullOrEmpty(fenced.Arguments) ? fenced.Info : $"{fenced.Info} {fenced.Arguments}",
                    FontSize = 12,
                    Foreground = ThemeBrush("TextFillColorTertiaryBrush"),
                });
            }
            content.Children.Add(new TextBlock
            {
                // Lines.ToString() joins exactly the block's lines. Don't loop over
                // Lines.Lines: it's a buffer with spare capacity, which adds blank lines.
                Text = code.Lines.ToString(),
                FontFamily = Monospace,
                IsTextSelectionEnabled = true,
                TextWrapping = TextWrapping.Wrap,
            });

            return new Border
            {
                Child = content,
                Background = ThemeBrush("SolidBackgroundFillColorBaseBrush"),
                BorderBrush = ThemeBrush("ControlStrokeColorDefaultBrush"),
                BorderThickness = new Thickness(1),
                CornerRadius = new CornerRadius(4),
                Padding = new Thickness(10, 8, 10, 8),
            };
        }

        private FrameworkElement Quote(QuoteBlock quote)
        {
            var content = new StackPanel { Spacing = 8 };
            new BlockWriter(source, content).Write(quote, indent: 0);
            return new Border
            {
                Child = content,
                BorderBrush = ThemeBrush("TextFillColorDisabledBrush"),
                BorderThickness = new Thickness(3, 0, 0, 0),
                Padding = new Thickness(12, 2, 0, 2),
            };
        }

        private FrameworkElement TableView(Table table)
        {
            var grid = new Grid { HorizontalAlignment = HorizontalAlignment.Left };
            Brush line = ThemeBrush("DividerStrokeColorDefaultBrush");
            int rowIndex = 0;

            foreach (TableRow row in table.OfType<TableRow>())
            {
                grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
                int columnIndex = 0;
                foreach (TableCell cell in row.OfType<TableCell>())
                {
                    while (grid.ColumnDefinitions.Count <= columnIndex)
                    {
                        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                    }

                    var text = new RichTextBlock
                    {
                        IsTextSelectionEnabled = true,
                        TextWrapping = TextWrapping.Wrap,
                        MaxWidth = 280,
                        TextAlignment = AlignmentOf(table, columnIndex),
                        FontWeight = row.IsHeader ? FontWeights.SemiBold : FontWeights.Normal,
                    };
                    foreach (MdBlock part in cell)
                    {
                        var paragraph = new Paragraph();
                        if (part is ParagraphBlock content)
                        {
                            WriteInlines(paragraph.Inlines, content.Inline);
                        }
                        else
                        {
                            paragraph.Inlines.Add(new Run { Text = SourceOf(part) });
                        }
                        text.Blocks.Add(paragraph);
                    }

                    var border = new Border
                    {
                        Child = text,
                        Padding = new Thickness(8, 4, 8, 4),
                        BorderBrush = line,
                        BorderThickness = new Thickness(columnIndex == 0 ? 1 : 0, rowIndex == 0 ? 1 : 0, 1, 1),
                        Background = row.IsHeader ? ThemeBrush("SubtleFillColorSecondaryBrush") : null,
                    };
                    Grid.SetRow(border, rowIndex);
                    Grid.SetColumn(border, columnIndex);
                    grid.Children.Add(border);
                    columnIndex++;
                }
                rowIndex++;
            }

            // A wide table scrolls sideways instead of overflowing the chat bubble. The
            // scrollbar is drawn over the content, so a table that can scroll keeps room for
            // it under the last row.
            var scroller = new ScrollViewer
            {
                Content = grid,
                HorizontalScrollBarVisibility = ScrollBarVisibility.Auto,
                HorizontalScrollMode = ScrollMode.Auto,
                VerticalScrollBarVisibility = ScrollBarVisibility.Disabled,
                VerticalScrollMode = ScrollMode.Disabled,
            };
            scroller.SizeChanged += (_, _) => ReserveScrollBarSpace(scroller);
            grid.SizeChanged += (_, _) => ReserveScrollBarSpace(scroller);
            return scroller;
        }

        private static void ReserveScrollBarSpace(ScrollViewer scroller)
        {
            double size = Application.Current.Resources.TryGetValue("ScrollBarSize", out object value) && value is double d ? d : 12;
            var padding = new Thickness(0, 0, 0, scroller.ScrollableWidth > 0 ? size : 0);
            if (scroller.Padding != padding)
            {
                scroller.Padding = padding;
            }
        }

        private static TextAlignment AlignmentOf(Table table, int column) =>
            column < table.ColumnDefinitions.Count
                ? table.ColumnDefinitions[column].Alignment switch
                {
                    TableColumnAlign.Center => TextAlignment.Center,
                    TableColumnAlign.Right => TextAlignment.Right,
                    _ => TextAlignment.Left,
                }
                : TextAlignment.Left;

        private void WriteInlines(InlineCollection target, ContainerInline? container)
        {
            for (MdInline? inline = container?.FirstChild; inline is not null; inline = inline.NextSibling)
            {
                switch (inline)
                {
                    case LiteralInline literal:
                        target.Add(new Run { Text = literal.Content.ToString() });
                        break;
                    case EmphasisInline emphasis:
                        Span span = emphasis.DelimiterCount >= 2 ? new Bold() : new Italic();
                        WriteInlines(span.Inlines, emphasis);
                        target.Add(span);
                        break;
                    case CodeInline code:
                        target.Add(new Run { Text = code.Content, FontFamily = Monospace });
                        break;
                    case LineBreakInline:
                        // Chat replies use single newlines as line breaks, so keep them rather
                        // than joining the lines into one, as CommonMark would.
                        target.Add(new LineBreak());
                        break;
                    case LinkInline link:
                        WriteLink(target, link);
                        break;
                    case AutolinkInline autolink:
                        target.Add(new Run { Text = autolink.Url });
                        break;
                    case HtmlEntityInline entity:
                        target.Add(new Run { Text = entity.Transcoded.ToString() });
                        break;
                    case DelimiterInline delimiter:
                        target.Add(new Run { Text = delimiter.ToLiteral() });
                        WriteInlines(target, delimiter);
                        break;
                    case ContainerInline other:
                        WriteInlines(target, other);
                        break;
                    default:
                        target.Add(new Run { Text = SourceOf(inline) });
                        break;
                }
            }
        }

        private void WriteLink(InlineCollection target, LinkInline link)
        {
            // Don't turn this into a Hyperlink or an Image: either would let a reply open or
            // download a URL the model chose. Show the text, or an image's alt text, then the URL.
            WriteInlines(target, link);

            string url = link.GetDynamicUrl?.Invoke() ?? link.Url ?? string.Empty;
            if (url.Length == 0 || (!link.IsImage && url == PlainText(link)))
            {
                return;
            }

            string details = link.IsImage ? $"image: {url}" : url;
            if (!string.IsNullOrEmpty(link.Title))
            {
                details += $" \"{link.Title}\"";
            }
            target.Add(new Run { Text = $" ({details})", Foreground = ThemeBrush("TextFillColorSecondaryBrush") });
        }

        private static string PlainText(ContainerInline container)
        {
            var text = new StringBuilder();
            for (MdInline? inline = container.FirstChild; inline is not null; inline = inline.NextSibling)
            {
                if (inline is LiteralInline literal)
                {
                    text.Append(literal.Content.ToString());
                }
                else if (inline is ContainerInline nested)
                {
                    text.Append(PlainText(nested));
                }
            }
            return text.ToString();
        }

        private string SourceOf(MarkdownObject node) =>
            node.Span.Start >= 0 && node.Span.Length > 0 && node.Span.End < source.Length
                ? source.Substring(node.Span.Start, node.Span.Length)
                : string.Empty;
    }
}
