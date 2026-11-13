#requires -Version 7.2
[CmdletBinding()]
param(
    [string] $ModulePath = (Join-Path $PSScriptRoot '../powershell/ohmyrushell.psd1')
)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
function Assert([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw $Message }
}

Import-Module PSReadLine
$originalPrompt = (Get-Item Function:\prompt).ScriptBlock.ToString()
$originalColor = (Get-PSReadLineOption).CommandColor
Import-Module $ModulePath -Force
$rendered = prompt
Assert ($rendered.Contains([string][char]0x276f)) 'Indicador do tema classico ausente.'
Assert (-not $rendered.Contains("`e[48;")) 'O prompt ainda usa blocos de fundo.'
Assert (-not $rendered.Contains('...')) 'O prompt ainda mostra loading Git.'
Assert ($rendered.Contains($PWD.Path.Replace('\', '/').Split('/')[-1])) 'Diretorio ausente.'
Assert ((Get-PSReadLineOption).CommandColor -eq [OhMyRushell.CommandHighlighting]::Neutral) 'Comandos nao resolvidos nao devem assumir verde.'
Assert ([OhMyRushell.CommandHighlighting]::WaitForIndex(5000)) 'Indice PATH nao ficou pronto.'
Assert ([OhMyRushell.CommandHighlighting]::Classify('Get-ChildItem').ToString() -eq 'Valid') 'Cmdlet conhecido nao foi validado.'
Assert ([OhMyRushell.CommandHighlighting]::Classify('ohmyrushell_comando_que_nao_existe').ToString() -eq 'Invalid') 'Comando inexistente foi aceito.'

$global:LASTEXITCODE = 37
$null = prompt
Assert ($LASTEXITCODE -eq 37) 'O prompt alterou LASTEXITCODE.'
# $? must be captured immediately after each command, with no assignment in between.
$shell = Join-Path $PSHOME $(if ($IsWindows) { 'pwsh.exe' } else { 'pwsh' })
& $shell -NoLogo -NoProfile -Command 'exit 1'
$failedPrompt = prompt
Assert ($failedPrompt.Contains("`e[38;2;243;139;168m")) 'Falha nativa nao deixou o indicador vermelho.'
& $shell -NoLogo -NoProfile -Command 'exit 0'
$successPrompt = prompt
Assert ($successPrompt.Contains("`e[38;2;166;227;161m")) 'Sucesso nao deixou o indicador verde.'

$module = Get-Module ohmyrushell
$moduleIdleSubscriptions = @(Get-EventSubscriber | Where-Object {
    $_.SourceIdentifier -eq 'PowerShell.OnIdle' -and $_.Action.Command -match 'ohmyrushell'
})
Assert ($moduleIdleSubscriptions.Count -eq 0) 'O modulo ainda instala redesenho por idle.'

# Warm up the PowerShell/.NET/native call path before measuring it.
for ($i = 0; $i -lt 100; $i++) { $null = prompt }
$iterations = 2000
$timer = [Diagnostics.Stopwatch]::StartNew()
for ($i = 0; $i -lt $iterations; $i++) { $null = prompt }
$timer.Stop()
$averageUs = $timer.Elapsed.TotalMilliseconds * 1000 / $iterations
Write-Host ('Prompt aquecido: {0:N2} us/chamada ({1} chamadas; Git nativo em processo).' -f $averageUs, $iterations)

Disable-OhMyRushell
Assert ((Get-Item Function:\prompt).ScriptBlock.ToString() -eq $originalPrompt) 'Prompt anterior nao foi restaurado.'
Assert ((Get-PSReadLineOption).CommandColor -eq $originalColor) 'Cores anteriores nao foram restauradas.'
Enable-OhMyRushell
Remove-Module ohmyrushell
Assert ((Get-Item Function:\prompt).ScriptBlock.ToString() -eq $originalPrompt) 'Remover modulo nao restaurou o prompt.'
Write-Host 'Smoke tests OK.' -ForegroundColor Green
