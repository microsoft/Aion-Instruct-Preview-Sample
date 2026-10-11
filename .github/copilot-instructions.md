# Copilot instructions — Aion Instruct Preview Chat sample

You are working in the **consumer sample** for the **Aion Instruct Preview SDK**: an on-device
language model that runs locally on the Copilot+ PC NPU — catalog QNN on Snapdragon (ARM64),
catalog OpenVINO on Intel (x64), with AMD support coming soon. A compatible NPU is required (no
CPU fallback, no cloud calls).
This repo shows a
third-party developer how to (1) consume the SDK's framework package, (2) wire it into their own
app, and (3) build + run a working chat app. Use this file to orient fast; the
[`README.md`](../README.md) has the deep dives and is the source of truth — cross-references below
point at its sections.

## What this repo contains

Three consumption patterns of the **same** SDK, so a developer can copy whichever matches their app:

| Path | Project | Identity model | Framework dependency taken |
| --- | --- | --- | --- |
| **Packaged WinUI 3** (canonical) | `AionInstructPreview.Chat.csproj` (repo root) | MSIX package identity | **Build-time**: SDK targets inject a `<PackageDependency>` into `Package.appxmanifest` |
| **Unpackaged console** | `unpackaged-console/AionInstructPreview.Chat.Console.csproj` | none (plain exe) | **Runtime**: `FrameworkDependency.cs` via `TryCreatePackageDependency` / `AddPackageDependency` |
| **Unpackaged WPF** | `unpackaged-wpf/AionInstructPreview.Chat.Wpf.csproj` | none (plain exe) | **Runtime**: same dynamic-dependency pattern as console |

The root WinUI app is the one most consumers should copy. The unpackaged variants exist for apps
that can't adopt MSIX identity; they take the same framework dependency at runtime instead of via a
manifest.

## The mental model (read this before changing build wiring)

There are **two distinct things** with similar names; never conflate them:

1. **The SDK NuGet — `AionInstructPreview.Text.Framework`** (a `PackageReference`). This is
   **build-time only**. Its build hooks:
   - `AionInstructPreview.Text.Framework.props` adds `AionInstructPreview.Text.winmd` to
     `$(CsWinRTInputs)` so **CsWinRT** projects the WinRT runtimeclasses into C# types you can call.
   - `AionInstructPreview.Text.Framework.targets` injects the runtime `<PackageDependency>` into a
     packaged app's `AppxManifest` (no-ops for unpackaged apps, which have no manifest).
2. **The framework MSIX — `Microsoft.AionInstructPreview.Framework.1.0`** (installed system-wide).
   This is the **runtime** that actually holds `AionInstructPreview.Text.dll`, `muffinapi.dll`, and
   the ONNX model files. It is **not on any public feed** — it ships only as a **GitHub release
   asset** of this repo (by design; this is a developer preview). `Bootstrap.ps1` downloads and
   installs it.

A build error almost never means a *runtime* component is missing, and vice-versa. See
README → [Prerequisites](../README.md#prerequisites).

## Build & run the sample

**Prereqs:** .NET 9 SDK + **Developer Mode** on. That's it — **no Visual Studio and no
registry-installed Windows SDK are required**; everything else (Windows App SDK, CsWinRT, SDK build
tools, the Windows metadata ref pack, MSIX loose-layout tooling) is restored from NuGet.

**One-shot quickstart** (downloads and installs the framework MSIX from this repo's public GitHub
release, drops the SDK NuGet into `./nuget-local/`, then builds and launches):

```powershell
./Bootstrap.ps1
```

**Manual build + run** (packaged WinUI app). Builds for **ARM64** (Snapdragon/QNN) and **x64**
(Intel/OpenVINO; AMD support is coming soon) — `-p:Platform=ARM64` or `-p:Platform=x64`. The csproj defaults `$(Platform)` to
the box's *native* arch, normalising `AMD64` to `x64`, so a bare `dotnet build` does the right thing.

```powershell
dotnet run --project AionInstructPreview.Chat.csproj --launch-profile "AionInstructPreview.Chat" -c Release -p:Platform=ARM64   # Snapdragon (QNN NPU)
```

`dotnet run` registers the build output as a **loose-layout development package** (this is what
gives the app the package identity it needs for cross-package WinRT activation) and launches it —
no signing cert, no separate `Add-AppxPackage`. Developer Mode is required for that registration.

**Unpackaged variants:** `cd unpackaged-console` (or `unpackaged-wpf`) then `./Run.ps1` — it checks
the framework package is installed, builds, and runs. These have no MSIX identity and pull the
framework dependency at runtime.

**Visual Studio:** the F5 path is supported on **Visual Studio 2026 (18.x) only**, with the
**(MSIX)** launch profile (never the `Project` profile — that runs the bare exe without identity and
crashes with `REGDB_E_CLASSNOTREG`). VS 2022 (17.x) cannot F5 this Windows App SDK 2.0 app. Select the
**Solution Platform set to ARM64** — a non-ARM64 platform makes F5 report
*"The project needs to be deployed. Please enable Deploy in the Configuration Manager"* even though
Deploy is enabled. Exact required VS 2026 components are in
README → [Visual Studio 2026 setup](../README.md#visual-studio-2026-setup).

## Consume the SDK in your OWN app

Minimum wiring to call the model from a new project (full guide:
README → [Use Aion Instruct Preview in your own app](../README.md#use-aion-instruct-preview-in-your-own-app)):

1. **Feed:** copy this repo's [`nuget.config`](../nuget.config) — it adds `./nuget-local/` where the
   SDK `.nupkg` lives until a public feed exists. Drop
   `AionInstructPreview.Text.Framework.<version>.nupkg` there.
2. **PackageReferences** (CsWinRT is **mandatory and must be referenced directly** — picking it up
   transitively does NOT import its source-generator targets, and you'll get a wall of
   `CS0246 LanguageModel not found`):
   ```xml
   <PackageReference Include="AionInstructPreview.Text.Framework" Version="[1.0.1]" />
   <PackageReference Include="Microsoft.Windows.CsWinRT" Version="2.1.5" />
   ```
   Pin the SDK with the exact range `[1.0.1]` — the local feed is hand-populated, so `1.0.*`
   silently resolves to whatever `.nupkg` is present. This sample requires **1.0.1** for the updated text
   contract and includes `AionInstructPreview.Imaging.winmd`.
   A **packaged** app additionally needs `Microsoft.WindowsAppSDK`, `Microsoft.Windows.SDK.BuildTools`,
   and (for `dotnet run` without VS) `Microsoft.Windows.SDK.BuildTools.WinApp` — see the root
   [`AionInstructPreview.Chat.csproj`](../AionInstructPreview.Chat.csproj) for the exact set and the
   comments explaining each.
3. **Identity:**
   - *Packaged:* nothing extra — the SDK `.targets` inject the framework `<PackageDependency>` into
     your `AppxManifest` automatically at build.
   - *Unpackaged:* copy [`unpackaged-console/FrameworkDependency.cs`](../unpackaged-console/FrameworkDependency.cs)
     and call `FrameworkDependency.EnsureLoaded()` **once at startup, before** the first
     `LanguageModel.CreateAsync()`.
4. **Runtime, on the end-user machine:** the framework MSIX installed (GitHub release),
   WindowsAppRuntime 2, and the .NET 9 desktop runtime.

## The API (what the SDK actually exposes)

Namespace `AionInstructPreview.Text`. Canonical usage lives in
[`AionInstructClient.cs`](../AionInstructClient.cs). Shape:

```csharp
using AionInstructPreview.Text;

LanguageModel model = await LanguageModel.CreateAsync();   // cold NPU compilation may take several minutes
LanguageModelContext ctx = model.CreateContext();          // carries multi-turn history

// Preserve the sample's previous sampling settings.
var options = new LanguageModelOptions { Temperature = 0.5f, TopP = 0.9f, TopK = 40 };
var op = model.GenerateResponseAsync(ctx, prompt, options);
op.Progress = (_, delta) => { /* streamed text chunk — marshal to UI thread yourself */ };
LanguageModelResponseResult result = await op;
```

- **SDK 1.0.1 contract:** multi-turn generation requires the third
  `AionInstructPreview.Text.LanguageModelOptions` argument; `null` is rejected.
  Single-shot generation supports `(prompt)` and `(prompt, options)`. Options expose only
  `Temperature`, `TopP`, `TopK`, and `ContentFilterOptions` (no LoRA).
  New options default to `0.9f`, `0.9f`, and `40`; the sample explicitly uses temperature `0.5f`
  to preserve its previous behavior. The prompt-only overload also retains `0.5f`.
  `ContentFilterOptions` is constructed by default and enables moderation in the moderation
  follow-up. That follow-up requires matching rebuilt SDK metadata and runtime; do not infer
  moderation support from the previously published package versions or invent a release version.
  Rebuild consumers with NuGet **1.0.1** and framework **1.0.0.3**; this breaking preview contract
  change does not promise compatibility with previously built consumer binaries.
- **No preview-only diagnostics:** results expose `Text` and `Status`, not `TokenCount`,
  `TimeToFirstToken`, or `DecodeDuration`. The model no longer exposes `GetTokenCount`,
  `MaxPromptTokenCount`, or `ContextLength`. Keep measurements in the app using `Stopwatch`
  and progress callbacks. Report callback counts/rates as **updates**, not tokenizer tokens;
  both chat and image description use `GenerationMetrics`.
- **First `CreateAsync()` per process is slow** (~4-5 min cold while QNN compiles the QDQ ONNX to the
  NPU; ~30s warm from cache). Keep loading UI up; never assume it's hung.
- **Multi-turn is automatic** via the `LanguageModelContext` — reuse it; call `CreateContext()` again
  to start a fresh conversation.
- `Progress` callbacks fire on a WinRT-chosen thread — the caller marshals back to the UI thread.
- **Moderation:** TCM, ICM, and inbox blocklists filter by default. Preserve accepted partial text
  during progress, but clear the current response on any terminal block/error and guard queued UI
  callbacks so they cannot append after completion. Only display final result text on `Complete`.
  The console cannot retract printed text: explicitly report that a failed stream has no final
  response. Accepted updates do not guarantee later checks or unchanged conversation state.
  Missing/null filter options and nested severities default to `Low`; they do not disable filtering.
  Missing/failed moderation or blocklist payloads fail the operation. Do not promise `High` severity
  support, an off switch, or RAI qualification.
- Distinguish text prompt/response blocks and image/image-text/description blocks from operational
  failures. Never display or log raw exception messages that could contain rejected content.
  Catch `CreateContext(systemPrompt)` rejection (`0x8A1F0202`) on first send and explicit reset.
  Retain the existing context after a blocked turn; do not automatically start a new conversation.
  User-typed input and thumbnails may remain visible but do not imply moderation approval.
  See README → [Content moderation](../README.md#content-moderation); do not claim RAI qualification.
- Dispose `LanguageModelContext` then `LanguageModel` (`IClosable` projects to `IDisposable`).

API reference: README → [API surface used](../README.md#api-surface-used).

## Hard rules / gotchas (do not violate)

- **Snapdragon/QNN and Intel LNL/OpenVINO are supported; AMD support is coming soon.** The csproj defaults `$(Platform)`
  to the box's native arch and normalises `AMD64` to `x64` — don't break that logic.
- **Never build under `C:\Windows\System32`** (the default dir of an elevated prompt). UAC file
  virtualization corrupts CsWinRT / XAML codegen (`cswinrt.exe exited with code 1`). Build
  non-elevated from your user profile.
- **CsWinRT must be a direct `PackageReference`** (see above).
- **For VS F5 pick the `(MSIX)` profile, not `Project`.** The `Project` profile → `REGDB_E_CLASSNOTREG`.
- **The framework MSIX is GitHub-release-only — by design.** Do not add it to a NuGet/public feed or
  suggest distributing it; it's a developer preview, not for redistribution.
- **Don't add MSIX signing/`.pfx`/packaging knobs** to the sample. The dev loop is `dotnet run`
  (loose-layout dev registration); a signing cert is intentionally not used.
- **Stay on a feature branch** for changes; open PRs against the repo's default branch.

## Where to look

- [`README.md`](../README.md) — authoritative; prereqs, quickstart, per-pattern integration,
  troubleshooting, API reference, project layout.
- [`AionInstructPreview.Chat.csproj`](../AionInstructPreview.Chat.csproj) — heavily commented;
  explains every non-obvious build property.
- [`AionInstructClient.cs`](../AionInstructClient.cs) — the clean API-usage example.
- [`unpackaged-console/FrameworkDependency.cs`](../unpackaged-console/FrameworkDependency.cs) — the
  runtime framework-dependency pattern for unpackaged apps.
- [`Bootstrap.ps1`](../Bootstrap.ps1) — end-to-end setup; mirrors the manual steps in the README.
- [`TRANSPARENCY_NOTES.md`](../TRANSPARENCY_NOTES.md) — model capabilities, limitations, responsible-AI guidance.
