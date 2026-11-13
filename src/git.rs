use std::fs::File;
use std::io::{BufRead, BufReader, Read};
use std::path::Path;
use std::process::{Command, Stdio};
use std::thread;
use std::time::{Duration, Instant};

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct GitStatus {
    pub branch: String,
    pub staged: usize,
    pub modified: usize,
    pub untracked: usize,
    pub conflicts: usize,
    pub ahead: usize,
    pub behind: usize,
    pub status_known: bool,
    pub(crate) oid: String,
}

impl GitStatus {
    fn push_line(&mut self, line: &str) {
        if let Some(head) = line.strip_prefix("# branch.head ") {
            self.branch = head.to_owned();
        } else if let Some(oid) = line.strip_prefix("# branch.oid ") {
            self.oid = oid.chars().take(8).collect();
        } else if let Some(ab) = line.strip_prefix("# branch.ab ") {
            let mut fields = ab.split_whitespace();
            self.ahead = fields
                .next()
                .and_then(|s| s.strip_prefix('+'))
                .and_then(|s| s.parse().ok())
                .unwrap_or(0);
            self.behind = fields
                .next()
                .and_then(|s| s.strip_prefix('-'))
                .and_then(|s| s.parse().ok())
                .unwrap_or(0);
        } else if line.starts_with("1 ") || line.starts_with("2 ") {
            let bytes = line.as_bytes();
            if bytes.len() >= 4 {
                self.staged += usize::from(bytes[2] != b'.');
                self.modified += usize::from(bytes[3] != b'.');
            }
        } else if line.starts_with("u ") {
            self.conflicts += 1;
        } else if line.starts_with("? ") {
            self.untracked += 1;
        }
    }

    fn finish(mut self) -> Option<Self> {
        if self.branch == "(detached)" {
            self.branch = format!("@{}", self.oid);
        }
        self.status_known = true;
        (!self.branch.is_empty()).then_some(self)
    }

    pub fn is_dirty(&self) -> bool {
        self.staged + self.modified + self.untracked + self.conflicts > 0
    }
}

fn small_file(path: &Path) -> Option<String> {
    let mut content = String::new();
    File::open(path)
        .ok()?
        .take(8192)
        .read_to_string(&mut content)
        .ok()?;
    Some(content)
}

/// Discover the branch immediately without spawning Git or scanning working files.
/// Supports normal repositories, subdirectories, submodules and linked worktrees.
pub fn read_head(path: &Path) -> Option<GitStatus> {
    for ancestor in path.ancestors() {
        let dot_git = ancestor.join(".git");
        let git_dir = if dot_git.is_dir() {
            dot_git
        } else if dot_git.is_file() {
            let content = small_file(&dot_git)?;
            let target = content.trim().strip_prefix("gitdir: ")?;
            ancestor.join(target)
        } else {
            continue;
        };
        let head = small_file(&git_dir.join("HEAD"))?;
        let head = head.trim();
        let branch = if let Some(branch) = head.strip_prefix("ref: refs/heads/") {
            branch.to_owned()
        } else if head.len() >= 8 && head.bytes().all(|b| b.is_ascii_hexdigit()) {
            format!("@{}", &head[..8])
        } else {
            return None;
        };
        if branch.is_empty() {
            return None;
        }
        return Some(GitStatus {
            branch,
            ..Default::default()
        });
    }
    None
}

/// Query Git directly in this process. No git.exe, worker, loading state or
/// deadline race: the returned status describes this exact prompt invocation.
/// The index is read/refreshed in memory only, never written back by this call.
pub fn read_native_status(path: &Path) -> Result<Option<GitStatus>, git2::Error> {
    use git2::{BranchType, ErrorCode, Repository, Status, StatusOptions};

    let repo = match Repository::discover(path) {
        Ok(repo) => repo,
        Err(error) if error.code() == ErrorCode::NotFound => return Ok(None),
        Err(error) => return Err(error),
    };
    if repo.is_bare() {
        return Ok(None);
    }
    let head = match repo.head() {
        Ok(head) => head,
        Err(error) if matches!(error.code(), ErrorCode::UnbornBranch | ErrorCode::NotFound) => {
            repo.find_reference("HEAD")?
        }
        Err(error) => return Err(error),
    };
    let branch = if let Some(target) = head.symbolic_target() {
        target
            .strip_prefix("refs/heads/")
            .unwrap_or(target)
            .to_owned()
    } else if head.is_branch() {
        head.shorthand().unwrap_or("HEAD").to_owned()
    } else if let Some(oid) = head.target() {
        format!("@{}", &oid.to_string()[..8])
    } else {
        return Err(git2::Error::from_str("HEAD has no branch or commit target"));
    };
    let mut options = StatusOptions::new();
    options
        .include_untracked(true)
        .recurse_untracked_dirs(false)
        .include_ignored(false)
        .include_unreadable(true)
        .exclude_submodules(false)
        .renames_head_to_index(false)
        .renames_index_to_workdir(false)
        .update_index(false);
    let entries = repo.statuses(Some(&mut options))?;
    let mut result = GitStatus {
        branch,
        status_known: true,
        ..Default::default()
    };
    let staged = Status::INDEX_NEW
        | Status::INDEX_MODIFIED
        | Status::INDEX_DELETED
        | Status::INDEX_RENAMED
        | Status::INDEX_TYPECHANGE;
    let modified = Status::WT_MODIFIED
        | Status::WT_DELETED
        | Status::WT_TYPECHANGE
        | Status::WT_RENAMED
        | Status::WT_UNREADABLE;
    for entry in entries.iter() {
        let status = entry.status();
        if status.contains(Status::CONFLICTED) {
            result.conflicts += 1;
            continue;
        }
        result.staged += usize::from(status.intersects(staged));
        result.modified += usize::from(status.intersects(modified));
        result.untracked += usize::from(status.contains(Status::WT_NEW));
    }
    if head.is_branch()
        && let Ok(local) = repo.find_branch(&result.branch, BranchType::Local)
        && let Ok(upstream) = local.upstream()
        && let (Some(local_oid), Some(remote_oid)) = (local.get().target(), upstream.get().target())
        && let Ok((ahead, behind)) = repo.graph_ahead_behind(local_oid, remote_oid)
    {
        result.ahead = ahead;
        result.behind = behind;
    }
    Ok(Some(result))
}

/// CLI reference implementation for regression tests/diagnostics only.
/// The prompt and preview use read_native_status instead.
pub fn read_status(path: &Path, timeout: Duration) -> Option<GitStatus> {
    let mut command = Command::new("git");
    command
        .args([
            "--no-optional-locks",
            "-c",
            "color.status=false",
            "-c",
            "core.quotePath=true",
            "status",
            "--porcelain=v2",
            "--branch",
            "--untracked-files=normal",
        ])
        .current_dir(path)
        .env("GIT_TERMINAL_PROMPT", "0")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null());

    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        command.creation_flags(0x0800_0000); // CREATE_NO_WINDOW
    }

    let mut child = command.spawn().ok()?;
    let stdout = child.stdout.take()?;
    // Drain the pipe concurrently, so a large status cannot deadlock Git.
    let reader = thread::spawn(move || {
        let mut status = GitStatus::default();
        for line in BufReader::new(stdout).lines() {
            status.push_line(&line.ok()?);
        }
        status.finish()
    });
    let deadline = Instant::now() + timeout;
    let success = loop {
        match child.try_wait() {
            Ok(Some(exit)) => break exit.success(),
            Ok(None) if Instant::now() < deadline => thread::sleep(Duration::from_millis(10)),
            _ => {
                let _ = child.kill();
                let _ = child.wait();
                // Do not join: a Git helper may still have an inherited pipe open.
                return None;
            }
        }
    };
    let status = reader.join().ok().flatten();
    if success { status } else { None }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parse(text: &str) -> GitStatus {
        let mut status = GitStatus::default();
        for line in text.lines() {
            status.push_line(line);
        }
        status.finish().unwrap()
    }

    #[test]
    fn counts_changes_and_tracking() {
        let status = parse(
            "# branch.oid abcdef123456\n# branch.head main\n# branch.ab +2 -3\n1 M. rest\n1 .M rest\n2 R. rest\nu UU rest\n? new file\n! ignored\n",
        );
        assert_eq!(status.branch, "main");
        assert_eq!(
            (
                status.staged,
                status.modified,
                status.untracked,
                status.conflicts
            ),
            (2, 1, 1, 1)
        );
        assert_eq!((status.ahead, status.behind), (2, 3));
    }

    #[test]
    fn handles_detached_and_unborn() {
        assert_eq!(
            parse("# branch.oid 0123456789abcdef\n# branch.head (detached)").branch,
            "@01234567"
        );
        assert_eq!(
            parse("# branch.oid (initial)\n# branch.head main").branch,
            "main"
        );
    }
}
