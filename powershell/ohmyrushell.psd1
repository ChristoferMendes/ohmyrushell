@{
    RootModule = 'ohmyrushell.psm1'
    ModuleVersion = '0.5.0'
    GUID = '83749ea8-4e87-48c5-aa2a-17e4dcbcd73f'
    Author = 'ohmyrushell contributors'
    Description = 'Prompt Rust com status Git nativo em processo e tema minimalista para PowerShell.'
    PowerShellVersion = '7.2'
    CompatiblePSEditions = @('Core')
    FunctionsToExport = @('Enable-OhMyRushell', 'Disable-OhMyRushell', 'Get-OhMyRushellChildItem', 'Update-OhMyRushellCommandCache')
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @()
    PrivateData = @{
        PSData = @{
            Tags = @('prompt', 'git', 'rust', 'PSReadLine')
            LicenseUri = 'https://github.com/ChristoferMendes/ohmyrushell/blob/main/LICENSE'
            ProjectUri = 'https://github.com/ChristoferMendes/ohmyrushell'
        }
    }
}
