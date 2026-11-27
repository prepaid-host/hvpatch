//! One node per Proxmox VE cluster at a time.
//!
//! pmxcfs (`/etc/pve`) is replicated to every cluster node. Proxmox uses
//! directories below `/etc/pve/priv/lock/` as cluster-wide locks: `mkdir` is
//! atomic across the cluster. pmxcfs treats a lock as expired when its mtime
//! is about two minutes old, but it never removes an expired lock by itself.
//! It removes the lock only when a client sends an "unlock request": `utime`
//! with mtime 0 on the lock directory (a no-op while the lock is not
//! expired). Therefore:
//!
//! - a waiter sends this request each time `mkdir` fails, like
//!   `PVE::Cluster::cfs_lock`, so the lock of a crashed holder is released;
//! - the holder runs a background thread that sets the mtime to now every
//!   30 s until the lock is dropped, so the lock does not expire while it is
//!   held (settle time and hooks can take minutes).
//!
//! Without quorum `/etc/pve` is read-only and the lock cannot be taken.
//!
//! On a host without `/etc/pve` (not a PVE node, or tests) the lock is a
//! no-op.

use std::path::{Path, PathBuf};
use std::sync::mpsc::{self, RecvTimeoutError, Sender};
use std::thread::JoinHandle;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use anyhow::{Result, bail};

pub const LOCK_NAME: &str = "hvpatch-load";

pub struct ClusterLock {
    path: PathBuf,
    stop: Option<Sender<()>>,
    refresher: Option<JoinHandle<()>>,
}

/// How often the holder refreshes the lock (pmxcfs expires it at ~120 s).
const REFRESH_EVERY: Duration = Duration::from_secs(30);

fn set_mtime(path: &Path, t: SystemTime) {
    if let Ok(d) = std::fs::File::open(path) {
        let _ = d.set_modified(t);
    }
}

impl ClusterLock {
    /// Try to take the lock once. `Ok(None)`: another node holds it.
    pub fn try_acquire(dir: &Path) -> Result<Option<Self>> {
        Self::try_acquire_every(dir, REFRESH_EVERY)
    }

    fn try_acquire_every(dir: &Path, every: Duration) -> Result<Option<Self>> {
        let path = dir.join(LOCK_NAME);
        match std::fs::create_dir(&path) {
            Ok(()) => {
                let (stop, rx) = mpsc::channel::<()>();
                let p = path.clone();
                // Build the lock first: if spawn fails, Drop removes the dir.
                let mut lock = Self { path, stop: Some(stop), refresher: None };
                lock.refresher = Some(std::thread::Builder::new().name("hvpatch-lock".into()).spawn(move || {
                    // Timeout: refresh. Message or disconnect: stop.
                    while rx.recv_timeout(every) == Err(RecvTimeoutError::Timeout) {
                        set_mtime(&p, SystemTime::now());
                    }
                })?);
                Ok(Some(lock))
            }
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {
                // pmxcfs unlock request (mtime 0): removes the lock only if expired.
                set_mtime(&path, UNIX_EPOCH);
                Ok(None)
            }
            Err(e) => bail!(
                "cannot take the cluster lock {}: {e}. Without quorum /etc/pve is read-only; \
                 hvpatch does not load livepatches on a node that is not part of a quorate cluster \
                 (set cluster_lock = false to override)",
                path.display()
            ),
        }
    }

    pub fn holder_path(&self) -> &Path {
        &self.path
    }
}

impl Drop for ClusterLock {
    fn drop(&mut self) {
        // Stop and join first: a late refresh must not touch a lock that
        // another node may take right after remove_dir.
        drop(self.stop.take());
        if let Some(h) = self.refresher.take() {
            let _ = h.join();
        }
        let _ = std::fs::remove_dir(&self.path);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_one_holder() {
        let t = tempfile::tempdir().unwrap();
        let a = ClusterLock::try_acquire(t.path()).unwrap().unwrap();
        assert!(ClusterLock::try_acquire(t.path()).unwrap().is_none());
        drop(a);
        assert!(ClusterLock::try_acquire(t.path()).unwrap().is_some());
    }

    #[test]
    fn read_only_cluster_fs_is_an_error() {
        let t = tempfile::tempdir().unwrap();
        let missing = t.path().join("no/such/dir");
        assert!(ClusterLock::try_acquire(&missing).is_err());
    }

    fn mtime(p: &Path) -> SystemTime {
        std::fs::metadata(p).unwrap().modified().unwrap()
    }

    #[test]
    fn waiter_sends_unlock_request_to_foreign_lock() {
        let t = tempfile::tempdir().unwrap();
        let lock = t.path().join(LOCK_NAME);
        std::fs::create_dir(&lock).unwrap();
        assert!(ClusterLock::try_acquire(t.path()).unwrap().is_none());
        assert_eq!(mtime(&lock), UNIX_EPOCH);
    }

    #[test]
    fn holder_refreshes_mtime_in_background() {
        let t = tempfile::tempdir().unwrap();
        let a = ClusterLock::try_acquire_every(t.path(), Duration::from_millis(50)).unwrap().unwrap();
        set_mtime(a.holder_path(), UNIX_EPOCH);
        let deadline = std::time::Instant::now() + Duration::from_secs(10);
        while mtime(a.holder_path()) == UNIX_EPOCH {
            assert!(std::time::Instant::now() < deadline, "mtime not refreshed");
            std::thread::sleep(Duration::from_millis(10));
        }
    }

    #[test]
    fn drop_stops_refresher_and_removes_dir_promptly() {
        let t = tempfile::tempdir().unwrap();
        // Long interval: Drop must not wait for it.
        let a = ClusterLock::try_acquire(t.path()).unwrap().unwrap();
        let start = std::time::Instant::now();
        drop(a);
        assert!(start.elapsed() < Duration::from_secs(2));
        assert!(!t.path().join(LOCK_NAME).exists());
    }

    #[test]
    fn refresher_is_stopped_after_drop() {
        let t = tempfile::tempdir().unwrap();
        let a = ClusterLock::try_acquire_every(t.path(), Duration::from_millis(20)).unwrap().unwrap();
        let p = a.holder_path().to_path_buf();
        drop(a);
        // A live refresher would touch the recreated dir within a few ticks.
        std::fs::create_dir(&p).unwrap();
        set_mtime(&p, UNIX_EPOCH);
        std::thread::sleep(Duration::from_millis(200));
        assert_eq!(mtime(&p), UNIX_EPOCH);
    }
}
