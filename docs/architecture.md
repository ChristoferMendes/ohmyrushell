# Arquitetura e limitações

[← README](../README.md)

## Caminho do prompt

1. O módulo PowerShell captura `$?` antes de executar qualquer outra expressão e
   preserva `$LASTEXITCODE`.
2. Uma ponte C# chama a biblioteca Rust via P/Invoke, dentro do processo.
3. Rust descobre o repositório e consulta branch, índice, alterações e upstream
   usando git2/libgit2. Não inicia `git.exe`.
4. O status fresco é renderizado uma única vez. Não há worker, loading, callback
   de idle ou redesenho posterior.

O índice é atualizado somente em memória: a consulta não regrava o índice do
usuário. O cache de até 64 snapshots existe apenas para retries de buffer FFI,
não para reaproveitar status antigo em prompts reais. O buffer .NET é reutilizado.
Nomes exibidos têm caracteres de controle neutralizados para impedir injeção de
sequências do terminal.

A consulta é **síncrona**. Repositórios grandes, discos frios, filtros especiais e
unidades de rede podem custar tempo: não há garantia de latência constante.
Erros reais mostram `!` e a branch atual quando possível, nunca estado limpo
inventado. Para diagnóstico:

```powershell
./target/release/ohmyrushell.exe git-status .
./target/release/ohmyrushell.exe preview
./target/release/ohmyrushell.exe init  # Apenas imprime a importação
```

No Linux/macOS, retire `.exe`. A descoberta reconhece `.git` nos ancestrais e
arquivos `gitdir:`, incluindo worktrees. Overrides avançados como `GIT_DIR` não
são tratados. libgit2 não reproduz todas as extensões/filtros especiais da CLI.
A implementação CLI em `src/git.rs` é uma referência para testes, não o backend
do prompt ou do preview. Nenhum `fetch` é executado automaticamente.

## Cache das pontes .NET

O instalador compila as pontes em um processo isolado e inclui o assembly em
`native/managed/` da release imutável. Com PSReadLine, uma única DLL contém a
ponte nativa e o realce. Abrir uma sessão não executa o compilador, mesmo com o
cache do usuário vazio. As cores/teclas do processo que instala não são alteradas.

A identidade inclui a versão principal do .NET e as versões de PSReadLine e
System.Management.Automation. Se essas versões mudarem, ou ao importar direto
do checkout, a compilação acontece uma vez com publicação atômica no cache:

- Windows: `%LOCALAPPDATA%/ohmyrushell/integration`;
- Unix: `$XDG_CACHE_HOME/ohmyrushell/integration` ou `~/.cache/ohmyrushell/integration`.

`OHMYRUSHELL_CACHE_HOME` permite escolher outra raiz de cache (útil nos testes).
A chave inclui código e runtime, **não o caminho da release**: atualizações de
scripts não obrigam a recompilar a ponte. Um resolver público .NET seleciona a
DLL Rust da release atual e continua proibindo trocar a DLL na mesma sessão.
Sem PSReadLine, a ponte nativa funciona sozinha (`ohmyrushell/bridge`).
Importação, compilação, primeiro input e prompt aquecido são custos distintos.

## Validação de comandos

O PSReadLine sozinho trata qualquer nome como comando. A camada C# analisa a AST
com APIs públicas, sem executar o texto digitado:

- verde: cmdlet, função, alias resolvível ou executável encontrado;
- vermelho: nome ausente do índice atual;
- neutro: índice carregando, caminho pendente ou invocação dinâmica (`& $cmd`).

Cada comando do pipeline é classificado separadamente. Argumentos não são
validados como comandos: `git qualquer-coisa` verifica somente `git`.
Não há `Get-Command`, processo externo ou varredura de PATH a cada tecla.
Cmdlets/exports são descobertos em background em um runspace temporário próprio,
sem bloquear o primeiro prompt e sem importar/executar os módulos descobertos.
Funções/aliases da sessão são lidos a cada prompt pela API pública de comandos,
sem pipeline PowerShell; nomes removidos não ficam em um cache persistente.
PATH/PATHEXT são indexados em background quando mudam e, durante prompts, no
máximo a cada 30 segundos. Enquanto qualquer descoberta está pendente, nomes
não resolvidos ficam neutros, nunca vermelhos por ausência de informação.
`Update-OhMyRushellCommandCache` continua fazendo o refresh explícito síncrono;
sua resposta não é sobrescrita por uma descoberta antiga ainda em andamento.
`WaitForIndex()` aguarda tanto o PATH quanto os exports. Caminhos explícitos são verificados em
background; a cor muda na próxima edição, não em callbacks de idle.

O realce interativo cobre a edição padrão Windows/Emacs no ConsoleHost com VT,
edição, histórico, conclusão e paste conhecidos. Preserva handlers personalizados
e predições. Ao desativar, restaura somente handlers que ainda são seus.
Modos/teclas não interceptados, incluindo Vi, mantêm o realce neutro. Seleções e
entradas com erros sintáticos usam a renderização nativa.

## Listagem

`ls` produz texto. Cores automáticas são desativadas em pipes/redirecionamentos e
com `NO_COLOR`; `--color=always` é uma escolha explícita. `-a` inclui ocultos,
mas não cria `.`/`..`. O modo exibido é o modo real do PowerShell, não permissões
POSIX simuladas no Windows. Datas são locais e cores de executáveis usam
extensões conhecidas. A largura de alguns emojis pode variar conforme o terminal.

```powershell
ls --color=always
ls -C --width=100
ls './-nome.txt'
ls '--' '-nome.txt'   # Aspas: PowerShell consome um -- sem aspas
```

## Instalações imutáveis

O instalador calcula SHA-256 do módulo completo e da biblioteca nativa, copia
para staging, verifica o conteúdo e publica `releases/<hash>/`. As pontes compiladas também
participam do hash. O módulo é validado em outro processo antes de publicar o
manifesto estável por último com rename atômico. Conteúdo idêntico é
reutilizado sem regravar DLLs; releases antigas não são removidas automaticamente.

Isso também permite migrar instalações antigas que tinham a DLL diretamente em
`native/`. `Remove-Module` restaura prompt/alias, mas não descarrega a DLL do
processo .NET. Atualizações passam a valer em novas sessões.

`-Check` verifica arquivos, presença e versão do Rust (ou biblioteca existente
com `-NoBuild`), mas não compila um programa para provar o compilador C/linker.
`-WhatIf` não compila nem instala. O build do instalador usa explicitamente
`target/` do projeto, independentemente de `CARGO_TARGET_DIR`; cross-compilação
via `CARGO_BUILD_TARGET` não é suportada. Compile para a arquitetura do `pwsh`.

### Migração de SwiftPrompt

O projeto, executável e módulo agora se chamam **ohmyrushell**.
`./install.ps1 -AddToProfile` substitui o import gerado anteriormente para
SwiftPrompt ou um `Import-Module SwiftPrompt` simples. Faz backup do perfil em
`$PROFILE.ohmyrushell.bak`, sem sobrescrever um backup existente.
Imports arbitrários/customizados precisam ser ajustados manualmente.
Sem `-AddToProfile`, nenhum perfil é modificado; o módulo antigo não é apagado.

A v0.5 substituiu o worker de `git status` por libgit2 em processo.
`OHMYRUSHELL_GIT_WAIT_MS` foi aposentada e é ignorada, mesmo configurada como 0.

## Estrutura

```text
src/git.rs          Backend libgit2 e referência CLI para testes
src/service.rs      Consulta fresca e snapshots para retries FFI
src/theme.rs        Tema, caminho e sanitização
src/lib.rs          ABI C e renderização
src/main.rs         Preview, init e diagnóstico
powershell/         Módulo, PSReadLine e ls
install.ps1         Build, instalação por usuário e perfil opt-in
scripts/test.ps1    Verificação local equivalente ao CI
```
