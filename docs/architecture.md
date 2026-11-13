# Architecture and limitations

[← README](../README.md)

## Prompt flow

1. The PowerShell module captures `$?` before executing any other expression and preserves `$LASTEXITCODE`.
2. A C# bridge calls the Rust library through P/Invoke, in-process.
3. Rust discovers the repository and queries the branch, index, changes, and upstream using git2/libgit2. It doesn't start `git.exe`.
4. Fresh status is rendered once. There is no worker, loading indicator, idle callback, or subsequent redraw.

The index is updated only in memory: the query does not rewrite the user's index. The cache of up to 64 snapshots exists only for FFI buffer retries, not to reuse stale status in actual prompts. The .NET buffer is reused. Displayed names have control characters neutralized to prevent terminal escape-sequence injection.

The query is **synchronous**. Large repositories, cold disks, special filters, and network drives can take time: constant latency isn't guaranteed. Actual errors show `!` and the current branch when possible, never fabricated clean status. For diagnostics:

```powershell
./target/release/ohmyrushell.exe git-status .
./target/release/ohmyrushell.exe preview
./target/release/ohmyrushell.exe init  # Prints the import command only
```

On Linux/macOS, omit `.exe`. Discovery recognizes `.git` in ancestor directories and `gitdir:` files, including worktrees. Advanced overrides such as `GIT_DIR` aren't handled. libgit2 doesn't reproduce all CLI extensions/special filters. The CLI implementation in `src/git.rs` is a test reference, not the prompt or preview backend. No `fetch` is run automatically.

## .NET bridge cache

The installer compiles the bridges in an isolated process and includes the assembly in `native/managed/` of the immutable release. With PSReadLine, a single DLL contains the native bridge and highlighting. Opening a session doesn't run the compiler, even with an empty user cache. Colors/keys in the installing process aren't changed.

The identity includes the .NET major version and the PSReadLine and System.Management.Automation versions. If these versions change, or when importing directly from the checkout, compilation runs once with atomic publication to the cache:

- Windows: `%LOCALAPPDATA%/ohmyrushell/integration`;
- Unix: `$XDG_CACHE_HOME/ohmyrushell/integration` or `~/.cache/ohmyrushell/integration`.

`OHMYRUSHELL_CACHE_HOME` lets you choose another cache root (useful in tests). The key includes code and runtime, **not the release path**: script updates don't require recompiling the bridge. A public .NET resolver selects the current release's Rust DLL and continues to prohibit swapping the DLL within the same session. Without PSReadLine, the native bridge works by itself (`ohmyrushell/bridge`). Import, compilation, first input, and warmed prompt are distinct costs.

## Command validation

PSReadLine alone treats any name as a command. The C# layer parses the AST using public APIs without executing the typed text:

- green: a cmdlet, function, resolvable alias, or executable was found;
- red: the name is absent from the current index;
- neutral: the index is loading, a path is pending, or invocation is dynamic (`& $cmd`).

Each pipeline command is classified separately. Arguments aren't validated as commands: `git whatever` checks only `git`. There is no `Get-Command`, external process, or PATH scan on every keystroke. Cmdlets/exports are discovered in the background in a dedicated temporary runspace, without blocking the first prompt or importing/executing discovered modules. Session functions/aliases are read on each prompt through the public command API, without a PowerShell pipeline; removed names aren't retained in a persistent cache. PATH/PATHEXT are indexed in the background when changed and, during prompts, at most every 30 seconds. While any discovery is pending, unresolved names stay neutral, never red due to missing information. `Update-OhMyRushellCommandCache` still performs an explicit synchronous refresh; its result isn't overwritten by an older discovery still in progress. `WaitForIndex()` waits for both PATH and exports. Explicit paths are checked in the background; the color changes on the next edit, not via idle callbacks.

Interactive highlighting covers default Windows/Emacs editing in ConsoleHost with VT, editing, history, completion, and paste recognized. It preserves custom handlers and predictions. When disabled, it restores only handlers that still belong to it. Unhandled modes/keys, including Vi, keep neutral highlighting. Selections and syntactically invalid input use native rendering.

## Listing

`ls` produces text. Automatic colors are disabled for pipes/redirection and with `NO_COLOR`; `--color=always` is an explicit choice. `-a` includes hidden entries but doesn't create `.`/`..`. The displayed mode is the actual PowerShell mode, not simulated POSIX permissions on Windows. Dates are local and executable colors use known extensions. The width of some emoji may vary by terminal.

```powershell
ls --color=always
ls -C --width=100
ls './-name.txt'
ls '--' '-name.txt'   # Quote it: PowerShell consumes an unquoted --
```

## Immutable installations

The installer calculates SHA-256 for the complete module and native library, copies them to staging, verifies the contents, and publishes `releases/<hash>/`. Compiled bridges are also included in the hash. The module is validated in another process before publishing the stable manifest last via atomic rename. Identical content is reused without rewriting DLLs; old releases aren't removed automatically.

This also supports migrating older installations that had the DLL directly in `native/`. `Remove-Module` restores the prompt/alias, but doesn't unload the DLL from the .NET process. Updates take effect in new sessions.

`-Check` verifies files and the presence/version of Rust (or an existing library with `-NoBuild`), but doesn't compile a program to prove the C compiler/linker works. `-WhatIf` doesn't compile or install. The installer build explicitly uses the project's `target/`, regardless of `CARGO_TARGET_DIR`; cross-compilation via `CARGO_BUILD_TARGET` isn't supported. Compile for the `pwsh` architecture.

### Migrating from SwiftPrompt

The project, executable, and module are now named **ohmyrushell**. `./install.ps1 -AddToProfile` replaces the previously generated SwiftPrompt import or a simple `Import-Module SwiftPrompt`. It backs up the profile to `$PROFILE.ohmyrushell.bak` without overwriting an existing backup. Arbitrary/custom imports must be adjusted manually. Without `-AddToProfile`, no profile is modified; the old module isn't deleted.

v0.5 replaced the `git status` worker with in-process libgit2. `OHMYRUSHELL_GIT_WAIT_MS` has been retired and is ignored, even when set to 0.

## Structure

```text
src/git.rs          libgit2 backend and CLI reference for tests
src/service.rs      Fresh queries and snapshots for FFI retries
src/theme.rs        Theme, path, and sanitization
src/lib.rs          C ABI and rendering
src/main.rs         Preview, init, and diagnostics
powershell/         Module, PSReadLine, and ls
install.ps1         Build, per-user installation, and opt-in profile setup
scripts/test.ps1    Local checks equivalent to CI
```
