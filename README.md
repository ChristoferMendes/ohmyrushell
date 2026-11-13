# ohmyrushell

[![CI](https://github.com/ChristoferMendes/ohmyrushell/actions/workflows/ci.yml/badge.svg)](https://github.com/ChristoferMendes/ohmyrushell/actions/workflows/ci.yml)
[![MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![PowerShell 7.2+](https://img.shields.io/badge/PowerShell-7.2%2B-5391FE)](https://github.com/PowerShell/PowerShell)
[![Rust 1.88+](https://img.shields.io/badge/Rust-1.88%2B-orange)](https://rustup.rs)

**Um prompt minimalista para PowerShell, com o Git dentro do processo — não um processo por prompt.**

Núcleo em Rust, status Git via libgit2, paleta Catppuccin Mocha e visual inspirado
no Oh My Zsh. Sem Nerd Font, Powerline, daemon ou runtime Node/Python.

```text
~/workspace/meu-projeto  git:(main) ✗ ↑2
❯ git status
```

- **Git atualizado:** branch, alterações, conflitos e ahead/behind consultados a cada prompt, sem loading ou redesenho por idle.
- **Comandos com validação:** existentes em verde, inexistentes em vermelho; argumentos não são executados para validar a entrada.
- **`ls` familiar:** cores, colunas, `-a`, `-l` e `-h`, sem iniciar outro processo.
- **Instalação por usuário:** sem administrador; perfil só muda com sua autorização.
- **Atualizações lado a lado:** não sobrescrevem DLLs carregadas por outras sessões.

## Instalação

### 1. Prepare o ambiente

Use **PowerShell 7.2+ (`pwsh`)**, não Windows PowerShell 5.1. No Windows,
recomendamos Windows Terminal. Esta versão é instalada **a partir do código-fonte**:
não há download automático de binários nem publicação no PowerShell Gallery.

| Dependência | Como obter |
|---|---|
| PowerShell 7.2+ | [Instruções oficiais](https://learn.microsoft.com/powershell/scripting/install/installing-powershell) |
| Git | [git-scm.com](https://git-scm.com/downloads) — para clonar e executar os testes |
| Rust 1.88+ | [rustup.rs](https://rustup.rs) — toolchain da mesma arquitetura do `pwsh` |
| Compilador C/linker | Windows: [Build Tools](https://visualstudio.microsoft.com/visual-cpp-build-tools/), workload **Desktop development with C++** (MSVC + Windows SDK). Linux: `build-essential`/equivalente e `pkg-config`. macOS: `xcode-select --install`. |

O primeiro build compila também libgit2/zlib e pode levar alguns minutos.
Depois de instalado, o prompt **não precisa de Rust, Cargo ou `git.exe` no PATH**.
A validação local inicial foi feita no Windows; o CI também exercita Linux/macOS.

### 2. Clone, confira e instale

Execute em um terminal **PowerShell**:

```powershell
git clone https://github.com/ChristoferMendes/ohmyrushell.git
cd ohmyrushell
./install.ps1 -Check          # Diagnóstico sem alterar arquivos
./install.ps1 -AddToProfile   # Compila, instala e habilita em novas sessões
```

Abra uma **nova aba do PowerShell**. Remova do `$PROFILE` inicializações de
Oh My Posh/Starship/outros prompts para evitar conflitos.

Prefere experimentar primeiro? Sem mudar o perfil:

```powershell
./install.ps1
Import-Module ohmyrushell
# Para restaurar o prompt e o alias ls da sessão:
Disable-OhMyRushell
```

O instalador mostra o caminho exato de importação — use-o se sua pasta de módulos
não estiver em `$env:PSModulePath`. Não executamos scripts remotos via `iex`.

### Opções úteis

```powershell
Get-Help ./install.ps1 -Detailed
./install.ps1 -NoBuild                    # Reutiliza target/release; não exige Rust
./install.ps1 -NoBuild -Check             # Confere módulo e biblioteca existentes
./install.ps1 -AddToProfile -WhatIf       # Simula, sem build, cópias ou mudanças no perfil
./install.ps1 -Destination ./sandbox/ohmyrushell  # Instalação em diretório customizado
```

Por padrão, o módulo vai para `Documents/PowerShell/Modules/ohmyrushell` no
Windows (respeitando a pasta Documentos do sistema) ou
`~/.local/share/powershell/Modules/ohmyrushell` no Linux/macOS.
`-AddToProfile` edita somente `$PROFILE.CurrentUserCurrentHost`, faz backup de
conteúdo existente em `$PROFILE.ohmyrushell.bak` e não duplica a linha gerada.

### Atualizar ou remover

```powershell
cd ohmyrushell
git pull --ff-only
./install.ps1              # Use -AddToProfile se ainda não habilitou no perfil
```

Não é necessário fechar as outras sessões para instalar. Cada pacote fica em
`releases/<hash>/`; o manifesto estável passa a apontar para a nova versão.
**Abra uma nova sessão para usá-la.** `Import-Module -Force` não descarrega a DLL.
Releases antigas são mantidas: só as remova depois de fechar as sessões em uso.

Para desativar agora: `Disable-OhMyRushell` ou `Remove-Module ohmyrushell`.
Para desinstalar, remova a linha de importação do `$PROFILE`, feche as sessões
que carregaram o módulo e apague **apenas a pasta `ohmyrushell`** indicada pelo
instalador. Nunca apague a pasta inteira de módulos do PowerShell.

## O que o prompt mostra

| Indicador | Significado |
|---|---|
| `git:(main)` | Branch atual, inclusive antes do primeiro commit |
| `git:(@12ab34cd)` | HEAD destacado |
| `✗` amarelo | Staging, alterações, arquivos não rastreados ou conflitos |
| `!` vermelho | Erro de consulta; não é apresentado como repositório limpo |
| `↑N` / `↓N` | Commits à frente/atrás do upstream conhecido localmente |
| `❯` verde/vermelho | Sucesso/falha do último comando |

Não faz `fetch` nem acessa a rede. Fora de um repositório, mostra apenas o caminho.
`NO_COLOR` desliga as cores do prompt Rust; PSReadLine tem configuração separada.
O realce usa um índice de comandos: pode ficar temporariamente desatualizado.
Para atualizar: `Update-OhMyRushellCommandCache`.

### `ls` no estilo Linux

```powershell
ls                 # Pastas primeiro, cores e colunas no terminal
ls -lah            # Ocultos, detalhes e tamanhos legíveis
ls -1 ./src        # Um nome por linha
ls --help
```

Somente o alias `ls` é trocado, e restaurado ao desativar o módulo. A saída é
**texto formatado**, não objetos. Para pipelines de objetos ou `-Recurse`, use
`Get-ChildItem`/`gci`. Não é uma implementação completa do GNU ls.

## Solução de problemas

| Sintoma | Ação |
|---|---|
| Script bloqueado no Windows | Confira `Get-ExecutionPolicy -List`. Se permitido pela sua política, use `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned`. Não burle políticas da organização. |
| `cargo`/`rustc` não encontrado | Instale Rust e abra uma nova sessão; rode `./install.ps1 -Check`. |
| Erro de linker/build | Confira C++ Build Tools/MSVC + SDK no Windows, ou compilador C na sua plataforma. Veja a saída do Cargo. |
| DLL ausente/incompatível | Execute `./install.ps1` na mesma plataforma/arquitetura do `pwsh`. `cargo install` sozinho não instala o módulo. |
| DLL bloqueada ao recompilar | Se importou direto do projeto, feche a sessão que carregou `target/release`. A instalação normal usa releases imutáveis. |
| Outra versão já carregada | Abra uma nova sessão; não há hot reload nativo. |
| Git mostra `!` | Rode `./target/release/ohmyrushell.exe git-status .` (sem `.exe` no Unix). |

## Inicialização e desempenho

A instalação já compila e inclui as pontes .NET: a primeira aba não precisa
abrir o compilador. A descoberta de comandos disponíveis roda em background;
Git continua fresco e síncrono, com um único prompt, sem loading/redesenho.
Cores, `ls`, aliases, atalhos personalizados e predições são preservados.
Nomes ainda não resolvidos ficam neutros até a descoberta terminar.

Para comparar no Windows com PSReadLine real, sem tocar no perfil/histórico:

```powershell
python ./tests/benchmark-startup.py --iterations 15 --output target/startup.json
# Para medir uma instalação, acrescente: --module C:/caminho/ohmyrushell.psd1
```

O teste alterna sessões nativas e com todas as features habilitadas, mede o
primeiro prompt e o primeiro input aceito, e verifica os índices depois.
Não inclui configurações do seu perfil, zoxide ou tempo de abrir a janela do
Windows Terminal. Para Git/prompt aquecido em qualquer plataforma:

```powershell
pwsh -NoProfile -File ./tests/benchmark-git.ps1 -Path ./
```

Ter mais features ainda tem custo: não há promessa de superar o shell sem
customizações. Compare mediana/p95 na mesma máquina, pasta e runtime.
Veja a [comparação local e metodologia](docs/startup-performance.md).

## Desenvolvimento

```powershell
./scripts/test.ps1   # fmt + clippy + testes Rust + build release + testes PowerShell
```

Veja [CONTRIBUTING.md](CONTRIBUTING.md) para testes individuais e importação
local, e [notas técnicas](docs/architecture.md) para arquitetura, limitações,
cache, realce e migração do nome anterior.

## Licença

[MIT](LICENSE). Usa [git2-rs](https://github.com/rust-lang/git2-rs) e
[libgit2](https://libgit2.org/), distribuída sob GPLv2 com exceção de linking.
As dependências mantêm suas próprias licenças.
