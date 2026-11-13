#requires -Version 7.2
[CmdletBinding()]
param([string] $ModulePath = (Join-Path $PSScriptRoot '../powershell/ohmyrushell.psd1'))
$ErrorActionPreference = 'Stop'
function Assert([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw $Message }
}
$originalAlias = Get-Alias ls -ErrorAction SilentlyContinue
$temporary = Join-Path ([IO.Path]::GetTempPath()) ('ohmyrushell-listing-' + [guid]::NewGuid())
$null = New-Item -ItemType Directory -Path $temporary
$null = New-Item -ItemType Directory -Path (Join-Path $temporary 'pasta com espaco')
[IO.File]::WriteAllText((Join-Path $temporary 'file.txt'), 'hello')
[IO.File]::WriteAllBytes((Join-Path $temporary 'large.bin'), [byte[]]::new(2048))
[IO.File]::WriteAllText((Join-Path $temporary '.env'), 'SECRET=value')
[IO.File]::WriteAllText((Join-Path $temporary '-dash.txt'), 'dash')
try {
    Import-Module $ModulePath -Force
    Assert ((Get-Alias ls).Definition -eq 'Get-OhMyRushellChildItem') 'Alias ls nao foi instalado.'
    $names = @(ls -1 --color=never $temporary)
    Assert ($names.Count -eq 4) 'Listagem simples incorreta ou arquivo oculto exibido.'
    Assert ($names[0] -eq 'pasta com espaco/') 'Pastas devem aparecer primeiro, com /.'
    Assert ($names -contains 'file.txt') 'Arquivo ausente.'
    Assert (-not ($names -join '').Contains([string][char]27)) 'ANSI inesperado sem cores.'
    $all = @(ls -a1 --color=never $temporary)
    Assert ($all -contains '.env') '-a nao mostrou dotfile.'
    $long = (ls -lah --color=never $temporary) -join "`n"
    Assert ($long.Contains('2KiB')) '-h nao formatou tamanho.'
    Assert ($long -match '\d{4}-\d{2}-\d{2} \d{2}:\d{2}') 'Data ausente.'
    $columns = @(ls -C --width=100 --color=never $temporary)
    Assert ($columns.Count -lt $names.Count) 'Colunas nao compactaram a listagem.'
    $narrow = @(ls -C --width=1 --color=never $temporary)
    Assert ($narrow.Count -eq $names.Count) 'Colunas estreitas perderam arquivos.'
    $wildcard = @(ls -1 --color=never (Join-Path $temporary '*.txt'))
    Assert ($wildcard.Count -eq 2) 'Wildcard nao foi expandido.'
    $colored = (ls -1 --color=always $temporary) -join "`n"
    Assert ($colored.Contains("`e[38;2;137;180;250m")) 'Cor de pasta ausente.'
    $oldNoColor = $env:NO_COLOR
    try {
        $env:NO_COLOR = '1'
        $plain = (ls -1 $temporary) -join "`n"
        Assert (-not $plain.Contains([string][char]27)) 'NO_COLOR foi ignorado.'
    } finally {
        $env:NO_COLOR = $oldNoColor
    }
    Push-Location $temporary
    try {
        $dash = @(ls -1 --color=never '--' '-dash.txt')
        Assert ($dash -contains '-dash.txt') '-- nao encerrou opcoes.'
    } finally { Pop-Location }
    Assert ((Get-ChildItem -LiteralPath $temporary | Select-Object -First 1) -is [IO.FileSystemInfo]) 'Get-ChildItem deixou de retornar objetos.'
    $failed = $false
    try { ls --invalid-option $temporary } catch { $failed = $true }
    Assert $failed 'Opcao invalida foi aceita.'
    Disable-OhMyRushell
    $restored = Get-Alias ls -ErrorAction SilentlyContinue
    Assert ($restored.Definition -eq $originalAlias.Definition) 'Alias ls anterior nao foi restaurado.'
    Enable-OhMyRushell
    Remove-Module ohmyrushell
    $restored = Get-Alias ls -ErrorAction SilentlyContinue
    Assert ($restored.Definition -eq $originalAlias.Definition) 'Remover modulo nao restaurou ls.'
    Write-Host 'Listing tests OK.' -ForegroundColor Green
} finally {
    Remove-Module ohmyrushell -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $temporary -Recurse -Force
}
