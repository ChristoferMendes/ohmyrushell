use ohmyrushell_core::{
    git::{read_head, read_native_status, read_status},
    render_cached, render_snapshot,
};
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

struct Repo {
    root: PathBuf,
    path: PathBuf,
}

impl Repo {
    fn new() -> Self {
        static SERIAL: AtomicU64 = AtomicU64::new(0);
        let serial = SERIAL.fetch_add(1, Ordering::Relaxed);
        let root =
            std::env::temp_dir().join(format!("ohmyrushell-test-{}-{serial}", std::process::id()));
        let path = root.join("repo com espaço");
        fs::create_dir_all(&path).unwrap();
        let repo = Self { root, path };
        repo.git(&["init", "--initial-branch=main"]);
        repo
    }

    fn git(&self, args: &[&str]) -> String {
        let output = Command::new("git")
            .args([
                "-c",
                "user.name=ohmyrushell Test",
                "-c",
                "user.email=test@example.invalid",
                "-c",
                "commit.gpgSign=false",
                "-c",
                "core.autocrlf=false",
            ])
            .args(args)
            .env("GIT_CONFIG_NOSYSTEM", "1")
            .env(
                "GIT_CONFIG_GLOBAL",
                if cfg!(windows) { "NUL" } else { "/dev/null" },
            )
            .current_dir(&self.path)
            .output()
            .expect("Git is required to run integration tests");
        assert!(
            output.status.success(),
            "git {args:?}: {}",
            String::from_utf8_lossy(&output.stderr)
        );
        String::from_utf8_lossy(&output.stdout).into_owned()
    }

    fn commit(&self) {
        fs::write(self.path.join("tracked.txt"), "initial\n").unwrap();
        self.git(&["add", "."]);
        self.git(&["commit", "-m", "initial"]);
    }
}

impl Drop for Repo {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.root);
    }
}

fn status(path: &Path) -> ohmyrushell_core::git::GitStatus {
    let native = read_native_status(path)
        .expect("native Git query failed")
        .expect("expected native Git status");
    let cli = read_status(path, Duration::from_secs(5)).expect("expected CLI Git status");
    assert_eq!(native.branch, cli.branch);
    assert_eq!(
        (
            native.staged,
            native.modified,
            native.untracked,
            native.conflicts
        ),
        (cli.staged, cli.modified, cli.untracked, cli.conflicts)
    );
    assert_eq!((native.ahead, native.behind), (cli.ahead, cli.behind));
    assert!(native.status_known);
    native
}

#[test]
fn real_repository_unborn_clean_dirty_and_staged() {
    let repo = Repo::new();
    assert_eq!(status(&repo.path).branch, "main");
    assert_eq!(read_head(&repo.path).unwrap().branch, "main");
    let nested = repo.path.join("deep/nested");
    fs::create_dir_all(&nested).unwrap();
    assert_eq!(read_head(&nested).unwrap().branch, "main");
    repo.commit();
    let clean = status(&repo.path);
    assert_eq!((clean.modified, clean.staged, clean.untracked), (0, 0, 0));
    fs::write(repo.path.join("tracked.txt"), "changed\n").unwrap();
    fs::write(repo.path.join("new file.txt"), "new\n").unwrap();
    let dirty = status(&repo.path);
    assert_eq!((dirty.modified, dirty.staged, dirty.untracked), (1, 0, 1));
    repo.git(&["add", "tracked.txt"]);
    let staged = status(&repo.path);
    assert_eq!(
        (staged.modified, staged.staged, staged.untracked),
        (0, 1, 1)
    );
}

#[test]
fn supports_detached_head_and_worktrees() {
    let repo = Repo::new();
    repo.commit();
    let oid = repo.git(&["rev-parse", "HEAD"]);
    repo.git(&["checkout", "--detach"]);
    assert_eq!(status(&repo.path).branch, format!("@{}", &oid[..8]));
    let worktree = repo.root.join("linked worktree");
    repo.git(&[
        "worktree",
        "add",
        "-b",
        "feature/test",
        worktree.to_str().unwrap(),
    ]);
    assert_eq!(status(&worktree).branch, "feature/test");
    assert_eq!(read_head(&worktree).unwrap().branch, "feature/test");
    assert_eq!(
        read_head(&repo.path).unwrap().branch,
        format!("@{}", &oid[..8])
    );
}

#[test]
fn native_status_respects_ignores_unicode_and_does_not_write_the_index() {
    let repo = Repo::new();
    repo.commit();
    fs::write(repo.path.join(".gitignore"), "ignored/\n*.log\n").unwrap();
    repo.git(&["add", ".gitignore"]);
    repo.git(&["commit", "-m", "ignore rules"]);
    fs::create_dir_all(repo.path.join("ignored")).unwrap();
    fs::write(repo.path.join("ignored/cache.txt"), "ignored").unwrap();
    fs::write(repo.path.join("debug.log"), "ignored").unwrap();
    assert!(!status(&repo.path).is_dirty());
    fs::write(repo.path.join("olá mundo.txt"), "new").unwrap();
    fs::write(repo.path.join("tracked.txt"), "changed").unwrap();
    repo.git(&["checkout", "-b", "feature/ação"]);
    let index = repo.path.join(".git/index");
    let before = fs::read(&index).unwrap();
    let native = status(&repo.path);
    assert_eq!((native.modified, native.untracked), (1, 1));
    assert_eq!(native.branch, "feature/ação");
    assert_eq!(
        fs::read(index).unwrap(),
        before,
        "native status wrote the user's index"
    );
}

#[test]
fn native_status_matches_upstream_divergence() {
    let repo = Repo::new();
    repo.commit();
    repo.git(&["branch", "upstream"]);
    repo.git(&["config", "branch.main.remote", "."]);
    repo.git(&["config", "branch.main.merge", "refs/heads/upstream"]);
    fs::write(repo.path.join("local.txt"), "local").unwrap();
    repo.git(&["add", "."]);
    repo.git(&["commit", "-m", "local change"]);
    assert_eq!(
        (status(&repo.path).ahead, status(&repo.path).behind),
        (1, 0)
    );
    repo.git(&["checkout", "upstream"]);
    fs::write(repo.path.join("remote.txt"), "remote").unwrap();
    repo.git(&["add", "."]);
    repo.git(&["commit", "-m", "upstream change"]);
    repo.git(&["checkout", "main"]);
    let native = status(&repo.path);
    assert_eq!((native.ahead, native.behind), (1, 1));
}

#[test]
fn native_status_reports_merge_conflicts() {
    let repo = Repo::new();
    repo.commit();
    repo.git(&["checkout", "-b", "other"]);
    fs::write(repo.path.join("tracked.txt"), "other\n").unwrap();
    repo.git(&["commit", "-am", "other change"]);
    repo.git(&["checkout", "main"]);
    fs::write(repo.path.join("tracked.txt"), "main\n").unwrap();
    repo.git(&["commit", "-am", "main change"]);
    let merge = Command::new("git")
        .args([
            "-c",
            "core.hooksPath=.git/no-hooks",
            "-c",
            "user.name=ohmyrushell Test",
            "-c",
            "user.email=test@example.invalid",
            "merge",
            "--no-commit",
            "other",
        ])
        .current_dir(&repo.path)
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .env(
            "GIT_CONFIG_GLOBAL",
            if cfg!(windows) { "NUL" } else { "/dev/null" },
        )
        .output()
        .unwrap();
    assert_eq!(
        merge.status.code(),
        Some(1),
        "{}",
        String::from_utf8_lossy(&merge.stderr)
    );
    let native = status(&repo.path);
    assert_eq!(native.conflicts, 1);
    assert!(native.is_dirty());
}

#[test]
fn non_repository_and_missing_directory_are_harmless() {
    let repo = Repo::new();
    assert!(read_native_status(&repo.root).unwrap().is_none());
    assert!(
        read_native_status(&repo.root.join("missing"))
            .unwrap()
            .is_none()
    );
}

#[test]
fn each_prompt_is_fresh_with_no_loading_even_after_repeated_git_clean() {
    let repo = Repo::new();
    repo.commit();
    let path = repo.path.to_str().unwrap();
    let first_prompt = render_cached(path, true);
    assert!(
        first_prompt.contains("main"),
        "branch must appear on the FIRST prompt"
    );
    assert!(!render_cached(repo.root.to_str().unwrap(), true).contains("main"));
    fs::write(repo.path.join("new.txt"), "new").unwrap();
    for _ in 0..5 {
        fs::write(repo.path.join("new.txt"), "new").unwrap();
        let dirty = render_cached(path, true);
        assert!(
            dirty.contains('✗'),
            "first prompt did not include native dirty status: {dirty:?}"
        );
        assert!(!dirty.contains("..."));
        assert_eq!(render_snapshot(path, true), dirty);
        repo.git(&["clean", "-fd"]);
        let clean = render_cached(path, true);
        assert!(
            !clean.contains('✗') && !clean.contains("..."),
            "git clean showed stale or loading status: {clean:?}"
        );
    }
    repo.git(&["checkout", "-b", "feature/instant"]);
    assert!(
        render_cached(path, true).contains("feature/instant"),
        "checkout must update the branch immediately"
    );
}
