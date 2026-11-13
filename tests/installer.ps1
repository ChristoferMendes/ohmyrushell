#requires -Version 7.2
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
function Assert([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw $Message }
}

$project = Split-Path $PSScriptRoot -Parent
$temporary = Join-Path ([IO.Path]::GetTempPath()) ('ohmyrushell-installer-' + [Guid]::NewGuid())
$fixture = Join-Path $temporary 'source'
$destination = Join-Path $temporary 'ohmyrushell'
$libraryName = if ($IsWindows) { 'ohmyrushell_core.dll' } elseif ($IsMacOS) { 'libohmyrushell_core.dylib' } else { 'libohmyrushell_core.so' }
$library = Join-Path $project "target/release/$libraryName"
if (-not (Test-Path -LiteralPath $library)) { throw 'Execute cargo build --release antes deste teste.' }
$handles = [Collections.Generic.List[IntPtr]]::new()
$originalProfile = $PROFILE

try {
    $null = New-Item -ItemType Directory -Path (Join-Path $fixture 'target/release') -Force
    $null = New-Item -ItemType Directory -Path (Join-Path $fixture 'powershell') -Force
    Copy-Item -LiteralPath (Join-Path $project 'install.ps1') -Destination $fixture
    Copy-Item -Path (Join-Path $project 'powershell/*.*') -Destination (Join-Path $fixture 'powershell')
    Copy-Item -LiteralPath $library -Destination (Join-Path $fixture "target/release/$libraryName")
    $installer = Join-Path $fixture 'install.ps1'

    # Reproduce the legacy layout and keep its native library mapped throughout.
    $null = New-Item -ItemType Directory -Path (Join-Path $destination 'native') -Force
    Copy-Item -Path (Join-Path $fixture 'powershell/*.*') -Destination $destination
    $legacyLibrary = Join-Path $destination "native/$libraryName"
    Copy-Item -LiteralPath $library -Destination $legacyLibrary
    $handles.Add([Runtime.InteropServices.NativeLibrary]::Load($legacyLibrary))
    $legacyHash = (Get-FileHash -LiteralPath $legacyLibrary).Hash
    if ($IsWindows) {
        $locked = $false
        try {
            $stream = [IO.File]::Open($legacyLibrary, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
            $stream.Dispose()
        } catch [IO.IOException] { $locked = $true }
        Assert $locked 'A DLL do teste nao esta bloqueada; nao reproduziu o problema original.'
    }

    & $installer -NoBuild -Destination $destination
    $manifest = Join-Path $destination 'ohmyrushell.psd1'
    $firstRootModule = (Import-PowerShellDataFile -LiteralPath $manifest).RootModule
    Assert ($firstRootModule -match '^releases/[a-f0-9]{64}/ohmyrushell\.psm1$') 'Manifesto nao aponta para release imutavel.'
    Assert ((Get-FileHash -LiteralPath $legacyLibrary).Hash -eq $legacyHash) 'A DLL legada foi alterada.'
    $firstRelease = Split-Path (Join-Path $destination $firstRootModule) -Parent
    $firstLibrary = Join-Path $firstRelease "native/$libraryName"
    $handles.Add([Runtime.InteropServices.NativeLibrary]::Load($firstLibrary))
    $firstWriteTime = (Get-Item -LiteralPath $firstLibrary).LastWriteTimeUtc

    # Reinstallation must not try to write the exact same, now locked, DLL.
    & $installer -NoBuild -Destination $destination
    Assert ((Import-PowerShellDataFile -LiteralPath $manifest).RootModule -eq $firstRootModule) 'Reinstalacao identica criou outra release.'
    Assert ((Get-Item -LiteralPath $firstLibrary).LastWriteTimeUtc -eq $firstWriteTime) 'DLL identica foi regravada.'

    # A script-only update still needs an immutable complete new release.
    Add-Content -LiteralPath (Join-Path $fixture 'powershell/Listing.ps1') -Value "`n# Installer regression fixture."
    & $installer -NoBuild -Destination $destination
    $secondRootModule = (Import-PowerShellDataFile -LiteralPath $manifest).RootModule
    Assert ($secondRootModule -ne $firstRootModule) 'Atualizacao nao publicou nova release.'
    Assert (Test-Path -LiteralPath $firstLibrary) 'Release em uso foi removida.'
    Assert ((Get-Item -LiteralPath $firstLibrary).LastWriteTimeUtc -eq $firstWriteTime) 'DLL em uso foi modificada.'
    $null = Test-ModuleManifest -Path $manifest -ErrorAction Stop
    Assert (@(Get-ChildItem -LiteralPath (Join-Path $destination 'releases') -Filter '.staging-*' -Force).Count -eq 0) 'Staging abandonado.'

    # Test -AddToProfile against a disposable profile, never the user's real file.
    $testProfile = Join-Path $temporary 'profile/Microsoft.PowerShell_profile.ps1'
    $PROFILE = [pscustomobject]@{ CurrentUserCurrentHost = $testProfile }
    & $installer -NoBuild -Destination $destination -AddToProfile
    & $installer -NoBuild -Destination $destination -AddToProfile
    $profileText = Get-Content -LiteralPath $testProfile -Raw
    Assert ([regex]::Matches($profileText, 'Import-Module').Count -eq 1) 'Perfil recebeu importacoes duplicadas.'
    Assert ($profileText.Contains($manifest)) 'Perfil nao usa o manifesto estavel.'

    # Name migration is opt-in, preserves custom setup and creates a backup.
    $legacyManifest = Join-Path (Split-Path $destination -Parent) 'SwiftPrompt/SwiftPrompt.psd1'
    $legacyProfile = "# preserve this comment`r`nImport-Module '$legacyManifest'`r`n# custom setup remains`r`n"
    [IO.File]::WriteAllText($testProfile, $legacyProfile)
    & $installer -NoBuild -Destination $destination -AddToProfile
    $migrated = [IO.File]::ReadAllText($testProfile)
    Assert (-not $migrated.Contains($legacyManifest)) 'Importacao legada nao foi migrada.'
    Assert ($migrated.Contains($manifest) -and $migrated.Contains('# custom setup remains')) 'Migracao perdeu configuracao do usuario.'
    Assert ([IO.File]::ReadAllText("$testProfile.ohmyrushell.bak") -eq $legacyProfile) 'Backup do perfil original incorreto.'
    [IO.File]::WriteAllText($testProfile, "Import-Module SwiftPrompt # keep comment`r`n")
    & $installer -NoBuild -Destination $destination -AddToProfile
    $migrated = [IO.File]::ReadAllText($testProfile)
    Assert ($migrated.Contains($manifest) -and $migrated.Contains('# keep comment')) 'Importacao simples nao foi migrada.'
    Assert ([regex]::Matches($migrated, 'Import-Module').Count -eq 1) 'Migracao duplicou a importacao.'
    Assert ([IO.File]::ReadAllText("$testProfile.ohmyrushell.bak") -eq $legacyProfile) 'Backup original foi sobrescrito.'

    $shell = Join-Path $PSHOME $(if ($IsWindows) { 'pwsh.exe' } else { 'pwsh' })
    & $shell -NoLogo -NoProfile -File (Join-Path $PSScriptRoot 'installer-loaded.ps1') -ModulePath $manifest -InstallerPath $installer
    Assert ($LASTEXITCODE -eq 0) 'Atualizacao com o modulo carregado falhou.'

    $beforeFailure = (Get-FileHash -LiteralPath $manifest).Hash
    Remove-Item -LiteralPath (Join-Path $fixture 'powershell/Listing.ps1')
    $failed = $false
    try { & $installer -NoBuild -Destination $destination } catch { $failed = $true }
    Assert $failed 'Fonte incompleta foi aceita.'
    Assert ((Get-FileHash -LiteralPath $manifest).Hash -eq $beforeFailure) 'Falha alterou o manifesto ativo.'

    # New processes must load the new release through the same stable path.
    & $shell -NoLogo -NoProfile -File (Join-Path $PSScriptRoot 'smoke.ps1') -ModulePath $manifest
    Assert ($LASTEXITCODE -eq 0) 'Smoke test da release instalada falhou.'
    & $shell -NoLogo -NoProfile -File (Join-Path $PSScriptRoot 'listing.ps1') -ModulePath $manifest
    Assert ($LASTEXITCODE -eq 0) 'Teste de ls da release instalada falhou.'
    & $shell -NoLogo -NoProfile -File (Join-Path $PSScriptRoot 'highlighting.ps1') -ModulePath $manifest
    Assert ($LASTEXITCODE -eq 0) 'Teste de realce da release instalada falhou.'
    Write-Host 'Installer tests OK: migracao legada, DLLs bloqueadas, reinstalacao, atualizacao e perfil.' -ForegroundColor Green
} finally {
    $PROFILE = $originalProfile
    foreach ($handle in $handles) { [Runtime.InteropServices.NativeLibrary]::Free($handle) }
    Remove-Item -LiteralPath $temporary -Recurse -Force -ErrorAction SilentlyContinue
}
