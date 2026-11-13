function Initialize-OhMyRushellHighlighting {
    if (-not ('OhMyRushell.CommandHighlighting' -as [type])) {
        $source = Join-Path $PSScriptRoot 'CommandHighlighting.cs'
        $cacheRoot = if ($IsWindows) { [Environment]::GetFolderPath('LocalApplicationData') }
            elseif ($env:XDG_CACHE_HOME) { $env:XDG_CACHE_HOME }
            else { Join-Path $HOME '.cache' }
        $cacheDirectory = Join-Path $cacheRoot 'ohmyrushell/highlighting'
        $null = [IO.Directory]::CreateDirectory($cacheDirectory)
        $readLineAssembly = [Microsoft.PowerShell.PSConsoleReadLine].Assembly
        $automationAssembly = [Management.Automation.PSObject].Assembly
        $hashInput = [Text.Encoding]::UTF8.GetBytes("$([Environment]::Version.Major)`n$($readLineAssembly.GetName().Version)`n$($automationAssembly.GetName().Version)`n$([IO.File]::ReadAllText($source))")
        $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($hashInput))
        $assembly = Join-Path $cacheDirectory "$hash.dll"
        if (-not [IO.File]::Exists($assembly)) {
            $temporary = Join-Path $cacheDirectory "$([Guid]::NewGuid()).dll"
            try {
                $references = @($readLineAssembly.Location, $automationAssembly.Location) + @(
                    Get-ChildItem -LiteralPath (Join-Path $PSHOME 'ref') -Filter '*.dll' | Select-Object -ExpandProperty FullName
                )
                Add-Type -Path $source -ReferencedAssemblies $references -CompilerOptions '/nowarn:1701' -OutputAssembly $temporary -ErrorAction Stop
                try { [IO.File]::Move($temporary, $assembly) }
                catch [IO.IOException] { if (-not [IO.File]::Exists($assembly)) { throw } }
            } finally {
                if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
            }
        }
        Add-Type -LiteralPath $assembly -ErrorAction Stop
    }
    $script:HighlightingReady = $true
    Update-OhMyRushellCommandCache
    if ($Host.Name -eq 'ConsoleHost' -and $Host.UI.SupportsVirtualTerminal -and -not [Console]::IsInputRedirected -and -not [Console]::IsOutputRedirected) {
        $null = [OhMyRushell.CommandHighlighting]::InstallBindings()
    }
}

function Update-OhMyRushellCommandCache {
    [CmdletBinding()]
    param([switch] $SessionOnly)
    if (-not $script:HighlightingReady) { return }
    if (-not $SessionOnly) {
        # Discover exported module commands once, not on each key press.
        $available = @(Get-Command -CommandType Cmdlet,Function,Filter -All -ErrorAction SilentlyContinue)
        [OhMyRushell.CommandHighlighting]::SetAvailableCommands([Management.Automation.CommandInfo[]]$available)
        [OhMyRushell.CommandHighlighting]::InvalidatePathIndex()
    }
    $commands = @(Get-Command -CommandType Alias,Function,Filter,Cmdlet -ListImported)
    $directory = $ExecutionContext.SessionState.Path.CurrentFileSystemLocation.ProviderPath
    [OhMyRushell.CommandHighlighting]::UpdateSession([Management.Automation.CommandInfo[]]$commands, $directory, $env:PATH, $env:PATHEXT)
}

function Disable-OhMyRushellHighlighting {
    if ($script:HighlightingReady) { [OhMyRushell.CommandHighlighting]::RemoveBindings() }
    $script:HighlightingReady = $false
}
