#requires -Version 7.2
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
function Assert([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw $Message }
}

$project = Split-Path $PSScriptRoot -Parent
$temporary = Join-Path ([IO.Path]::GetTempPath()) ('ohmyrushell-preflight-' + [Guid]::NewGuid())
$fixture = Join-Path $temporary 'source'
$destination = Join-Path $temporary 'not-created/ohmyrushell'
$originalProfile = $PROFILE
$libraryName = if ($IsWindows) { 'ohmyrushell_core.dll' } elseif ($IsMacOS) { 'libohmyrushell_core.dylib' } else { 'libohmyrushell_core.so' }
try {
    $null = New-Item -ItemType Directory -Path (Join-Path $fixture 'target/release') -Force
    Copy-Item -LiteralPath (Join-Path $project 'install.ps1') -Destination $fixture
    Copy-Item -LiteralPath (Join-Path $project 'powershell') -Destination $fixture -Recurse
    $installer = Join-Path $fixture 'install.ps1'
    $testProfile = Join-Path $temporary 'profile.ps1'
    [IO.File]::WriteAllText($testProfile, '# existing profile')
    $PROFILE = [pscustomobject]@{ CurrentUserCurrentHost = $testProfile }
    $beforeProfile = (Get-FileHash -LiteralPath $testProfile).Hash

    # Missing artifacts must fail with an actionable message, before creating folders.
    $message = ''
    try { & $installer -NoBuild -Destination $destination } catch { $message = $_.Exception.Message }
    Assert ($message -match 'sem -NoBuild') 'Erro de biblioteca ausente nao explica como compilar.'
    Assert (-not (Test-Path -LiteralPath $destination)) 'Preflight com falha criou o destino.'

    Copy-Item -LiteralPath (Join-Path $project "target/release/$libraryName") -Destination (Join-Path $fixture 'target/release')
    $beforeFiles = @(Get-ChildItem -LiteralPath $temporary -Recurse -File).Count
    & $installer -Check -Destination $destination -AddToProfile
    & $installer -WhatIf -Destination $destination -AddToProfile
    & $installer -NoBuild -Check -Destination $destination -AddToProfile
    & $installer -NoBuild -WhatIf -Destination $destination -AddToProfile
    Assert (-not (Test-Path -LiteralPath $destination)) 'Check/WhatIf criou o destino.'
    Assert ((Get-FileHash -LiteralPath $testProfile).Hash -eq $beforeProfile) 'Check/WhatIf alterou o perfil.'
    Assert (@(Get-ChildItem -LiteralPath $temporary -Recurse -File).Count -eq $beforeFiles) 'Check/WhatIf criou arquivos.'

    # Normal profile activation backs up existing content and is idempotent.
    & $installer -NoBuild -Destination $destination -AddToProfile
    Assert ([IO.File]::ReadAllText("$testProfile.ohmyrushell.bak") -eq '# existing profile') 'Perfil existente nao recebeu backup.'
    & $installer -NoBuild -Destination $destination -AddToProfile
    Assert ([regex]::Matches([IO.File]::ReadAllText($testProfile), 'Import-Module').Count -eq 1) 'Ativacao duplicou imports.'
    Assert ([IO.File]::ReadAllText("$testProfile.ohmyrushell.bak") -eq '# existing profile') 'Reinstalacao sobrescreveu backup.'

    # -NoBuild must work without Rust; ordinary installation explains what is missing.
    $savedPath = $env:PATH
    try {
        $env:PATH = ''
        $message = ''
        try { & $installer -Check -Destination $destination } catch { $message = $_.Exception.Message }
        Assert ($message -match 'cargo' -and $message -match 'rustup.rs') 'Rust ausente nao gera uma instrucao util.'
        & $installer -NoBuild -Check -Destination $destination
    } finally {
        $env:PATH = $savedPath
    }

    Remove-Item -LiteralPath (Join-Path $fixture 'powershell/Listing.ps1')
    $message = ''
    try { & $installer -NoBuild -Check -Destination $destination } catch { $message = $_.Exception.Message }
    Assert ($message -match 'Listing.ps1') 'Check aceitou modulo incompleto.'
    Write-Host 'Preflight OK: erros uteis, Check/WhatIf sem efeitos, backup e perfil idempotente.' -ForegroundColor Green
} finally {
    $PROFILE = $originalProfile
    Remove-Item -LiteralPath $temporary -Recurse -Force -ErrorAction SilentlyContinue
}
