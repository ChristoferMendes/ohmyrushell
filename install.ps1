#requires -Version 7.2
<#
.SYNOPSIS
Build and install ohmyrushell for the current user (no administrator needed).
.DESCRIPTION
Builds a release with Cargo, then publishes an immutable module release.
Existing PowerShell sessions keep their loaded DLL. The profile is untouched
unless -AddToProfile is supplied. Run in PowerShell 7.2+, not Windows PowerShell.
.PARAMETER Destination
Module directory. Defaults to the current user's PowerShell Modules directory.
.PARAMETER AddToProfile
Enable in future sessions. Backs up an existing profile before changing it.
.PARAMETER NoBuild
Reuse target/release from a previous build, without requiring Rust.
.PARAMETER Check
Validate prerequisites and source files without building or changing any files.
.EXAMPLE
./install.ps1 -Check
.EXAMPLE
./install.ps1 -AddToProfile
.EXAMPLE
./install.ps1 -NoBuild -Destination ./sandbox/ohmyrushell -WhatIf
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [string] $Destination,
    [switch] $AddToProfile,
    [switch] $NoBuild,
    [switch] $Check
)

$ErrorActionPreference = 'Stop'
if (-not $Destination) {
    $moduleRoot = if ($IsWindows) {
        Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'PowerShell/Modules'
    } else {
        Join-Path $HOME '.local/share/powershell/Modules'
    }
    $Destination = Join-Path $moduleRoot 'ohmyrushell'
}

$Destination = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Destination)
$libraryName = if ($IsWindows) { 'ohmyrushell_core.dll' } elseif ($IsMacOS) { 'libohmyrushell_core.dylib' } else { 'libohmyrushell_core.so' }
$library = Join-Path $PSScriptRoot "target/release/$libraryName"
$sourceDirectory = Join-Path $PSScriptRoot 'powershell'
foreach ($required in @('ohmyrushell.psd1', 'ohmyrushell.psm1', 'AssemblyCache.ps1', 'PrepareAssemblies.ps1', 'Native.cs', 'Listing.ps1', 'CommandHighlighting.ps1', 'CommandHighlighting.cs')) {
    if (-not (Test-Path -LiteralPath (Join-Path $sourceDirectory $required) -PathType Leaf)) {
        throw "Arquivo do modulo ausente: $required. Use um clone completo do repositorio."
    }
}

if ($NoBuild) {
    if (-not (Test-Path -LiteralPath $library -PathType Leaf)) {
        throw "Biblioteca nao encontrada: $library. Execute ./install.ps1 sem -NoBuild para compilar primeiro."
    }
} else {
    foreach ($tool in @('cargo', 'rustc')) {
        if (-not (Get-Command $tool -CommandType Application -ErrorAction SilentlyContinue)) {
            throw "Pre-requisito ausente: $tool. Instale Rust 1.88+ em https://rustup.rs e abra uma nova sessao. No Windows, instale tambem C++ Build Tools (Desktop development with C++)."
        }
    }
    $rustVersion = & rustc --version
    if ($LASTEXITCODE -ne 0 -or $rustVersion -notmatch '^rustc (\d+\.\d+\.\d+)') {
        throw 'Nao foi possivel consultar rustc. Verifique a toolchain com rustup show.'
    }
    if ([version]$Matches[1] -lt [version]'1.88.0') {
        throw "Rust 1.88+ necessario; encontrado: $rustVersion. Atualize com rustup update stable."
    }
}

Write-Host "PowerShell $($PSVersionTable.PSVersion) / $([Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture)"
Write-Host "Destino: $Destination"
if (-not $NoBuild) { Write-Host "Toolchain: $rustVersion" }
if ($Check) {
    Write-Host 'Pre-requisitos OK; nenhum arquivo foi alterado. O compilador C/linker sera validado pelo Cargo no build.' -ForegroundColor Green
    return
}
$action = if ($NoBuild) { 'Instalar build release existente' } else { 'Compilar e instalar release (o primeiro build pode levar alguns minutos)' }
if ($AddToProfile) { $action += ' e atualizar o perfil com backup' }
if (-not $PSCmdlet.ShouldProcess($Destination, $action)) { return }

if (-not $NoBuild) {
    Write-Host '[1/3] Compilando Rust + libgit2...'
    Push-Location $PSScriptRoot
    try {
        # Keep the artifact location deterministic even with CARGO_TARGET_DIR set.
        & cargo build --release --locked --target-dir (Join-Path $PSScriptRoot 'target')
        if ($LASTEXITCODE -ne 0) {
            throw 'Falha no build Rust (veja a saida do Cargo acima). Verifique o compilador C/linker; no Windows, instale C++ Build Tools/MSVC. Se importou diretamente do projeto, feche a sessao que carregou target/release antes de recompilar.'
        }
    } finally {
        Pop-Location
    }
}

if (-not (Test-Path -LiteralPath $library -PathType Leaf)) { throw "Biblioteca nao encontrada: $library. Compile para a mesma plataforma/arquitetura do PowerShell, sem CARGO_BUILD_TARGET de cross-compilacao." }
Write-Host '[2/3] Preparando pontes .NET e publicando modulo...'
# Ship compiled bridges, not just a warmed user cache. A new shell need not
# compile even after the cache is cleared. Another runtime falls back to source.
$shell = Join-Path $PSHOME $(if ($IsWindows) { 'pwsh.exe' } else { 'pwsh' })
$metadataPath = [IO.Path]::GetTempFileName()
try {
    & $shell -NoLogo -NoProfile -NonInteractive -File (Join-Path $sourceDirectory 'PrepareAssemblies.ps1') -OutputPath $metadataPath
    if ($LASTEXITCODE -ne 0) { throw 'Falha ao compilar as pontes .NET. A instalacao anterior foi preservada.' }
    $managed = [IO.File]::ReadAllText($metadataPath) | ConvertFrom-Json
} finally {
    [IO.File]::Delete($metadataPath)
}

# Content-address the complete module, not just its DLL. Loaded releases are
# immutable: Windows can keep any previous library mapped without blocking updates.
$files = @(
    [pscustomobject]@{ Source = $library; Relative = "native/$libraryName"; Hash = (Get-FileHash -LiteralPath $library -Algorithm SHA256).Hash }
    [pscustomobject]@{ Source = $managed.Source; Relative = $managed.Relative; Hash = (Get-FileHash -LiteralPath $managed.Source -Algorithm SHA256).Hash }
    foreach ($file in Get-ChildItem -LiteralPath $sourceDirectory -File | Where-Object { $_.Extension -in @('.ps1', '.psm1', '.psd1', '.cs') }) {
        [pscustomobject]@{ Source = $file.FullName; Relative = $file.Name; Hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash }
    }
) | Sort-Object -Property Relative
$hashInput = ($files | ForEach-Object { "$($_.Relative):$($_.Hash)" }) -join "`n"
$releaseId = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($hashInput))).ToLowerInvariant()
$null = [IO.Directory]::CreateDirectory($Destination)
$Destination = (Resolve-Path -LiteralPath $Destination).ProviderPath
$releaseRoot = Join-Path $Destination 'releases'
$null = [IO.Directory]::CreateDirectory($releaseRoot)
$releasePath = Join-Path $releaseRoot $releaseId

if (-not [IO.Directory]::Exists($releasePath)) {
    $staging = Join-Path $releaseRoot ('.staging-' + [Guid]::NewGuid())
    try {
        $null = [IO.Directory]::CreateDirectory((Join-Path $staging 'native'))
        foreach ($file in $files) {
            $target = Join-Path $staging $file.Relative
            $null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target))
            Copy-Item -LiteralPath $file.Source -Destination $target
            if ((Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash -ne $file.Hash) {
                throw 'Os arquivos do build mudaram durante a instalacao. Tente novamente.'
            }
        }
        try {
            [IO.Directory]::Move($staging, $releasePath)
        } catch [IO.IOException] {
            # Another installer may have published the identical release first.
            if (-not [IO.Directory]::Exists($releasePath)) { throw }
        }
    } finally {
        if ([IO.Directory]::Exists($staging)) { Remove-Item -LiteralPath $staging -Recurse -Force }
    }
}

# Reinstalling an identical release is read-only, even if its DLL is in use.
foreach ($file in $files) {
    $target = Join-Path $releasePath $file.Relative
    if (-not [IO.File]::Exists($target) -or (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash -ne $file.Hash) {
        throw "Release incompleta ou modificada: $releasePath. Nenhuma DLL em uso foi sobrescrita."
    }
}

# Validate in a fresh process BEFORE publishing. A loaded Native type,
# PSReadLine settings and custom aliases in the caller are untouched.
Write-Host 'Validando modulo em uma sessao isolada...'
$releaseManifest = (Join-Path $releasePath 'ohmyrushell.psd1').Replace("'", "''")
$prepare = '$ErrorActionPreference = ''Stop''; Import-Module ''' + $releaseManifest + ''' -ErrorAction Stop'
& $shell -NoLogo -NoProfile -NonInteractive -Command $prepare
if ($LASTEXITCODE -ne 0) { throw 'Falha ao preparar o modulo. O manifesto ativo anterior foi preservado.' }

# Publish the stable entry point LAST with an atomic rename. Existing profiles
# keep importing the same path; new sessions select the newly installed release.
$sourceManifest = Join-Path $releasePath 'ohmyrushell.psd1'
$manifestText = [IO.File]::ReadAllText($sourceManifest)
$pattern = "(?m)^(\s*RootModule\s*=\s*)'ohmyrushell\.psm1'"
if ([regex]::Matches($manifestText, $pattern).Count -ne 1) {
    throw 'RootModule inesperado no manifesto. A instalacao anterior foi preservada.'
}
$replacement = '${1}' + "'releases/$releaseId/ohmyrushell.psm1'"
$manifestText = [regex]::Replace($manifestText, $pattern, $replacement)
$manifest = Join-Path $Destination 'ohmyrushell.psd1'
$temporaryManifest = Join-Path $Destination ('.manifest-' + [Guid]::NewGuid() + '.tmp')
try {
    [IO.File]::WriteAllText($temporaryManifest, $manifestText, [Text.UTF8Encoding]::new($false))
    $null = Test-ModuleManifest -Path $sourceManifest -ErrorAction Stop
    [IO.File]::Move($temporaryManifest, $manifest, $true)
} finally {
    if ([IO.File]::Exists($temporaryManifest)) { [IO.File]::Delete($temporaryManifest) }
}
$importLine = "Import-Module '$($manifest.Replace("'", "''"))'"

Write-Host '[3/3] Configurando ativacao...'
if ($AddToProfile) {
    $profilePath = $PROFILE.CurrentUserCurrentHost
    $null = New-Item -ItemType Directory -Path (Split-Path $profilePath -Parent) -Force
    if (-not (Test-Path -LiteralPath $profilePath)) {
        $null = New-Item -ItemType File -Path $profilePath
    }
    $existing = [IO.File]::ReadAllText($profilePath)
    $backup = "$profilePath.ohmyrushell.bak"
    # Back up before appending as well as before migrating legacy imports.
    if ($existing -and -not (Test-Path -LiteralPath $backup) -and -not $existing.Contains($importLine)) {
        Copy-Item -LiteralPath $profilePath -Destination $backup
        Write-Host "Backup do perfil: $backup"
    }
    # Only migrate the old generated import or a simple literal module import.
    # Never rewrite arbitrary scripts, expressions or custom prompt setup.
    $legacyManifest = Join-Path (Split-Path $Destination -Parent) 'SwiftPrompt/SwiftPrompt.psd1'
    $legacyImport = "Import-Module '$($legacyManifest.Replace("'", "''"))'"
    $comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    $updated = $existing.Replace($legacyImport, $importLine, $comparison)
    $legacyPattern = '(?im)^[\t ]*Import-Module[\t ]+(?:SwiftPrompt|''SwiftPrompt''|"SwiftPrompt")([ \t]*(?:#[^\r\n]*)?)(\r?)$'
    $updated = [regex]::Replace($updated, $legacyPattern, [Text.RegularExpressions.MatchEvaluator]{
        param($match)
        $importLine + $match.Groups[1].Value + $match.Groups[2].Value
    })
    if ($updated -cne $existing) {
        $backup = "$profilePath.ohmyrushell.bak"
        if (-not (Test-Path -LiteralPath $backup)) { Copy-Item -LiteralPath $profilePath -Destination $backup }
        $updated = [regex]::Replace($updated, '(?im)^# SwiftPrompt[ \t]*$', '# ohmyrushell')
        [IO.File]::WriteAllText($profilePath, $updated, [Text.UTF8Encoding]::new($false))
        $existing = $updated
        Write-Host "Importacao antiga migrada para ohmyrushell. Backup: $backup"
    }
    if (-not $existing -or -not $existing.Contains($importLine)) {
        Add-Content -LiteralPath $profilePath -Value "`n# ohmyrushell`n$importLine" -Encoding utf8
    }
    Write-Host 'Adicionado ao perfil. Remova inicializacoes de outros prompts para evitar conflito.'
}

Write-Host "Instalado em: $Destination"
Write-Host "Release: $releaseId"
if (('OhMyRushell.Native' -as [type]) -or ('SwiftPrompt.Native' -as [type])) {
    Write-Host 'A sessao atual continua com a versao carregada. Abra uma nova sessao para usar a atualizacao.' -ForegroundColor Yellow
    Write-Host 'Nao e necessario fechar as outras sessoes para instalar.'
} else {
    Write-Host 'Ative com:'
    Write-Host $importLine -ForegroundColor Green
}
Write-Host 'Releases anteriores foram mantidas para preservar DLLs em uso; nao ha hot reload de biblioteca nativa.'
