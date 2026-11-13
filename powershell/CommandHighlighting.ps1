function Initialize-OhMyRushellHighlighting {
    if (-not ('OhMyRushell.CommandHighlighting' -as [type])) {
        $assembly = Get-OhMyRushellAssembly -Source "$PSScriptRoot/CommandHighlighting.cs" -Kind highlighting -ReadLine
        Add-Type -LiteralPath $assembly -ErrorAction Stop
    }
    [OhMyRushell.CommandHighlighting]::EnableColors()
    $script:HighlightingReady = $true
    try {
        [OhMyRushell.CommandHighlighting]::StartAvailableDiscovery()
        Update-OhMyRushellCommandCache -SessionOnly
        if ($Host.Name -eq 'ConsoleHost' -and $Host.UI.SupportsVirtualTerminal -and -not [Console]::IsInputRedirected -and -not [Console]::IsOutputRedirected) {
            $null = [OhMyRushell.CommandHighlighting]::InstallBindings()
        }
    } catch {
        Disable-OhMyRushellHighlighting
        throw
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
    [OhMyRushell.CommandHighlighting]::UpdateSession($ExecutionContext)
}

function Disable-OhMyRushellHighlighting {
    if ($script:HighlightingReady) {
        [OhMyRushell.CommandHighlighting]::RemoveBindings()
        [OhMyRushell.CommandHighlighting]::RestoreColors()
    }
    $script:HighlightingReady = $false
}
