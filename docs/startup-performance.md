# Medição de startup

[← README](../README.md)

## Comparação local

Windows x64, PowerShell 7.7.0, ConPTY, mesmo Rust nativo e pasta temporária vazia
fora de Git. Comparação com o código anterior à otimização (`c26136b`).
15 amostras por cenário, com ordem alternada; primeiro run separado. Sem perfis,
sem gravação de histórico e com predições desabilitadas **igualmente no benchmark**
para reduzir interferência. O módulo não desliga predições na utilização normal.

| Cenário | Primeiro prompt mediana / p95 | Primeiro input aceito mediana / p95 |
|---|---:|---:|
| PowerShell nativo + PSReadLine | 270 / 302 ms | 315 / 347 ms |
| ohmyrushell anterior, cache pronto | 425 / 463 ms | 467 / 498 ms |
| ohmyrushell otimizado, instalado | 372 / 385 ms | 416 / 432 ms |

Redução da mediana do primeiro prompt: **12,5%**. O primeiro input aceito caiu
**10,8%**, sem simplesmente imprimir um prompt antes de o editor estar usável.
A confirmação dos índices por um segundo comando caiu de 499 para 448 ms; isso
inclui digitar/executar a confirmação, não mede o instante exato da conclusão.

O primeiro run anterior precisou compilar a ponte e levou **1.893 ms** até o
prompt; o primeiro run instalado levou **387 ms**. Não são medições de disco/OS
completamente frios. A eliminação do compilador na abertura é verificada também
por teste funcional: cache vazio e compilação explicitamente proibida.
Uma troca de runtime/PSReadLine pode exigir nova compilação (fallback).

Em outra comparação, 300 prompts aquecidos na mesma pasta sem Git:

| Cenário | Mediana | p95 |
|---|---:|---:|
| Anterior | 2,047 ms | 2,483 ms |
| Otimizado | 0,785 ms | 1,037 ms |

A queda de **62%** vem principalmente de atualizar os comandos da sessão pela
API pública em C#, sem pipeline/embrulhos PowerShell. O backend Git e a exigência
de status fresco não foram substituídos por snapshots antigos.

**Não superou o PowerShell sem customizações.** O trabalho extra ainda custa
~102 ms até o primeiro prompt neste teste. Estes números locais não garantem
latência em outra máquina, perfil, rede, runtime ou repositório grande.

## Reproduzir

```powershell
cargo build --release --locked
./install.ps1 -NoBuild -Destination ./target/startup-installed
python ./tests/benchmark-startup.py --iterations 15 `
  --module ./target/startup-installed/ohmyrushell.psd1 `
  --baseline-module C:/checkout-anterior/powershell/ohmyrushell.psd1 `
  --output ./target/startup-comparison.json
```

O checkout anterior também precisa ter sua biblioteca Rust release compilada.
O JSON registra primeiro run, amostras e mediana/p95. Os perfis, aliases e
histórico do usuário não são alterados. Para prompt aquecido:

```powershell
pwsh -NoProfile -File ./tests/benchmark-git.ps1 -Path C:/pasta-sem-git -Iterations 300
```

Validação funcional: `./scripts/test.ps1` e, no Windows,
`python ./tests/interactive_git.py`. Cobertura adicional em `tests/startup.ps1`:
imports frios concorrentes, cache compartilhado entre releases, instalação sem
compilador/cache, fallback sem PSReadLine, comandos de módulos não importados
sem executar seu código, aliases, cores, handlers e predições preservados.
