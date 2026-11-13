# Contribuindo

Bugs, ideias e pull requests são bem-vindos. Para bugs, inclua plataforma,
arquitetura, versões de PowerShell/Rust, passos de reprodução e a mensagem de
erro, sem segredos ou caminhos privados desnecessários.

## Ambiente local

Siga os [pré-requisitos do README](README.md#1-prepare-o-ambiente). Use Git,
PowerShell 7.2+, Rust 1.88+ com `rustfmt`/`clippy` e um compilador C/linker.

```powershell
rustup component add rustfmt clippy
./install.ps1 -Check
./scripts/test.ps1
```

O runner para imediatamente em caso de falha e executa cada teste PowerShell em
um processo separado para isolar DLLs e alterações de prompt. Não instala nada
no seu perfil: os testes do instalador usam diretórios e perfis descartáveis.
O CI executa a mesma sequência no Windows, Linux e macOS.

Para experimentar diretamente do checkout, sem instalar:

```powershell
cargo build --release --locked
Import-Module ./powershell/ohmyrushell.psd1
```

Feche essa sessão **antes de recompilar a DLL que ela carregou**. Para evitar
esse bloqueio no fluxo diário, prefira `./install.ps1` e importe o módulo
instalado em uma nova aba; as releases instaladas são imutáveis.

## Verificações individuais

```powershell
cargo fmt --all --check
cargo clippy --locked --all-targets -- -D warnings
cargo test --locked
cargo build --release --locked
pwsh -NoProfile -File ./tests/installer-preflight.ps1
pwsh -NoProfile -File ./tests/smoke.ps1
pwsh -NoProfile -File ./tests/listing.ps1
pwsh -NoProfile -File ./tests/highlighting.ps1
pwsh -NoProfile -File ./tests/installer.ps1
```

- Rust: parser, sanitização, FFI, staging, arquivos não rastreados, conflitos,
  HEAD destacado, upstream, worktrees, ignores e caminhos Unicode/com espaços.
  Compara o backend nativo com Git CLI e verifica que o índice não é regravado.
- PowerShell: preservação de `$LASTEXITCODE`, cores, restauração do prompt/alias,
  listagem, realce sem execução da entrada e instalação com DLLs bloqueadas.
- Instalador: diagnóstico/simulação sem efeitos colaterais, reinstalação,
  atualizações lado a lado, falhas e migração de perfil descartável.

Teste interativo opcional no Windows, com Python 3 e sem pacotes extras:

```powershell
python ./tests/interactive_git.py
```

Esse teste usa ConPTY para conferir edição real, cores, branch e exatamente um
prompt fresco após `git clean -fd`. A limpeza ocorre apenas no repositório
temporário do teste. O log fica em `target/interactive-output.log`.

## Medir desempenho

```powershell
pwsh -NoProfile -File ./tests/benchmark-git.ps1 -Path ./
```

O benchmark é somente leitura. Meça cold start, importação/compilação das pontes
e prompt aquecido separadamente. Não trate uma medição local como garantia de
latência ou comparação controlada com outros prompts.

Veja [a arquitetura](docs/architecture.md) antes de alterar cache/FFI, consulta
Git, handlers de teclado ou publicação de releases do instalador.
