# Runtime-specific names keep packaged bridges safe across PowerShell upgrades.
function Get-OhMyRushellAssemblyIdentity {
    param([switch] $ReadLine)
    $identity = "$([Environment]::Version.Major)"
    if ($ReadLine) {
        $identity += "-$([Microsoft.PowerShell.PSConsoleReadLine].Assembly.GetName().Version)-$([Management.Automation.PSObject].Assembly.GetName().Version)"
    }
    return $identity
}

# Shared by both bridges. No compiler or reference-assembly enumeration on a hit.
function Get-OhMyRushellAssembly {
    param([string[]] $Source, [string] $Kind, [switch] $ReadLine)
    $cacheRoot = if ($env:OHMYRUSHELL_CACHE_HOME) { $env:OHMYRUSHELL_CACHE_HOME }
        elseif ($IsWindows) { [Environment]::GetFolderPath('LocalApplicationData') }
        elseif ($env:XDG_CACHE_HOME) { $env:XDG_CACHE_HOME }
        else { "$HOME/.cache" }
    $identity = Get-OhMyRushellAssemblyIdentity -ReadLine:$ReadLine
    $packaged = "$PSScriptRoot/native/managed/$Kind-$identity.dll"
    if ([IO.File]::Exists($packaged)) { return $packaged }
    $contents = foreach ($file in $Source) { [IO.File]::ReadAllText($file) }
    $bytes = [Text.Encoding]::UTF8.GetBytes("$identity`n$($contents -join "`n")")
    $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))
    $directory = "$cacheRoot/ohmyrushell/$Kind"
    $assembly = "$directory/$hash.dll"
    if (-not [IO.File]::Exists($assembly)) {
        $null = [IO.Directory]::CreateDirectory($directory)
        $temporary = "$directory/$([Guid]::NewGuid()).dll"
        try {
            if ($ReadLine) {
                $readLineAssembly = [Microsoft.PowerShell.PSConsoleReadLine].Assembly
                $automationAssembly = [Management.Automation.PSObject].Assembly
                $references = @($readLineAssembly.Location, $automationAssembly.Location) + @(
                    [IO.Directory]::GetFiles("$PSHOME/ref", '*.dll')
                )
                Add-Type -Path $Source -ReferencedAssemblies $references -CompilerOptions '/nowarn:1701' -OutputAssembly $temporary -ErrorAction Stop
            } else {
                Add-Type -Path $Source -OutputAssembly $temporary -ErrorAction Stop
            }
            try { [IO.File]::Move($temporary, $assembly) }
            catch [IO.IOException] { if (-not [IO.File]::Exists($assembly)) { throw } }
        } finally {
            if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
        }
    }
    return $assembly
}
