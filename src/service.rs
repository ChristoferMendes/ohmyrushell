use crate::git::{GitStatus, read_head, read_native_status};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Mutex, OnceLock};
use std::time::Instant;

const MAX_ENTRIES: usize = 64;
static REVISION: AtomicU64 = AtomicU64::new(0);

struct Entry {
    value: Option<GitStatus>,
    touched: Instant,
}

#[derive(Default)]
struct Service {
    entries: Mutex<HashMap<PathBuf, Entry>>,
}

impl Service {
    fn get(&self, path: PathBuf, refresh: bool) -> Option<GitStatus> {
        self.get_with(path, refresh, read_native_status)
    }

    fn get_with(
        &self,
        path: PathBuf,
        refresh: bool,
        reader: impl FnOnce(&Path) -> Result<Option<GitStatus>, git2::Error>,
    ) -> Option<GitStatus> {
        if !refresh {
            return self
                .entries
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .get(&path)
                .and_then(|entry| entry.value.clone());
        }
        // Query before the only render, without holding the snapshot-cache lock.
        // On a real error keep only the current HEAD, never an old dirty status.
        let value = reader(&path).unwrap_or_else(|_| read_head(&path));
        let mut entries = self.entries.lock().unwrap_or_else(|e| e.into_inner());
        if entries.len() >= MAX_ENTRIES
            && !entries.contains_key(&path)
            && let Some(oldest) = entries
                .iter()
                .min_by_key(|(_, e)| e.touched)
                .map(|(p, _)| p.clone())
        {
            entries.remove(&oldest);
        }
        if entries.get(&path).and_then(|entry| entry.value.as_ref()) != value.as_ref() {
            REVISION.fetch_add(1, Ordering::Release);
        }
        // This cache is only for snapshot/FFI buffer retries. An actual prompt
        // always obtains a new native status, even when the branch is unchanged.
        entries.insert(
            path,
            Entry {
                value: value.clone(),
                touched: Instant::now(),
            },
        );
        value
    }
}

pub fn cached_status(path: &str, refresh: bool) -> Option<GitStatus> {
    static SERVICE: OnceLock<Service> = OnceLock::new();
    SERVICE
        .get_or_init(Service::default)
        .get(PathBuf::from(path), refresh)
}

pub fn revision() -> u64 {
    REVISION.load(Ordering::Acquire)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    #[test]
    fn every_prompt_gets_fresh_status_and_only_buffer_retries_reuse_it() {
        let service = Service::default();
        let path = PathBuf::from("/repo");
        service.get_with(path.clone(), true, |_| {
            Ok(Some(GitStatus {
                branch: "main".into(),
                untracked: 2,
                status_known: true,
                ..Default::default()
            }))
        });
        let clean = service
            .get_with(path.clone(), true, |_| {
                Ok(Some(GitStatus {
                    branch: "main".into(),
                    status_known: true,
                    ..Default::default()
                }))
            })
            .unwrap();
        assert!(clean.status_known);
        assert!(!clean.is_dirty(), "leaked the status from before git clean");
        let snapshot = service.get_with(path, false, |_| panic!("buffer retry queried Git again"));
        assert_eq!(snapshot, Some(clean));
    }

    #[test]
    fn native_error_keeps_current_branch_but_never_an_old_dirty_status_or_loading() {
        let root =
            std::env::temp_dir().join(format!("ohmyrushell-git-error-{}", std::process::id()));
        fs::create_dir_all(root.join(".git")).unwrap();
        fs::write(root.join(".git/HEAD"), "ref: refs/heads/main\n").unwrap();
        let service = Service::default();
        service.get_with(root.clone(), true, |_| {
            Ok(Some(GitStatus {
                branch: "main".into(),
                untracked: 2,
                status_known: true,
                ..Default::default()
            }))
        });
        let fallback = service
            .get_with(root.clone(), true, |_| {
                Err(git2::Error::from_str("simulated failure"))
            })
            .unwrap();
        assert_eq!(fallback.branch, "main");
        assert!(!fallback.status_known && !fallback.is_dirty());
        let prompt = crate::theme::render("/repo", None, Some(&fallback), true, false);
        assert!(!prompt.contains("...") && !prompt.contains('✗'));
        assert!(
            prompt.contains('!'),
            "query failure must not pretend the repository is clean"
        );
        fs::remove_dir_all(root).unwrap();
    }
}
