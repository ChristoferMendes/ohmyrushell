# Shell-only formatting: reuse Get-ChildItem, without starting another process.
function Get-OhMyRushellChildItem {
    # Deliberately not an advanced function: Unix flags (-lah, --color) must
    # arrive unchanged instead of going through PowerShell parameter binding.
    $showAll = $false
    $long = $false
    $human = $false
    $redirected = [Console]::IsOutputRedirected -or ($MyInvocation.PipelinePosition -lt $MyInvocation.PipelineLength)
    $columns = -not $redirected
    $colorMode = 'auto'
    $width = 80
    try {
        $terminalWidth = $Host.UI.RawUI.WindowSize.Width
        if ($terminalWidth -gt 0) { $width = $terminalWidth }
    } catch { }
    $paths = [Collections.Generic.List[string]]::new()
    $options = $true

    foreach ($argument in $args) {
        $argument = [string]$argument
        if ($options -and $argument -eq '--') { $options = $false; continue }
        if ($options -and $argument -eq '--help') {
            return @'
ls [opcoes] [caminho...]
  -a, --all              Inclui arquivos ocultos e nomes iniciados por ponto
  -l                    Lista detalhada: modo, tamanho, data local e nome
  -h, --human-readable   Tamanhos em KiB/MiB/GiB (com -l)
  -1                    Um nome por linha
  -C                    Forca colunas, inclusive em pipes
  --color=auto|always|never
  --width=N             Largura das colunas
  '--'                  Encerra opcoes (aspas necessarias no PowerShell)
Exemplos: ls; ls -lah; ls -l ./src; ls *.rs
Para objetos PowerShell e parametros nativos: Get-ChildItem (ou gci).
'@
        }
        if ($options -and $argument -eq '--all') { $showAll = $true; continue }
        if ($options -and $argument -eq '--human-readable') { $human = $true; continue }
        if ($options -and $argument.StartsWith('--color=')) {
            $colorMode = $argument.Substring(8)
            if ($colorMode -notin @('auto', 'always', 'never')) { throw 'ls: --color deve ser auto, always ou never.' }
            continue
        }
        if ($options -and $argument.StartsWith('--width=')) {
            $parsed = 0
            if (-not [int]::TryParse($argument.Substring(8), [ref]$parsed) -or $parsed -lt 1 -or $parsed -gt 10000) {
                throw 'ls: --width deve ser um inteiro entre 1 e 10000.'
            }
            $width = $parsed
            continue
        }
        if ($options -and $argument.StartsWith('-') -and $argument -ne '-') {
            foreach ($flag in $argument.Substring(1).ToCharArray()) {
                switch -CaseSensitive ($flag) {
                    'a' { $showAll = $true }
                    'l' { $long = $true }
                    'h' { $human = $true }
                    '1' { $columns = $false }
                    'C' { $columns = $true }
                    default { throw "ls: opcao desconhecida '$argument'. Use ls --help ou Get-ChildItem para parametros PowerShell." }
                }
            }
            continue
        }
        $paths.Add($argument)
    }
    if ($paths.Count -eq 0) { $paths.Add('.') }
    $color = $colorMode -eq 'always' -or ($colorMode -eq 'auto' -and -not $redirected -and $Host.UI.SupportsVirtualTerminal -and -not (Test-Path Env:\NO_COLOR))

    for ($pathIndex = 0; $pathIndex -lt $paths.Count; $pathIndex++) {
        $path = $paths[$pathIndex]
        # Explicit filesystem check avoids silently formatting Registry/provider objects.
        $provider = $null
        $drive = $null
        $null = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($path, [ref]$provider, [ref]$drive)
        if ($provider.Name -ne 'FileSystem') { throw 'ls: apenas caminhos de arquivos. Use Get-ChildItem para outros providers.' }
        $explicitFile = Test-Path -LiteralPath $path -PathType Leaf
        $items = @(Get-ChildItem -Path $path -Force:($showAll -or $explicitFile) -ErrorAction Stop |
            Where-Object { $showAll -or $explicitFile -or -not $_.Name.StartsWith('.') } |
            Sort-Object -Property @{ Expression = { -not $_.PSIsContainer } }, Name)
        if ($paths.Count -gt 1) {
            if ($pathIndex -gt 0) { '' }
            "$(ConvertTo-OhMyRushellSafeName $path):"
        }
        if ($items.Count -eq 0) { continue }

        $entries = @(
            foreach ($item in $items) {
                $link = ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
                $name = ConvertTo-OhMyRushellSafeName $item.Name
                if ($item.PSIsContainer) { $name += '/' }
                $tone = if ($link) { "`e[38;2;137;220;235m" }
                    elseif ($item.PSIsContainer) { "`e[38;2;137;180;250m" }
                    elseif ($item.Extension -in @('.exe', '.com', '.cmd', '.bat', '.ps1', '.sh')) { "`e[38;2;166;227;161m" }
                    elseif ($item.Extension -in @('.zip', '.7z', '.tar', '.gz', '.xz', '.rar')) { "`e[38;2;203;166;247m" }
                    else { '' }
                if ($long -and $link -and $item.LinkTarget) {
                    $name += ' -> ' + (ConvertTo-OhMyRushellSafeName $item.LinkTarget)
                }
                $display = if ($color -and $tone) { "$tone$name`e[0m" } else { $name }
                $cells = $name.Length
                try { $cells = $Host.UI.RawUI.LengthInBufferCells($name) } catch { }
                $size = if ($item.PSIsContainer) { '-' }
                    elseif ($human) { ConvertTo-OhMyRushellFileSize $item.Length }
                    else { [string]$item.Length }
                [pscustomobject]@{
                    Item = $item; Display = $display; Cells = $cells; Size = $size
                }
            }
        )
        if ($long) {
            $sizeWidth = ($entries | ForEach-Object { $_.Size.Length } | Measure-Object -Maximum).Maximum
            foreach ($entry in $entries) {
                # Mode is PowerShell's real platform mode, not simulated POSIX permissions.
                '{0} {1} {2}  {3}' -f $entry.Item.Mode, $entry.Size.PadLeft($sizeWidth),
                    $entry.Item.LastWriteTime.ToString('yyyy-MM-dd HH:mm'), $entry.Display
            }
        } elseif (-not $columns) {
            foreach ($entry in $entries) { $entry.Display }
        } else {
            $cellWidth = [int]($entries | Measure-Object -Property Cells -Maximum).Maximum + 2
            $columnCount = [Math]::Max(1, [Math]::Min($entries.Count, [Math]::Floor(($width + 2) / $cellWidth)))
            $rowCount = [int][Math]::Ceiling($entries.Count / $columnCount)
            for ($row = 0; $row -lt $rowCount; $row++) {
                $line = [Text.StringBuilder]::new()
                for ($column = 0; $column -lt $columnCount; $column++) {
                    $index = $column * $rowCount + $row
                    if ($index -ge $entries.Count) { break }
                    $entry = $entries[$index]
                    $null = $line.Append($entry.Display)
                    if ($index + $rowCount -lt $entries.Count) {
                        $null = $line.Append(' ' * ($cellWidth - $entry.Cells))
                    }
                }
                $line.ToString()
            }
        }
    }
}

function ConvertTo-OhMyRushellSafeName([string] $Name) {
    [regex]::Replace($Name, '[\p{Cc}\u202a-\u202e\u2066-\u2069]', '?')
}

function ConvertTo-OhMyRushellFileSize([long] $Size) {
    $units = @('B', 'KiB', 'MiB', 'GiB', 'TiB', 'PiB', 'EiB')
    $unit = 0
    $value = [double]$Size
    while ($value -ge 1024 -and $unit -lt $units.Length - 1) {
        $value /= 1024
        $unit++
    }
    if ($unit -eq 0) { return "${Size}B" }
    return $value.ToString('0.#', [Globalization.CultureInfo]::InvariantCulture) + $units[$unit]
}

function Enable-OhMyRushellListing {
    $previous = Get-Alias ls -ErrorAction SilentlyContinue
    $script:OriginalLsAlias = if ($previous) {
        [pscustomobject]@{ Definition = $previous.Definition; Options = $previous.Options }
    } else { $null }
    Set-Alias -Name ls -Value Get-OhMyRushellChildItem -Scope Global -Force -ErrorAction Stop
}

function Disable-OhMyRushellListing {
    $alias = Get-Alias ls -ErrorAction SilentlyContinue
    if ($alias -and $alias.Definition -eq 'Get-OhMyRushellChildItem') {
        if ($script:OriginalLsAlias) {
            # A detached closure prevents Remove-Module from removing the
            # restored alias as if it still belonged to ohmyrushell.
            $restore = {
                param($definition, $options)
                Set-Alias -Name ls -Value $definition -Option $options -Scope Global -Force
            }.GetNewClosure()
            & $restore $script:OriginalLsAlias.Definition $script:OriginalLsAlias.Options
        } else {
            Remove-Alias -Name ls -Scope Global -Force
        }
    }
}
