# Startup performance

[← README](../README.md)

## Local comparison

Windows x64, PowerShell 7.7.0, ConPTY, the same native Rust build, and an empty temporary folder outside Git. Compared with the code before optimization (`c26136b`). 15 samples per scenario, alternating order; first run measured separately. No profiles, no history recording, and predictions disabled **equally in the benchmark** to reduce interference. The module does not disable predictions during normal use.

| Scenario | First prompt median / p95 | First accepted input median / p95 |
|---|---:|---:|
| Native PowerShell + PSReadLine | 270 / 302 ms | 315 / 347 ms |
| Previous ohmyrushell, cache ready | 425 / 463 ms | 467 / 498 ms |
| Optimized ohmyrushell, installed | 372 / 385 ms | 416 / 432 ms |

The first-prompt median decreased by **12.5%**. The first accepted input decreased by **10.8%**, without simply printing a prompt before the editor was usable. Confirmation of the indexes with a second command dropped from 499 to 448 ms; this includes typing and executing the confirmation, and does not measure the exact completion time.

The previous version's first run had to compile the bridge and took **1,893 ms** to reach the prompt; the first installed run took **387 ms**. These are not completely cold disk/OS measurements. Avoiding the compiler at startup is also verified by a functional test: empty cache with compilation explicitly forbidden. A runtime/PSReadLine change may require recompilation (fallback).

In another comparison, 300 warmed prompts in the same folder outside Git:

| Scenario | Median | p95 |
|---|---:|---:|
| Previous | 2.047 ms | 2.483 ms |
| Optimized | 0.785 ms | 1.037 ms |

The **62%** reduction mainly comes from updating session commands through the public C# API, without a PowerShell pipeline/wrappers. The Git backend and requirement for fresh status were not replaced with stale snapshots.

**It did not outperform uncustomized PowerShell.** The extra work still costs ~102 ms to the first prompt in this test. These local numbers don't guarantee latency on another machine, profile, network, runtime, or large repository.

## Reproducing

```powershell
cargo build --release --locked
./install.ps1 -NoBuild -Destination ./target/startup-installed
python ./tests/benchmark-startup.py --iterations 15 `
  --module ./target/startup-installed/ohmyrushell.psd1 `
  --baseline-module C:/checkout-before/powershell/ohmyrushell.psd1 `
  --output ./target/startup-comparison.json
```

The previous checkout also needs its Rust release library built. The JSON records the first run, samples, and median/p95. User profiles, aliases, and history are not changed. For warmed prompts:

```powershell
pwsh -NoProfile -File ./tests/benchmark-git.ps1 -Path C:/folder-outside-git -Iterations 300
```

Functional validation: `./scripts/test.ps1` and, on Windows, `python ./tests/interactive_git.py`. Additional coverage in `tests/startup.ps1`: concurrent cold imports, cache shared across releases, installation without a compiler/cache, fallback without PSReadLine, commands from modules not imported without executing their code, and preservation of aliases, colors, handlers, and predictions.
