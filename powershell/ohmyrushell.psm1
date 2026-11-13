#requires -Version 7.2

$script:Enabled = $false
$script:OriginalPrompt = $null
$script:PromptBlock = $null
. (Join-Path $PSScriptRoot 'AssemblyCache.ps1')
. "$PSScriptRoot/Listing.ps1"
. "$PSScriptRoot/CommandHighlighting.ps1"
$script:HighlightingReady = $false
# Load PSReadLine once. When present, one cached assembly provides both bridges.
$readLine = Get-Module PSReadLine
if (-not $readLine -and (Get-Module -ListAvailable PSReadLine)) {
    $readLine = Import-Module PSReadLine -PassThru -ErrorAction Stop
}

$libraryName = if ($IsWindows) { 'ohmyrushell_core.dll' } elseif ($IsMacOS) { 'libohmyrushell_core.dylib' } else { 'libohmyrushell_core.so' }
$nativePath = [IO.Path]::GetFullPath("$PSScriptRoot/native/$libraryName")
if (-not [IO.File]::Exists($nativePath)) {
    $nativePath = [IO.Path]::GetFullPath("$PSScriptRoot/../target/release/$libraryName")
}
if (-not [IO.File]::Exists($nativePath)) {
    throw 'ohmyrushell: biblioteca Rust ausente. Execute ./install.ps1 ou cargo build --release.'
}

if (-not ('OhMyRushell.Native' -as [type])) {
    $bridgePath = if ($readLine) {
        Get-OhMyRushellAssembly -Source @("$PSScriptRoot/Native.cs", "$PSScriptRoot/CommandHighlighting.cs") -Kind integration -ReadLine
    } else {
        Get-OhMyRushellAssembly -Source "$PSScriptRoot/Native.cs" -Kind bridge
    }
    Add-Type -LiteralPath $bridgePath -ErrorAction Stop
} elseif (-not [OhMyRushell.Native].GetMethod('Initialize')) {
    throw 'Uma ponte ohmyrushell antiga esta carregada. Abra uma nova sessao para atualizar.'
} elseif ([OhMyRushell.Native]::LibraryPath -and [OhMyRushell.Native]::LibraryPath -ne $nativePath) {
    throw 'ohmyrushell ja foi carregado de outra pasta. Abra uma nova sessao para trocar a biblioteca.'
}

[OhMyRushell.Native]::Initialize($nativePath)

function Enable-OhMyRushell {
    [CmdletBinding()]
    param()
    if ($script:Enabled) { return }

    $script:OriginalPrompt = ${function:prompt}
    if ($readLine) { Initialize-OhMyRushellHighlighting }

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
    $script:PromptBlock = ${function:prompt}
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
    if (${function:prompt} -eq $script:PromptBlock) {
        if ($script:OriginalPrompt) {
            Set-Item Function:\global:prompt -Value $script:OriginalPrompt
        } else {
            Remove-Item Function:\global:prompt -ErrorAction SilentlyContinue
        }
    }
    $script:Enabled = $false
}

$ExecutionContext.SessionState.Module.OnRemove = { Disable-OhMyRushell }
Enable-OhMyRushell
Export-ModuleMember -Function Enable-OhMyRushell, Disable-OhMyRushell, Get-OhMyRushellChildItem, Update-OhMyRushellCommandCache
