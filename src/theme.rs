use crate::git::GitStatus;
use std::fmt::Write;

const RESET: &str = "\x1b[0m";
const BLUE: &str = "\x1b[38;2;137;180;250m";
const MAUVE: &str = "\x1b[38;2;203;166;247m";
const YELLOW: &str = "\x1b[38;2;249;226;175m";
const GREEN: &str = "\x1b[38;2;166;227;161m";
const RED: &str = "\x1b[38;2;243;139;168m";

// Never allow a directory/branch name to inject terminal control sequences.
fn safe(text: &str) -> String {
    text.chars()
        .map(|ch| {
            if ch.is_control()
                || ('\u{202a}'..='\u{202e}').contains(&ch)
                || ('\u{2066}'..='\u{2069}').contains(&ch)
            {
                '�'
            } else {
                ch
            }
        })
        .collect()
}

pub fn display_path(path: &str, home: Option<&str>) -> String {
    #[cfg(windows)]
    let path = path.replace('\\', "/");
    #[cfg(not(windows))]
    let path = path.to_owned();
    if let Some(home) = home.filter(|h| !h.is_empty()) {
        #[cfg(windows)]
        let home = home.replace('\\', "/");
        #[cfg(not(windows))]
        let home = home.to_owned();
        let home = home.trim_end_matches('/');
        let prefix = path.get(..home.len());
        #[cfg(windows)]
        let matches = prefix.is_some_and(|p| p.eq_ignore_ascii_case(home));
        #[cfg(not(windows))]
        let matches = prefix == Some(home);
        if matches && (path.len() == home.len() || path[home.len()..].starts_with('/')) {
            return safe(&format!("~{}", &path[home.len()..]));
        }
    }
    safe(&path)
}

pub fn render(
    path: &str,
    home: Option<&str>,
    git: Option<&GitStatus>,
    success: bool,
    color: bool,
) -> String {
    let c = |value| if color { value } else { "" };
    // Classic OMZ-inspired text theme. Presentation only: freshness and the
    // single-render policy remain the responsibility of the Git service.
    let mut out = format!("{}{}{}", c(BLUE), display_path(path, home), c(RESET));
    if let Some(git) = git {
        let _ = write!(
            out,
            "  {}git:({}{}{}){}",
            c(BLUE),
            c(RED),
            safe(&git.branch),
            c(BLUE),
            c(RESET)
        );
        if !git.status_known {
            let _ = write!(out, " {}!{}", c(RED), c(RESET));
        } else {
            if git.is_dirty() {
                let _ = write!(out, " {}✗{}", c(YELLOW), c(RESET));
            }
            for (symbol, count) in [("↑", git.ahead), ("↓", git.behind)] {
                if count > 0 {
                    let _ = write!(out, " {}{symbol}{count}{}", c(MAUVE), c(RESET));
                }
            }
        }
    }
    let _ = write!(
        out,
        "\n{}❯{} ",
        c(if success { GREEN } else { RED }),
        c(RESET)
    );
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn home_is_only_replaced_at_a_directory_boundary() {
        assert_eq!(display_path("/home/me/code", Some("/home/me")), "~/code");
        assert_eq!(display_path("/home/me", Some("/home/me")), "~");
        assert_eq!(
            display_path("/home/mercury", Some("/home/me")),
            "/home/mercury"
        );
        assert_eq!(display_path("/tmp", Some("")), "/tmp");
    }

    #[test]
    fn strips_control_characters() {
        let prompt = render("/tmp/\x1b[31m\n", None, None, true, false);
        assert_eq!(prompt, "/tmp/�[31m�\n❯ ");
    }

    #[test]
    fn classic_theme_shows_clean_dirty_or_error_but_never_loading() {
        let status = GitStatus {
            branch: "main".into(),
            status_known: true,
            ..Default::default()
        };
        assert_eq!(
            render("/repo", None, Some(&status), true, false),
            "/repo  git:(main)\n❯ "
        );
        assert!(render("/repo", None, None, false, true).contains(RED));
        let dirty = GitStatus {
            modified: 1,
            ..status.clone()
        };
        assert_eq!(
            render("/repo", None, Some(&dirty), true, false),
            "/repo  git:(main) ✗\n❯ "
        );
        let unavailable = GitStatus {
            status_known: false,
            modified: 42,
            ..status
        };
        assert_eq!(
            render("/repo", None, Some(&unavailable), true, false),
            "/repo  git:(main) !\n❯ "
        );
        let colored = render("/repo", None, Some(&dirty), true, true);
        assert!(colored.contains(YELLOW));
        assert!(!colored.contains("..."));
        assert!(colored.contains('❯') && !colored.contains('\u{e0b0}'));
        assert!(!colored.contains("\x1b[48;") && !colored.contains("[ /repo ]"));
        assert!(colored.ends_with("\x1b[0m "));
    }
}
