#requires -Version 7.2
[CmdletBinding()]
param([string] $ModulePath = (Join-Path $PSScriptRoot '../powershell/ohmyrushell.psd1'))
$ErrorActionPreference = 'Stop'
function Assert([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw $Message }
}
function Wait-Classification([string] $Name) {
    $deadline = [DateTime]::UtcNow.AddSeconds(5)
    do {
        $state = [OhMyRushell.CommandHighlighting]::Classify($Name).ToString()
        if ($state -ne 'Pending') { return $state }
        Start-Sleep -Milliseconds 10
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Classificacao pendente por muito tempo: $Name"
}

$temporary = Join-Path ([IO.Path]::GetTempPath()) ('ohmyrushell-highlight-' + [Guid]::NewGuid())
$null = New-Item -ItemType Directory -Path $temporary
$originalPath = $env:PATH
try {
    Import-Module $ModulePath
    Assert ([OhMyRushell.CommandHighlighting]::WaitForIndex(5000)) 'Indice inicial nao ficou pronto.'
    Assert ([OhMyRushell.CommandHighlighting]::Classify('Get-ChildItem').ToString() -eq 'Valid') 'Cmdlet valido nao reconhecido.'
    Assert ([OhMyRushell.CommandHighlighting]::Classify('gci').ToString() -eq 'Valid') 'Alias nativo nao reconhecido.'
    Assert ([OhMyRushell.CommandHighlighting]::Classify('Microsoft.PowerShell.Management\Get-ChildItem').ToString() -eq 'Valid') 'Cmdlet qualificado nao reconhecido.'
    Assert ([OhMyRushell.CommandHighlighting]::Classify('ohmyrushell_command_that_does_not_exist').ToString() -eq 'Invalid') 'Comando inexistente ficou valido.'

    function global:ohmyrushell_test_function { throw 'O validador nunca deve executar esta funcao.' }
    Set-Alias -Name ohmyrushell_test_alias -Value ohmyrushell_test_function -Scope Global
    Set-Alias -Name ohmyrushell_broken_alias -Value ohmyrushell_command_that_does_not_exist -Scope Global
    Update-OhMyRushellCommandCache -SessionOnly
    Assert ([OhMyRushell.CommandHighlighting]::Classify('ohmyrushell_test_function').ToString() -eq 'Valid') 'Funcao criada na sessao nao reconhecida.'
    Assert ([OhMyRushell.CommandHighlighting]::Classify('ohmyrushell_test_alias').ToString() -eq 'Valid') 'Alias da sessao nao reconhecido.'
    Assert ([OhMyRushell.CommandHighlighting]::Classify('ohmyrushell_broken_alias').ToString() -eq 'Invalid') 'Alias com destino inexistente foi aceito.'
    Remove-Item Function:\ohmyrushell_test_function
    Remove-Alias -Name ohmyrushell_test_alias -Scope Global
    Update-OhMyRushellCommandCache -SessionOnly
    Assert ([OhMyRushell.CommandHighlighting]::Classify('ohmyrushell_test_function').ToString() -eq 'Invalid') 'Funcao removida ficou no cache.'

    $marks = [OhMyRushell.CommandHighlighting]::Analyze('Get-ChildItem | ohmyrushell_command_that_does_not_exist; Write-Output not_a_command')
    Assert ($marks.Count -eq 3) 'Argumentos foram confundidos com nomes de comando.'
    Assert ($marks[0].Validity.ToString() -eq 'Valid' -and $marks[1].Validity.ToString() -eq 'Invalid' -and $marks[2].Validity.ToString() -eq 'Valid') 'Pipeline nao foi classificado por comando.'
    Assert ([OhMyRushell.CommandHighlighting]::Analyze('& $dynamicCommand').Count -eq 0) 'Invocacao dinamica deveria permanecer neutra.'
    $sentinel = Join-Path $temporary 'must-not-exist'
    $null = [OhMyRushell.CommandHighlighting]::Analyze("Write-Output `$(New-Item '$sentinel')")
    Assert (-not (Test-Path -LiteralPath $sentinel)) 'Validador executou a entrada analisada.'

    $programName = 'ohmyrushell_test_program'
    $program = Join-Path $temporary ($programName + $(if ($IsWindows) { '.cmd' } else { '' }))
    [IO.File]::WriteAllText($program, $(if ($IsWindows) { '@exit /b 0' } else { "#!/bin/sh`nexit 0`n" }))
    if (-not $IsWindows) { & chmod +x $program }
    $env:PATH = $temporary + [IO.Path]::PathSeparator + $originalPath
    Update-OhMyRushellCommandCache -SessionOnly
    Assert ([OhMyRushell.CommandHighlighting]::WaitForIndex(5000)) 'Indice PATH alterado nao ficou pronto.'
    Assert ([OhMyRushell.CommandHighlighting]::Classify($programName).ToString() -eq 'Valid') 'Executavel no PATH nao reconhecido.'
    Assert ((Wait-Classification $program) -eq 'Valid') 'Caminho explicito nao reconhecido.'
    Assert ((Wait-Classification (Join-Path $temporary 'missing.ps1')) -eq 'Invalid') 'Script inexistente foi aceito.'
    Remove-Item -LiteralPath $program
    Update-OhMyRushellCommandCache
    Assert ([OhMyRushell.CommandHighlighting]::WaitForIndex(5000)) 'Refresh explicito nao reconstruiu PATH.'
    Assert ([OhMyRushell.CommandHighlighting]::Classify($programName).ToString() -eq 'Invalid') 'Executavel removido ficou no indice apos refresh.'
    # Public key APIs: preserve custom handlers and restore only our own edits.
    $originalX = @([Microsoft.PowerShell.PSConsoleReadLine]::GetKeyHandlers([string[]]@('x')))
    $originalA = @([Microsoft.PowerShell.PSConsoleReadLine]::GetKeyHandlers([string[]]@('a')))
    if ($originalX.Count -eq 0 -and $originalA.Count -eq 0) {
        Set-PSReadLineKeyHandler -Key x -BriefDescription OhMyRushellTestCustom -ScriptBlock { param($key, $arg) [Microsoft.PowerShell.PSConsoleReadLine]::SelfInsert($key, $arg) }
        $before = @([Microsoft.PowerShell.PSConsoleReadLine]::GetKeyHandlers($true, $false) | ForEach-Object { "$($_.Key)=$($_.Function)" } | Sort-Object) -join "`n"
        Assert ([OhMyRushell.CommandHighlighting]::InstallBindings() -gt 0) 'Handlers nao foram instalados.'
        Assert (([Microsoft.PowerShell.PSConsoleReadLine]::GetKeyHandlers([string[]]@('x')) | Select-Object -First 1).Function -eq 'OhMyRushellTestCustom') 'Handler personalizado foi sobrescrito.'
        [OhMyRushell.CommandHighlighting]::RemoveBindings()
        $after = @([Microsoft.PowerShell.PSConsoleReadLine]::GetKeyHandlers($true, $false) | ForEach-Object { "$($_.Key)=$($_.Function)" } | Sort-Object) -join "`n"
        Assert ($before -eq $after) 'Handlers originais nao foram restaurados.'
        $null = [OhMyRushell.CommandHighlighting]::InstallBindings()
        Set-PSReadLineKeyHandler -Key a -BriefDescription OhMyRushellTestLater -ScriptBlock { param($key, $arg) [Microsoft.PowerShell.PSConsoleReadLine]::SelfInsert($key, $arg) }
        [OhMyRushell.CommandHighlighting]::RemoveBindings()
        Assert (([Microsoft.PowerShell.PSConsoleReadLine]::GetKeyHandlers([string[]]@('a')) | Select-Object -First 1).Function -eq 'OhMyRushellTestLater') 'Handler instalado depois da ativacao foi removido.'
        Remove-PSReadLineKeyHandler -Key x, a
    }
    Write-Host 'Highlighting tests OK: comandos, PATH, pipelines, atalhos preservados e nenhuma execucao.' -ForegroundColor Green
} finally {
    $env:PATH = $originalPath
    if ('OhMyRushell.CommandHighlighting' -as [type]) { [OhMyRushell.CommandHighlighting]::RemoveBindings() }
    foreach ($key in @('x', 'a')) {
        $handler = [Microsoft.PowerShell.PSConsoleReadLine]::GetKeyHandlers([string[]]@($key)) | Select-Object -First 1
        if ($handler.Function -in @('OhMyRushellTestCustom', 'OhMyRushellTestLater')) { Remove-PSReadLineKeyHandler -Key $key }
    }
    Remove-Item Function:\ohmyrushell_test_function -ErrorAction SilentlyContinue
    Remove-Alias -Name ohmyrushell_test_alias -Scope Global -ErrorAction SilentlyContinue
    Remove-Alias -Name ohmyrushell_broken_alias -Scope Global -ErrorAction SilentlyContinue
    Remove-Module ohmyrushell -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $temporary -Recurse -Force -ErrorAction SilentlyContinue
}
