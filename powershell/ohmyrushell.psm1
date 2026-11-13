#requires -Version 7.2

$script:Enabled = $false
$script:OriginalPrompt = $null
$script:OriginalColors = @{}
$script:PromptBlock = $null
. (Join-Path $PSScriptRoot 'Listing.ps1')
. (Join-Path $PSScriptRoot 'CommandHighlighting.ps1')
$script:HighlightingReady = $false

$libraryName = if ($IsWindows) { 'ohmyrushell_core.dll' } elseif ($IsMacOS) { 'libohmyrushell_core.dylib' } else { 'libohmyrushell_core.so' }
$nativePath = Join-Path $PSScriptRoot "native/$libraryName"
if (-not (Test-Path -LiteralPath $nativePath)) {
    $nativePath = Join-Path (Split-Path $PSScriptRoot -Parent) "target/release/$libraryName"
}
if (-not (Test-Path -LiteralPath $nativePath)) {
    throw 'ohmyrushell: biblioteca Rust ausente. Execute ./install.ps1 ou cargo build --release.'
}
$nativePath = (Resolve-Path -LiteralPath $nativePath).ProviderPath

if (-not ('OhMyRushell.Native' -as [type])) {
    $escapedPath = $nativePath.Replace('"', '""')
    $bridgeSource = @"
using System;
using System.Runtime.InteropServices;
using System.Text;

namespace OhMyRushell {
    public static class Native {
        public const string LibraryPath = @"$escapedPath";
        [ThreadStatic] private static byte[] buffer;

        [DllImport(LibraryPath, EntryPoint = "ohmyrushell_render", CallingConvention = CallingConvention.Cdecl)]
        private static extern UIntPtr RenderNative(
            [In] byte[] path, UIntPtr pathLength, int success,
            [Out] byte[] output, UIntPtr capacity);

        [DllImport(LibraryPath, EntryPoint = "ohmyrushell_revision", CallingConvention = CallingConvention.Cdecl)]
        public static extern ulong Revision();

        public static string Render(string path, bool success) {
            return Render(path, success, true);
        }

        public static string Render(string path, bool success, bool refresh) {
            byte[] input = Encoding.UTF8.GetBytes(path);
            if (buffer == null) buffer = new byte[4096];
            for (int attempt = 0; attempt < 3; attempt++) {
                ulong size = RenderNative(input, (UIntPtr)input.Length, (success ? 1 : 0) | (refresh && attempt == 0 ? 0 : 2),
                    buffer, (UIntPtr)buffer.Length).ToUInt64();
                if (size == 0 || size > 1048576) throw new InvalidOperationException("Native rendering failed.");
                if (size <= (ulong)buffer.Length) return Encoding.UTF8.GetString(buffer, 0, (int)size);
                buffer = new byte[checked((int)size + 4096)];
            }
            throw new InvalidOperationException("Native prompt exceeds its buffer.");
        }
    }
}
"@
    # Compile once per source/native path/.NET runtime, not once per shell.
    $cacheRoot = if ($IsWindows) {
        [Environment]::GetFolderPath('LocalApplicationData')
    } elseif ($env:XDG_CACHE_HOME) {
        $env:XDG_CACHE_HOME
    } else {
        Join-Path $HOME '.cache'
    }
    $cacheDirectory = Join-Path $cacheRoot 'ohmyrushell/bridge'
    $null = [IO.Directory]::CreateDirectory($cacheDirectory)
    $hashInput = [Text.Encoding]::UTF8.GetBytes("$([Environment]::Version.Major)`n$bridgeSource")
    $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($hashInput))
    $bridgePath = Join-Path $cacheDirectory "$hash.dll"
    if (-not [IO.File]::Exists($bridgePath)) {
        $temporary = Join-Path $cacheDirectory "$([Guid]::NewGuid()).dll"
        try {
            Add-Type -TypeDefinition $bridgeSource -OutputAssembly $temporary -ErrorAction Stop
            try {
                [IO.File]::Move($temporary, $bridgePath)
            } catch [IO.IOException] {
                # A second shell may have published the same assembly first.
                if (-not [IO.File]::Exists($bridgePath)) { throw }
            }
        } finally {
            if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
        }
    }
    Add-Type -LiteralPath $bridgePath -ErrorAction Stop
} elseif (-not [OhMyRushell.Native].GetMethod('Revision')) {
    throw 'Uma ponte ohmyrushell antiga esta carregada. Abra uma nova sessao para atualizar.'
} elseif ([OhMyRushell.Native]::LibraryPath -ne $nativePath) {
    throw 'ohmyrushell ja foi carregado de outra pasta. Abra uma nova sessao para trocar a biblioteca.'
}

function Enable-OhMyRushell {
    [CmdletBinding()]
    param()
    if ($script:Enabled) { return }

    $script:OriginalPrompt = (Get-Item Function:\prompt -ErrorAction SilentlyContinue).ScriptBlock
    if ((Get-Module PSReadLine) -or (Get-Module -ListAvailable PSReadLine)) {
        Import-Module PSReadLine -ErrorAction Stop
        $options = Get-PSReadLineOption
        $properties = @{
            Command = 'CommandColor'; Parameter = 'ParameterColor'; String = 'StringColor'
            Variable = 'VariableColor'; Number = 'NumberColor'; Operator = 'OperatorColor'
            Comment = 'CommentColor'; Keyword = 'KeywordColor'; Error = 'ErrorColor'
            ContinuationPrompt = 'ContinuationPromptColor'
        }
        foreach ($entry in $properties.GetEnumerator()) {
            $script:OriginalColors[$entry.Key] = $options.($entry.Value)
        }
        # A neutral baseline never claims that an unresolved name is valid.
        # The lightweight C# highlighter repaints only resolved command spans.
        Set-PSReadLineOption -Colors @{
            Command = '#cdd6f4'; Parameter = '#89b4fa'; String = '#f9e2af'
            Variable = '#cba6f7'; Number = '#fab387'; Operator = '#89dceb'
            Comment = '#6c7086'; Keyword = '#cba6f7'; Error = '#f38ba8'
            ContinuationPrompt = '#6c7086'
        }
        try { Initialize-OhMyRushellHighlighting }
        catch {
            Set-PSReadLineOption -Colors $script:OriginalColors
            throw
        }
    }

    function global:prompt {
        # Capture $? BEFORE running any other expression.
        $lastCommandSucceeded = $?
        $savedExitCode = $global:LASTEXITCODE
        try {
            Update-OhMyRushellCommandCache -SessionOnly
            if ($PWD.Provider.Name -eq 'FileSystem') {
                # Render exactly once with fresh in-process libgit2 status.
                # No worker, process startup, loading placeholder or idle redraw.
                return [OhMyRushell.Native]::Render($PWD.ProviderPath, $lastCommandSucceeded)
            }
            return "$($PWD.Path)`n❯ "
        } catch {
            return "PS $($PWD.Path)> "
        } finally {
            $global:LASTEXITCODE = $savedExitCode
        }
    }
    $script:PromptBlock = (Get-Item Function:\prompt).ScriptBlock
    Enable-OhMyRushellListing
    $script:Enabled = $true
}

function Disable-OhMyRushell {
    [CmdletBinding()]
    param()
    if (-not $script:Enabled) { return }
    Disable-OhMyRushellHighlighting
    Disable-OhMyRushellListing
    # Do not overwrite a different prompt installed after ours.
    if ((Get-Item Function:\prompt -ErrorAction SilentlyContinue).ScriptBlock -eq $script:PromptBlock) {
        if ($script:OriginalPrompt) {
            Set-Item Function:\global:prompt -Value $script:OriginalPrompt
        } else {
            Remove-Item Function:\global:prompt -ErrorAction SilentlyContinue
        }
    }
    if ($script:OriginalColors.Count -gt 0 -and (Get-Module PSReadLine)) {
        Set-PSReadLineOption -Colors $script:OriginalColors
    }
    $script:OriginalColors = @{}
    $script:Enabled = $false
}

$ExecutionContext.SessionState.Module.OnRemove = { Disable-OhMyRushell }
Enable-OhMyRushell
Export-ModuleMember -Function Enable-OhMyRushell, Disable-OhMyRushell, Get-OhMyRushellChildItem, Update-OhMyRushellCommandCache
