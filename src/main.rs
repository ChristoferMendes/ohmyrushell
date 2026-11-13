use std::path::Path;

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match args.first().map(String::as_str) {
        Some("init") => {
            let module = std::env::current_exe().ok().and_then(|exe| {
                exe.ancestors()
                    .skip(1)
                    .take(4)
                    .map(|base| base.join("powershell/ohmyrushell.psd1"))
                    .find(|module| module.is_file())
            });
            if let Some(module) = module {
                println!(
                    "Import-Module '{}'",
                    module.to_string_lossy().replace('\'', "''")
                );
            } else {
                println!("Import-Module ohmyrushell");
            }
        }
        Some("preview" | "git-status") => {
            let cwd = std::env::current_dir().expect("current directory is unavailable");
            let path = args.get(1).map(Path::new).unwrap_or(&cwd);
            let git = match ohmyrushell_core::git::read_native_status(path) {
                Ok(git) => git,
                Err(error) => {
                    eprintln!("Native Git error in {}: {error}", path.display());
                    std::process::exit(1);
                }
            };
            if args[0] == "git-status" {
                if let Some(git) = git {
                    println!(
                        "branch={} dirty={} staged={} modified={} untracked={} conflicts={} ahead={} behind={}",
                        git.branch,
                        git.is_dirty(),
                        git.staged,
                        git.modified,
                        git.untracked,
                        git.conflicts,
                        git.ahead,
                        git.behind
                    );
                } else {
                    eprintln!("Not a Git working tree: {}", path.display());
                    std::process::exit(1);
                }
                return;
            }
            let home = std::env::var(if cfg!(windows) { "USERPROFILE" } else { "HOME" }).ok();
            print!(
                "{}",
                ohmyrushell_core::theme::render(
                    &path.to_string_lossy(),
                    home.as_deref(),
                    git.as_ref(),
                    true,
                    std::env::var_os("NO_COLOR").is_none()
                )
            );
        }
        Some("--version" | "-V") => println!("ohmyrushell {}", env!("CARGO_PKG_VERSION")),
        None | Some("--help" | "-h") => println!(
            "ohmyrushell — Rust + PowerShell\n\n  ohmyrushell init             Print the PowerShell import command\n  ohmyrushell preview [path]   Preview the theme (in-process Git)\n  ohmyrushell git-status [path]  Diagnose native Git status/errors\n  ohmyrushell --version\n\nInstall: pwsh -File ./install.ps1\nThe interactive prompt uses a native library, not this executable."
        ),
        _ => {
            eprintln!("Unknown command. Run ohmyrushell --help.");
            std::process::exit(2);
        }
    }
}
