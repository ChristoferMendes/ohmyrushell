# Contributing

Bug reports, ideas, and pull requests are welcome. For bug reports, include the platform, architecture, PowerShell/Rust versions, reproduction steps, and error message, without secrets or unnecessary private paths.

## Local setup

Follow the [README prerequisites](README.md#1-check-the-requirements). Use Git, PowerShell 7.2+, Rust 1.88+ with `rustfmt`/`clippy`, and a C compiler/linker.

```powershell
rustup component add rustfmt clippy
./install.ps1 -Check
./scripts/test.ps1
```

The runner stops immediately on failure and runs each PowerShell test in a separate process to isolate DLLs and prompt changes. It doesn't install anything into your profile: installer tests use disposable directories and profiles. CI runs the same sequence on Windows, Linux, and macOS.

To try directly from the checkout without installing:

```powershell
cargo build --release --locked
Import-Module ./powershell/ohmyrushell.psd1
```

Close that session **before rebuilding the DLL it loaded**. To avoid this lock during daily development, prefer `./install.ps1` and import the installed module in a new tab; installed releases are immutable.

## Individual checks

```powershell
cargo fmt --all --check
cargo clippy --locked --all-targets -- -D warnings
cargo test --locked
cargo build --release --locked
pwsh -NoProfile -File ./tests/installer-preflight.ps1
pwsh -NoProfile -File ./tests/smoke.ps1
pwsh -NoProfile -File ./tests/listing.ps1
pwsh -NoProfile -File ./tests/highlighting.ps1
pwsh -NoProfile -File ./tests/startup.ps1
pwsh -NoProfile -File ./tests/installer.ps1
```

- Rust: parser, sanitization, FFI, staging, untracked files, conflicts, detached HEAD, upstream, worktrees, ignores, and Unicode/space-containing paths. Compares the native backend with the Git CLI and verifies that the index isn't rewritten.
- PowerShell: `$LASTEXITCODE` preservation, colors, prompt/alias restoration, listing, highlighting without executing input, and installation with locked DLLs.
- Startup: concurrent cold imports, cache shared across releases, installation without compilation on the first session even with an empty cache, module exports without executing code, preserved aliases/colors/shortcuts/predictions, and fallback without PSReadLine.
- Installer: diagnostics/dry runs without side effects, reinstalls, side-by-side updates, failures, and disposable-profile migration.

Optional interactive test on Windows, with Python 3 and no extra packages:

```powershell
python ./tests/interactive_git.py
```

This test uses ConPTY to check real editing, colors, branch, and exactly one fresh prompt after `git clean -fd`. Cleanup happens only in the test's temporary repository. The log is written to `target/interactive-output.log`.

## Measuring performance

```powershell
pwsh -NoProfile -File ./tests/benchmark-git.ps1 -Path ./
# Windows/ConPTY: first prompt + first real input, native vs customized
python ./tests/benchmark-startup.py --iterations 15 --output target/startup.json
# Additional paired comparison with an earlier checkout/manifest:
# --baseline-module C:/previous/path/powershell/ohmyrushell.psd1
```

The Git benchmark is read-only. ConPTY uses an empty temporary folder, without profiles or history, alternates session order, and records the first run separately from warmed samples. `index_check_ms` is the index confirmation via a second command (including editing/executing that command), not the exact moment background work completes. Measure cold start, bridge import/compilation, and warmed prompts separately. Don't treat a local measurement as a latency guarantee or a controlled comparison with other prompts.

See [the architecture notes](docs/architecture.md) before changing the cache/FFI, Git queries, keyboard handlers, or installer release publishing.
