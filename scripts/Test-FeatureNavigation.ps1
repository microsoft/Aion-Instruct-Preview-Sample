<#
.SYNOPSIS
    Checks that feature views remain independent siblings under the navigation content.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
[xml]$layout = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\MainWindow.xaml') -Raw
$namespaces = New-Object System.Xml.XmlNamespaceManager $layout.NameTable
$namespaces.AddNamespace('ui', 'http://schemas.microsoft.com/winfx/2006/xaml/presentation')
$namespaces.AddNamespace('x', 'http://schemas.microsoft.com/winfx/2006/xaml')
$navigation = $layout.SelectSingleNode('//ui:NavigationView[@x:Name="MainNav"]', $namespaces)
if (-not $navigation) { throw 'Main navigation is missing.' }
foreach ($tag in 'chat', 'image', 'text', 'lora') {
    $icon = $navigation.SelectSingleNode(
        "ui:NavigationView.MenuItems/ui:NavigationViewItem[@Tag='$tag']/ui:NavigationViewItem.Icon/ui:FontIcon",
        $namespaces)
    if (-not $icon -or [string]::IsNullOrWhiteSpace($icon.Glyph)) {
        throw "$tag navigation must have an icon."
    }
}
$container = $navigation.SelectSingleNode('ui:Grid', $namespaces)
if (-not $container) { throw 'Navigation content grid is missing.' }
foreach ($name in 'ChatView', 'ImageView', 'TextIntelligenceView', 'LoRAView') {
    $views = $layout.SelectNodes("//*[@x:Name='$name']", $namespaces)
    if ($views.Count -ne 1 -or $views[0].ParentNode -ne $container) {
        throw "$name must be a unique direct child of the navigation content grid."
    }
}
$textView = $container.SelectSingleNode('ui:ScrollViewer[@x:Name="TextIntelligenceView"]', $namespaces)
foreach ($name in 'TextOperationBox', 'TextSkillInput', 'RewriteToneBox', 'TextSkillsView') {
    if (-not $textView.SelectSingleNode(".//*[@x:Name='$name']", $namespaces)) {
        throw "TI view is missing $name."
    }
}
$loraView = $container.SelectSingleNode('ui:ScrollViewer[@x:Name="LoRAView"]', $namespaces)
foreach ($name in 'ComparisonPromptInput', 'LoRACompareView', 'BaseResultCard', 'AdaptedResultCard',
        'LoadAdapterButton', 'UnloadAdapterButton') {
    if (-not $loraView.SelectSingleNode(".//*[@x:Name='$name']", $namespaces) -or
        $textView.SelectSingleNode(".//*[@x:Name='$name']", $namespaces)) {
        throw "$name must be exclusive to the LoRA validation tab."
    }
}
$tasks = $textView.SelectNodes('.//ui:ComboBox[@x:Name="TextOperationBox"]/ui:ComboBoxItem', $namespaces)
if ($tasks.Count -ne 5 -or @($tasks | Where-Object { $_.Tag -like 'Generate*' }).Count) {
    throw 'Text skills must contain only the five TI tasks, not comparison operations.'
}
foreach ($name in 'RewriteToneBox', 'CustomRewriteInstruction', 'ConversationSettings') {
    if ($textView.SelectSingleNode(".//*[@x:Name='$name']", $namespaces).Visibility -ne 'Collapsed') {
        throw "$name must be hidden in the default summary view."
    }
}
foreach ($name in 'ConversationInputKind', 'MaxSummaryPoints', 'SummaryLanguage', 'SummaryCitations', 'SummaryAttribution') {
    if ($textView.SelectSingleNode(".//*[@x:Name='$name']", $namespaces).IsEnabled -notmatch 'TextToolsEnabled') {
        throw "$name must be disabled while the model is busy."
    }
}
if ($textView.SelectSingleNode('.//ui:Grid[@x:Name="TextToolsLayout"]', $namespaces).SizeChanged -ne 'OnTextLayoutSizeChanged') {
    throw 'TI options must respond to the actual content size.'
}
if ($loraView.SelectSingleNode('.//ui:Grid[@x:Name="LoRALayout"]', $namespaces).SizeChanged -ne 'OnLoRALayoutSizeChanged') {
    throw 'LoRA comparison must respond to its own content size.'
}
Write-Output 'PASS: four independent tabs, isolated LoRA controls, task disclosure, busy controls and adaptive layouts.'
