<#
.SYNOPSIS
    Exercises task selection, validation and comparison in a running sample through UI Automation.
.PARAMETER AppProcessId
    Process ID of this branch's running WinUI sample.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][int]$AppProcessId,
    [string]$AdapterPath,
    [string]$IncompatibleAdapterPath,
    [string]$RevalidationAdapterPath
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
$app = Get-Process -Id $AppProcessId -ErrorAction Stop
$windowDeadline = [DateTime]::UtcNow.AddSeconds(30)
while ($app.MainWindowHandle -eq 0) {
    if ($app.HasExited) { throw 'Sample exited before creating its window.' }
    if ([DateTime]::UtcNow -gt $windowDeadline) { throw 'Sample did not create a window within 30 seconds.' }
    Start-Sleep -Milliseconds 200
    $app.Refresh()
}
$window = [System.Windows.Automation.AutomationElement]::FromHandle($app.MainWindowHandle)
$scope = [System.Windows.Automation.TreeScope]::Descendants
function Find-Control {
    param([string]$Id, [string]$Name, [switch]$Optional)
    $property = if ($Id) { [System.Windows.Automation.AutomationElement]::AutomationIdProperty }
        else { [System.Windows.Automation.AutomationElement]::NameProperty }
    $value = if ($Id) { $Id } else { $Name }
    $condition = New-Object System.Windows.Automation.PropertyCondition($property, $value)
    $control = $window.FindFirst($scope, $condition)
    if (-not $control -and -not $Optional) { throw "Control not found: $value" }
    return $control
}
function Assert-UI {
    param([scriptblock]$Condition, [string]$Message)
    Wait-UI -Condition $Condition -Seconds 10 -Description $Message
    Write-Output "PASS: $Message"
}
function Set-Text {
    param([string]$Id, [string]$Text)
    (Find-Control -Id $Id).GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).SetValue($Text)
    Wait-UI -Condition {
        (Find-Control -Id $Id).GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value -eq $Text
    } -Seconds 10
}
function Invoke-Control {
    param([string]$Id, [string]$Name)
    Wait-UI -Condition { (Find-Control -Id $Id -Name $Name).Current.IsEnabled } -Seconds 10
    (Find-Control -Id $Id -Name $Name).GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
}
function Select-Task {
    param([string]$Name)
    $box = Find-Control -Id 'TextOperationBox'
    $box.GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern).Expand()
    Wait-UI -Condition { [bool](Find-Control -Name $Name -Optional) } -Seconds 10
    $item = Find-Control -Name $Name
    $selection = $item.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)
    $selection.Select()
    Wait-UI -Condition { $selection.Current.IsSelected } -Seconds 10 -Description "Select task '$Name'"
    $box.GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern).Collapse()
}
function Wait-UI {
    param([scriptblock]$Condition, [int]$Seconds = 120, [string]$Description = 'Expected UI state')
    $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
    $lastError = ''
    while ($true) {
        $app.Refresh()
        if ($app.HasExited) { throw 'The sample exited during UI checks.' }
        if (Find-Control -Name 'Aion Instruct Preview failed to load' -Optional) {
            throw 'The sample reported a model-loading failure.'
        }
        try {
            if (& $Condition) { return }
        } catch { $lastError = $_.Exception.Message }
        if ([DateTime]::UtcNow -gt $deadline) { throw "${Description}: timed out after ${Seconds}s. Last lookup error: $lastError" }
        Start-Sleep -Milliseconds 100
    }
}
function Load-TestAdapter {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { throw "Adapter test file not found: $Path" }
    Invoke-Control -Id 'LoadAdapterButton'
    Wait-UI -Condition { [bool](Find-Control -Name 'Open' -Optional) } -Seconds 20
    $dialog = Find-Control -Name 'Open'
    $fields = $dialog.FindAll($scope, (New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::AutomationIdProperty, '1148')))
    $edit = $null
    foreach ($field in $fields) {
        $class = New-Object Text.StringBuilder 256
        [void][AionPickerTest]::GetClassName([IntPtr]$field.Current.NativeWindowHandle, $class, 256)
        if ($class.ToString() -eq 'Edit') { $edit = $field }
    }
    if (-not $edit) { throw 'App-owned picker file-name edit is missing.' }
    [void][AionPickerTest]::SendMessage([IntPtr]$edit.Current.NativeWindowHandle, 0x000C, [IntPtr]::Zero, $Path)
    $open = $dialog.FindAll($scope, (New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::AutomationIdProperty, '1'))) |
        Where-Object { $_.Current.Name -eq 'Open' -and $_.Current.NativeWindowHandle -ne 0 } |
        Select-Object -First 1
    if (-not $open) { throw 'App-owned picker Open button is missing.' }
    [void][AionPickerTest]::SendMessage([IntPtr]$open.Current.NativeWindowHandle, 0x00F5, [IntPtr]::Zero, [IntPtr]::Zero)
    $expectedFileName = [IO.Path]::GetFileName($Path)
    Wait-UI -Condition {
        $feedback = Find-Control -Id 'AdapterFeedbackText' -Optional
        (Find-Control -Id 'LoadAdapterButton').Current.IsEnabled -and
        -not (Find-Control -Name 'Open' -Optional) -and $feedback -and
        ($feedback.Current.Name.StartsWith("Loaded $expectedFileName.") -or
         $feedback.Current.Name.StartsWith("Loaded $expectedFileName with a compatibility warning.") -or
         $feedback.Current.Name.StartsWith('Replacement failed;') -or
         $feedback.Current.Name.StartsWith('Adapter could not be loaded.'))
    }
    Wait-UI -Condition { (Find-Control -Id 'LoadAdapterButton').Current.HasKeyboardFocus }
    Assert-UI -Condition { (Find-Control -Id 'LoadAdapterButton').Current.HasKeyboardFocus } -Message 'Adapter loading restores keyboard focus'
}
if ($AdapterPath -and -not ('AionPickerTest' -as [type])) {
    Add-Type @'
using System; using System.Text; using System.Runtime.InteropServices;
public static class AionPickerTest {
    [DllImport("user32.dll", CharSet=CharSet.Unicode)]
    public static extern int GetClassName(IntPtr hwnd, StringBuilder name, int size);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)]
    public static extern IntPtr SendMessage(IntPtr hwnd, uint message, IntPtr wParam, string lParam);
    [DllImport("user32.dll")]
    public static extern IntPtr SendMessage(IntPtr hwnd, uint message, IntPtr wParam, IntPtr lParam);
}
'@
}
Wait-UI -Condition { [bool](Find-Control -Name 'Text intelligence' -Optional) } -Seconds 600 -Description 'Model ready and navigation visible'
(Find-Control -Name 'Text intelligence').GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
Wait-UI -Condition { (Find-Control -Id 'TextOperationBox').Current.IsEnabled } -Seconds 30
Assert-UI -Condition { -not (Find-Control -Id 'LoadAdapterButton' -Optional) } -Message 'Text intelligence has no developer LoRA controls'
(Find-Control -Name 'LoRA validation').GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
if (Find-Control -Id 'UnloadAdapterButton' -Optional) { Invoke-Control -Id 'UnloadAdapterButton' }
(Find-Control -Name 'Text intelligence').GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
Select-Task -Name 'Summarize text'
Set-Text -Id 'TextSkillInput' -Text ''
Assert-UI -Condition { -not (Find-Control -Id 'RunTextSkillButton').Current.IsEnabled } -Message 'Empty skill input disables the action'
Assert-UI -Condition { -not (Find-Control -Id 'RewriteToneBox' -Optional) } -Message 'Summary hides rewrite tone'
Assert-UI -Condition { -not (Find-Control -Id 'CustomRewriteInstruction' -Optional) } -Message 'Summary hides custom instructions'
Invoke-Control -Name 'Try an example'
Assert-UI -Condition { (Find-Control -Id 'RunTextSkillButton').Current.IsEnabled } -Message 'Example enables Summarize'
Select-Task -Name 'Rewrite'
Assert-UI -Condition { -not (Find-Control -Id 'RewriteToneBox').Current.IsOffscreen } -Message 'Rewrite shows tone'
Invoke-Control -Name 'Try an example'
Assert-UI -Condition { (Find-Control -Id 'RunTextSkillButton').Current.IsEnabled } -Message 'Rewrite has a valid selected tone'
Invoke-Control -Id 'RunTextSkillButton'
Wait-UI -Condition {
    (Find-Control -Id 'TextOperationBox').Current.IsEnabled -and
    (Find-Control -Id 'SkillResultStatus').Current.Name -eq 'Complete.'
}
Assert-UI -Condition { (Find-Control -Id 'SkillResultOutput').Current.Name.Length -gt 0 } -Message 'Rewrite runs with the selected tone and returns moderated text'
Select-Task -Name 'Rewrite with custom instruction'
Set-Text -Id 'CustomRewriteInstruction' -Text ''
Assert-UI -Condition { -not (Find-Control -Id 'RunTextSkillButton').Current.IsEnabled } -Message 'Custom rewrite requires instructions'
Invoke-Control -Name 'Try an example'
Assert-UI -Condition { (Find-Control -Id 'RunTextSkillButton').Current.IsEnabled } -Message 'Custom rewrite example fills instructions'
Select-Task -Name 'Summarize conversation'
Set-Text -Id 'TextSkillInput' -Text '{not-json}'
Assert-UI -Condition { -not (Find-Control -Id 'RunTextSkillButton').Current.IsEnabled } -Message 'Invalid conversation JSON disables inference'
Assert-UI -Condition {
    (Find-Control -Id 'SkillValidationMessage').Current.Name -eq 'Enter a valid JSON array. Try the example to see the format.'
} -Message 'Invalid conversation input explains why inference is disabled'
Invoke-Control -Name 'Try an example'
Assert-UI -Condition { (Find-Control -Id 'RunTextSkillButton').Current.IsEnabled } -Message 'Conversation example is valid'
Assert-UI -Condition {
    $message = Find-Control -Id 'SkillValidationMessage' -Optional
    -not $message -or [string]::IsNullOrEmpty($message.Current.Name)
} -Message 'Valid conversation input clears the validation message'
Set-Text -Id 'TextSkillInput' -Text '[{"participant":"Alex","message":""},{"participant":"","message":"Attachment only."}]'
Assert-UI -Condition { (Find-Control -Id 'RunTextSkillButton').Current.IsEnabled } -Message 'Attachment-only conversation items are accepted'
Invoke-Control -Id 'RunTextSkillButton'
Wait-UI -Condition {
    (Find-Control -Id 'TextOperationBox').Current.IsEnabled -and
    (Find-Control -Id 'SkillResultStatus').Current.Name -eq 'Nothing to summarize: each item needs both a participant and a message.'
}
Assert-UI -Condition { -not (Find-Control -Id 'CopySkillButton').Current.IsEnabled } -Message 'All-skipped conversation says there is nothing to summarize, with no copyable result'
Set-Text -Id 'TextSkillInput' -Text '[]'
Assert-UI -Condition { (Find-Control -Id 'RunTextSkillButton').Current.IsEnabled } -Message 'Empty conversation arrays are accepted'
Set-Text -Id 'TextSkillInput' -Text '[{"participant":"Alex","message":null}]'
Assert-UI -Condition { -not (Find-Control -Id 'RunTextSkillButton').Current.IsEnabled } -Message 'Null conversation fields remain invalid'
Set-Text -Id 'TextSkillInput' -Text '[{"participant":"Alex\nInjected","message":"Meeting tomorrow."}]'
Assert-UI -Condition { -not (Find-Control -Id 'RunTextSkillButton').Current.IsEnabled } -Message 'Multiline participants are rejected before inference'
Set-Text -Id 'TextSkillInput' -Text '[{"participant":"Alex","message":"Reference MessageId: abc"}]'
Assert-UI -Condition { -not (Find-Control -Id 'RunTextSkillButton').Current.IsEnabled } -Message 'Reserved framing is rejected before inference'
Select-Task -Name 'Convert text to table'
Assert-UI -Condition { (Find-Control -Id 'RunTextSkillButton').Current.Name -eq 'Create table' } -Message 'Table task has a task-named action'

(Find-Control -Name 'LoRA validation').GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
Add-Type -AssemblyName System.Windows.Forms
Set-Text -Id 'ComparisonPromptInput' -Text ' '
(Find-Control -Id 'ComparisonPromptInput').SetFocus()
[System.Windows.Forms.SendKeys]::SendWait('^{ENTER}')
Assert-UI -Condition { -not (Find-Control -Id 'BaseOnlyButton').Current.IsEnabled -and
    (Find-Control -Id 'LoadAdapterButton').Current.IsEnabled } -Message 'Whitespace Ctrl+Enter does not start inference or crash'
Set-Text -Id 'ComparisonPromptInput' -Text 'Say hello in one short sentence.'
Assert-UI -Condition { (Find-Control -Id 'BaseOnlyButton').Current.IsEnabled } -Message 'Base-only run needs a prompt, not a LoRA'
Assert-UI -Condition { -not (Find-Control -Id 'CompareButton').Current.IsEnabled } -Message 'Compare requires a loaded LoRA'
Assert-UI -Condition { -not (Find-Control -Id 'AdaptedOnlyButton').Current.IsEnabled } -Message 'Adapted run requires a loaded LoRA'
Invoke-Control -Id 'BaseOnlyButton'
Wait-UI -Condition {
    $status = Find-Control -Id 'BaseResultStatus' -Optional
    $status -and $status.Current.Name -eq 'Complete.'
}
Assert-UI -Condition { (Find-Control -Id 'BaseResultOutput').Current.Name.Length -gt 0 } -Message 'Base inference publishes a moderated result'
Assert-UI -Condition { (Find-Control -Id 'CopyBaseButton').Current.IsEnabled } -Message 'Base result can be copied'
Set-Text -Id 'ComparisonPromptInput' -Text 'A different prompt'
Assert-UI -Condition { $warning = Find-Control -Id 'ComparisonStaleWarning' -Optional
    $warning -and -not $warning.Current.IsOffscreen } -Message 'Editing the prompt marks previous results out of date'
if ($AdapterPath) {
    Load-TestAdapter -Path $AdapterPath
    $expectedName = [IO.Path]::GetFileName($AdapterPath)
    Assert-UI -Condition { (Find-Control -Id 'ActiveAdapterText').Current.Name -eq "Adapter: $expectedName" } `
        -Message 'LoRA validation identifies the loaded adapter'
    (Find-Control -Name 'Text intelligence').GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
    Select-Task -Name 'Rewrite with custom instruction'
    Invoke-Control -Name 'Try an example'
    Assert-UI -Condition { (Find-Control -Id 'RunTextSkillButton').Current.IsEnabled } `
        -Message 'A loaded developer LoRA does not disable custom rewrite'
    Invoke-Control -Id 'RunTextSkillButton'
    Wait-UI -Condition {
        (Find-Control -Id 'TextOperationBox').Current.IsEnabled -and
        (Find-Control -Id 'SkillResultStatus').Current.Name -eq 'Complete.'
    }
    $skillOutput = (Find-Control -Id 'SkillResultOutput').Current.Name
    Assert-UI -Condition { $skillOutput.Length -gt 0 } -Message 'TI runs successfully with built-in resources while a developer LoRA is loaded'
    (Find-Control -Name 'LoRA validation').GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
    Set-Text -Id 'ComparisonPromptInput' -Text 'Summarize this text: The public library reopened after renovations. It now has more reading rooms and study desks.'
    Assert-UI -Condition { (Find-Control -Id 'CompareButton').Current.IsEnabled } -Message 'Loaded adapter enables comparison'
    (Find-Control -Id 'ComparisonPromptInput').SetFocus()
    [System.Windows.Forms.SendKeys]::SendWait('^{ENTER}')
    Wait-UI -Condition {
        (Find-Control -Id 'LoadAdapterButton').Current.IsEnabled -and
        (Find-Control -Id 'BaseResultStatus').Current.Name -eq 'Complete.' -and
        (Find-Control -Id 'AdaptedResultStatus').Current.Name -eq 'Complete.'
    }
    Assert-UI -Condition { (Find-Control -Id 'BaseResultOutput').Current.Name.Length -gt 0 -and
        (Find-Control -Id 'AdaptedResultOutput').Current.Name.Length -gt 0 } -Message 'Compare preserves both moderated outputs'
    Assert-UI -Condition { (Find-Control -Id 'CopyBaseButton').Current.IsEnabled -and
        (Find-Control -Id 'CopyAdapterButton').Current.IsEnabled } -Message 'Comparison outputs can be copied independently'
    Assert-UI -Condition {
        (Find-Control -Id 'ComparisonPromptInput').GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value -eq
            'Summarize this text: The public library reopened after renovations. It now has more reading rooms and study desks.'
    } -Message 'Ctrl+Enter starts the comparison without inserting a newline'
    if ($RevalidationAdapterPath) {
        Load-TestAdapter -Path $RevalidationAdapterPath
        $expectedName = [IO.Path]::GetFileName($RevalidationAdapterPath)
        Assert-UI -Condition { (Find-Control -Id 'ActiveAdapterText').Current.Name -eq "Adapter: $expectedName" } `
            -Message 'Minor-version mismatch loads the new adapter rather than rejecting it'
        Assert-UI -Condition { [bool](Find-Control -Id 'AdapterCompatibilityWarning' -Optional) } `
            -Message 'Revalidation warning remains visible after a successful load'
        $details = Find-Control -Name 'Native compatibility details'
        $details.SetFocus()
        Assert-UI -Condition { $details.Current.HasKeyboardFocus } -Message 'Native warning details are keyboard focusable'
        $pattern = $null
        if ($details.TryGetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern, [ref]$pattern)) {
            $pattern.Expand()
        } else {
            $details.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
        }
        Assert-UI -Condition { (Find-Control -Id 'AdapterNativeDetails').Current.Name -like '*WarningAdapterRevalidationRecommended*' } `
            -Message 'Native warning details are readable without hovering'
        Assert-UI -Condition { (Find-Control -Id 'AdapterFeedbackText').Current.Name -like '*with a compatibility warning.*' } `
            -Message 'Successful load does not misrepresent a revalidation warning as fully validated'
        Assert-UI -Condition { (Find-Control -Id 'AdaptedOnlyButton').Current.IsEnabled } `
            -Message 'Accepted native warning does not disable LoRA inference'
    }
    $bounds = $window.Current.BoundingRectangle
    $transform = $window.GetCurrentPattern([System.Windows.Automation.TransformPattern]::Pattern)
    try {
        foreach ($width in 1000, 600) {
            $transform.Resize($width, 1000)
            Start-Sleep -Milliseconds 300
            $scroll = (Find-Control -Id 'LoRAView').GetCurrentPattern(
                [System.Windows.Automation.ScrollPattern]::Pattern)
            if ($scroll.Current.VerticallyScrollable) { $scroll.SetScrollPercent(-1, 100) }
            Start-Sleep -Milliseconds 300
            $baseBounds = (Find-Control -Id 'BaseResultStatus').Current.BoundingRectangle
            $adaptedBounds = (Find-Control -Id 'AdaptedResultStatus').Current.BoundingRectangle
            if ($width -eq 1000) {
                Assert-UI -Condition { [Math]::Abs($baseBounds.Y - $adaptedBounds.Y) -lt 2 } `
                    -Message 'Wide comparison renders results side by side'
            } else {
                Assert-UI -Condition { $adaptedBounds.Y -gt $baseBounds.Y } `
                    -Message 'Narrow comparison stacks its result panes'
                Assert-UI -Condition { (Find-Control -Id 'BaseOnlyButton').Current.BoundingRectangle.Y -gt
                    (Find-Control -Id 'CompareButton').Current.BoundingRectangle.Y } `
                    -Message 'Narrow comparison stacks its action buttons'
            }
        }
    } finally { $transform.Resize($bounds.Width, $bounds.Height) }
    if ($IncompatibleAdapterPath) {
        Load-TestAdapter -Path $IncompatibleAdapterPath
        Assert-UI -Condition { (Find-Control -Id 'AdapterFeedbackText').Current.Name -like "Replacement failed; still using $expectedName.*" } `
            -Message 'Failed replacement explicitly retains the previous adapter'
        Assert-UI -Condition {
            (Find-Control -Id 'AdapterFeedbackText').Current.Name -like '*AdapterIncompatibleRetrainRequired:*'
        } -Message 'Failed replacement preserves the SDK native compatibility reason'
        Assert-UI -Condition { (Find-Control -Id 'ActiveAdapterText').Current.Name -eq "Adapter: $expectedName" } `
            -Message 'Failed replacement preserves the active adapter'
        if ($RevalidationAdapterPath) {
            Assert-UI -Condition { [bool](Find-Control -Id 'AdapterCompatibilityWarning' -Optional) } `
                -Message 'Failed replacement retains the previous revalidation warning'
        }
        Assert-UI -Condition { -not (Find-Control -Id 'CopyBaseButton').Current.IsEnabled -and
            -not (Find-Control -Id 'CopyAdapterButton').Current.IsEnabled } -Message 'Adapter changes clear previous comparison results'
    }
    Set-Text -Id 'ComparisonPromptInput' -Text 'Write a detailed story about visiting a public library. Describe its reading rooms and study desks.'
    Invoke-Control -Id 'CompareButton'
    Wait-UI -Condition {
        $cancel = Find-Control -Id 'CancelComparisonButton' -Optional
        $cancel -and $cancel.Current.IsEnabled
    }
    Invoke-Control -Id 'CancelComparisonButton'
    Wait-UI -Condition { (Find-Control -Id 'LoadAdapterButton').Current.IsEnabled }
    Assert-UI -Condition { (Find-Control -Id 'BaseResultStatus').Current.Name -eq 'Cancelled.' -and
        (Find-Control -Id 'AdaptedResultStatus').Current.Name -eq 'Cancelled before starting.' } `
        -Message 'Cancel stops the active call and skips the remaining comparison call'
    Invoke-Control -Id 'UnloadAdapterButton'
    Assert-UI -Condition { (Find-Control -Id 'ActiveAdapterText').Current.Name -eq 'Adapter: No custom LoRA loaded' } `
        -Message 'Unload resets only the developer LoRA'
    Assert-UI -Condition { -not (Find-Control -Id 'CompareButton').Current.IsEnabled } -Message 'Unload disables adapted comparisons'
    Assert-UI -Condition { -not (Find-Control -Id 'AdapterCompatibilityWarning' -Optional) } -Message 'Unload clears the previous compatibility warning'
    Assert-UI -Condition { (Find-Control -Id 'LoadAdapterButton').Current.HasKeyboardFocus } -Message 'Unload restores keyboard focus'
    (Find-Control -Name 'Text intelligence').GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
    Assert-UI -Condition { (Find-Control -Id 'SkillResultOutput').Current.Name -eq $skillOutput } `
        -Message 'Replacing and unloading developer LoRAs preserve the TI result'
}
(Find-Control -Name 'Text intelligence').GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
Select-Task -Name 'Rewrite'
Set-Text -Id 'TextSkillInput' -Text ((1..30 | ForEach-Object {
    "On day $_, the library team organized a reading workshop, added study desks, and prepared a report for visitors."
}) -join ' ')
Invoke-Control -Id 'RunTextSkillButton'
Wait-UI -Condition {
    $cancel = Find-Control -Id 'CancelTextButton' -Optional
    $cancel -and $cancel.Current.IsEnabled
}
(Find-Control -Name 'LoRA validation').GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
(Find-Control -Name 'Compatibility and validation notes').SetFocus()
[System.Windows.Forms.SendKeys]::SendWait('{ESC}')
(Find-Control -Name 'Text intelligence').GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
Wait-UI -Condition { (Find-Control -Id 'TextOperationBox').Current.IsEnabled }
Assert-UI -Condition { (Find-Control -Id 'SkillResultStatus').Current.Name -eq 'Complete.' } `
    -Message 'Escape on LoRA validation allows the TI operation to complete'
(Find-Control -Id 'TextSkillInput').SetFocus()
[System.Windows.Forms.SendKeys]::SendWait('^{ENTER}')
Wait-UI -Condition {
    $cancel = Find-Control -Id 'CancelTextButton' -Optional
    $cancel -and $cancel.Current.IsEnabled
}
Assert-UI -Condition { (Find-Control -Id 'CancelTextButton').Current.HasKeyboardFocus } -Message 'Keyboard run moves focus to Cancel'
[System.Windows.Forms.SendKeys]::SendWait('{ESC}')
Wait-UI -Condition { (Find-Control -Id 'TextOperationBox').Current.IsEnabled }
Assert-UI -Condition { (Find-Control -Id 'SkillResultStatus').Current.Name -eq 'Cancelled.' } `
    -Message 'Ctrl+Enter runs and Escape cancels without publishing output'
Select-Task -Name 'Convert text to table'
Set-Text -Id 'TextSkillInput' -Text 'Alex is 30, lives in London, works as a teacher, earns 50000 dollars per year and owns a blue car. Robin is 40, lives in Paris, works as an engineer, earns 60000 dollars per year and owns a red car.'
Invoke-Control -Id 'RunTextSkillButton'
Wait-UI -Condition {
    (Find-Control -Id 'TextOperationBox').Current.IsEnabled -and
    (Find-Control -Id 'SkillResultStatus').Current.Name -eq 'Complete.'
}
Assert-UI -Condition { (Find-Control -Id 'CopySkillButton').Current.IsEnabled } -Message 'Structured table result is available for copying'
$tableScroll = (Find-Control -Id 'TableResultScroller').GetCurrentPattern([System.Windows.Automation.ScrollPattern]::Pattern)
Assert-UI -Condition { $tableScroll.Current.HorizontallyScrollable } -Message 'Wide table columns scroll instead of being clipped'
Select-Task -Name 'Summarize text'
Set-Text -Id 'TextSkillInput' -Text ''
Write-Output 'PASS: live task disclosure, request validation, comparison and adapter-state behavior.'
