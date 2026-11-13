# ohmyrushell

[![CI](https://github.com/ChristoferMendes/ohmyrushell/actions/workflows/ci.yml/badge.svg)](https://github.com/ChristoferMendes/ohmyrushell/actions/workflows/ci.yml)
[![MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![PowerShell 7.2+](https://img.shields.io/badge/PowerShell-7.2%2B-5391FE)](https://github.com/PowerShell/PowerShell)
[![Rust 1.88+](https://img.shields.io/badge/Rust-1.88%2B-orange)](https://rustup.rs)

ohmyrushell is a minimal PowerShell prompt with a Rust core. It reads Git status
inside the shell process through libgit2, so it doesn't need to start a Git
process for each prompt.

The look takes inspiration from Oh My Zsh and uses the Catppuccin Mocha palette.
You don't need a Nerd Font, Powerline, a daemon, or a Node/Python runtime.

```text
~/workspace/meu-projeto  git:(main) ✗ ↑2
❯ git status
```

- Git status is checked at every prompt, including the branch, changes, conflicts,
  and ahead/behind counts. There's no loading indicator or idle redraw.
- Commands appear in green when found and red when missing. Validation doesn't
  execute your input or its arguments.
- A built-in `ls` adds colors, columns, and familiar flags such as `-a`, `-l`, and
  `-h`, without starting another process.
- Installation is per user, with no administrator access needed. The installer
  only changes your profile if you ask it to.
- Updates install side by side, leaving DLLs loaded by other sessions alone.

## Installation

<a id="1-prepare-o-ambiente"></a>

### 1. Check the requirements

Use PowerShell 7.2+ (`pwsh`). Windows PowerShell 5.1 isn't supported. On Windows,
we recommend Windows Terminal.

You'll need to build this version from source. The installer doesn't download
prebuilt binaries, and the module isn't published on the PowerShell Gallery.

| Dependency | Where to get it |
|---|---|
| PowerShell 7.2+ | [Official installation guide](https://learn.microsoft.com/powershell/scripting/install/installing-powershell) |
| Git | [git-scm.com](https://git-scm.com/downloads), for cloning the repository and running tests |
| Rust 1.88+ | [rustup.rs](https://rustup.rs). Use a toolchain that matches your `pwsh` architecture. |
| C compiler/linker | Windows: [Build Tools](https://visualstudio.microsoft.com/visual-cpp-build-tools/) with the **Desktop development with C++** workload (MSVC + Windows SDK). Linux: `build-essential` or equivalent, plus `pkg-config`. macOS: `xcode-select --install`. |

The first build also compiles libgit2/zlib and may take a few minutes. Once
installed, the prompt doesn't need Rust, Cargo, or `git.exe` on your PATH.
Initial local testing was done on Windows; CI also runs on Linux and macOS.

### 2. Clone and install

Run these commands in PowerShell:

```powershell
git clone https://github.com/ChristoferMendes/ohmyrushell.git
cd ohmyrushell
./install.ps1 -Check          # Check requirements without changing files
./install.ps1 -AddToProfile   # Build, install, and enable in future sessions
```

Open a new PowerShell tab to use the prompt. Remove any Oh My Posh, Starship, or
other prompt initialization from `$PROFILE` to avoid conflicts.

To try it without changing your profile:

```powershell
./install.ps1
Import-Module ohmyrushell
# Restore the session's previous prompt and ls alias:
Disable-OhMyRushell
```

The installer prints the exact import path. Use that path if your module folder
isn't in `$env:PSModulePath`. Installation doesn't run remote scripts through `iex`.

### Installer options

```powershell
Get-Help ./install.ps1 -Detailed
./install.ps1 -NoBuild                    # Reuse target/release; no Rust needed
./install.ps1 -NoBuild -Check             # Check the existing module and library
./install.ps1 -AddToProfile -WhatIf       # Preview without building, copying, or editing the profile
./install.ps1 -Destination ./sandbox/ohmyrushell  # Install to a custom directory
```

By default, the module goes into `Documents/PowerShell/Modules/ohmyrushell` on
Windows, using the system's Documents folder location, or
`~/.local/share/powershell/Modules/ohmyrushell` on Linux and macOS.

`-AddToProfile` only edits `$PROFILE.CurrentUserCurrentHost`. It backs up existing
content to `$PROFILE.ohmyrushell.bak` and won't add the generated import line twice.

### Updating or removing

```powershell
cd ohmyrushell
git pull --ff-only
./install.ps1              # Add -AddToProfile if you haven't enabled it in your profile
```

You can leave other sessions open during installation. Each release lives in
`releases/<hash>/`, and the stable manifest points to the newly installed version.
Open a new session to load it: `Import-Module -Force` doesn't unload the native DLL.
Old releases stay on disk; only remove them after closing the sessions using them.

To turn the module off in the current session, run `Disable-OhMyRushell` or
`Remove-Module ohmyrushell`.

To uninstall, remove the import line from `$PROFILE`, close any sessions that
loaded the module, and delete only the `ohmyrushell` folder shown by the installer.
Don't delete the entire PowerShell modules folder.

## Reading the prompt

| Indicator | Meaning |
|---|---|
| `git:(main)` | Current branch, including before the first commit |
| `git:(@12ab34cd)` | Detached HEAD |
| Yellow `✗` | Staged changes, working-tree changes, untracked files, or conflicts |
| Red `!` | Git status lookup failed; the repository isn't shown as clean |
| `↑N` / `↓N` | Commits ahead of or behind the locally known upstream |
| Green/red `❯` | The last command succeeded/failed |

The prompt never runs `fetch` or accesses the network. Outside a repository, it
shows just the path.

`NO_COLOR` turns off colors in the Rust prompt. PSReadLine has its own color
settings. Command highlighting uses an index that can briefly fall out of date;
run `Update-OhMyRushellCommandCache` to refresh it.

### Linux-style `ls`

```powershell
ls                 # Directories first, with colors and columns in the terminal
ls -lah            # Hidden entries, details, and human-readable sizes
ls -1 ./src        # One name per line
ls --help
```

The module replaces only the `ls` alias and restores it when disabled. Output is
formatted text. Use `Get-ChildItem`/`gci` when you need objects in a pipeline or
`-Recurse`. This isn't a full implementation of GNU ls.

## Troubleshooting

| Problem | What to try |
|---|---|
| Windows blocks the script | Check `Get-ExecutionPolicy -List`. If your policy allows it, use `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned`. Don't bypass your organization's policies. |
| `cargo`/`rustc` not found | Install Rust, open a new session, and run `./install.ps1 -Check`. |
| Linker or build error | Check that C++ Build Tools/MSVC + SDK are installed on Windows, or that a C compiler is available on your platform. Read the Cargo output for details. |
| Missing or incompatible DLL | Run `./install.ps1` on the same platform and architecture as `pwsh`. Running `cargo install` alone doesn't install the PowerShell module. |
| DLL locked during a rebuild | If you imported directly from the checkout, close the session that loaded `target/release`. Normal installation uses immutable releases to avoid this. |
| Another version is already loaded | Open a new session. Native hot reload isn't supported. |
| Git shows `!` | Run `./target/release/ohmyrushell.exe git-status .` (omit `.exe` on Unix). |

## Startup and performance

Installation compiles and includes the .NET bridges, so the first tab doesn't
need to run the compiler. Available commands are discovered in the background;
Git status stays fresh and synchronous, with one prompt and no loading or redraw.
Colors, `ls`, aliases, custom key bindings, and predictions are preserved.
Unresolved names stay neutral until discovery completes.

To compare real PSReadLine sessions on Windows without changing profiles or history:

```powershell
python ./tests/benchmark-startup.py --iterations 15 --output target/startup.json
# To measure an installation, add: --module C:/path/to/ohmyrushell.psd1
```

The test alternates native sessions and sessions with all features enabled,
measures the first prompt and first accepted input, then checks the indexes.
It excludes your profile, zoxide, and the time to open a Windows Terminal window.
To measure Git and warmed-up prompts on any platform:

```powershell
pwsh -NoProfile -File ./tests/benchmark-git.ps1 -Path ./
```

Extra features still have a cost: there's no promise to outperform an
uncustomized shell. Compare median/p95 on the same machine, directory, and runtime.
See the [local comparison and methodology](docs/startup-performance.md).

## Development

```powershell
./scripts/test.ps1   # fmt + clippy + Rust tests + release build + PowerShell tests
```

See [CONTRIBUTING.md](CONTRIBUTING.md) for individual tests and importing from a
local checkout. The [architecture notes](docs/architecture.md) cover limitations,
caching, command highlighting, and migration from the project's previous name.

## License

[MIT](LICENSE). The project uses [git2-rs](https://github.com/rust-lang/git2-rs) and
[libgit2](https://libgit2.org/). libgit2 is distributed under GPLv2 with a linking
exception. Dependencies retain their own licenses.
