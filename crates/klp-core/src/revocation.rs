//! Signed revocation list (`v1/revoked.json` + `.minisig`).
//!
//! Lets a publisher withdraw a module that is already on nodes, e.g. after
//! a regression found in the field. Agents never load a revoked module
//! again, unload it if it is active, and fall back to the next level that
//! is not revoked. The list is signed with the manifest key and carries a
//! sequence number that only goes up, so an old list cannot be replayed to
//! un-revoke a module.

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

pub const FORMAT_VERSION: u32 = 1;
/// Upper bound for the list on the wire.
pub const MAX_SIZE: u64 = 1024 * 1024;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RevocationList {
    pub format: u32,
    /// Increases with every published list.
    pub sequence: u64,
    pub issued: DateTime<Utc>,
    #[serde(default)]
    pub revoked: Vec<Revoked>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Revoked {
    /// SHA-256 of the module file, as in the manifest.
    pub sha256: String,
    pub kernel: String,
    pub level: u32,
    pub reason: String,
    pub revoked: DateTime<Utc>,
}

impl Default for RevocationList {
    fn default() -> Self {
        Self { format: FORMAT_VERSION, sequence: 0, issued: DateTime::<Utc>::UNIX_EPOCH, revoked: vec![] }
    }
}

impl RevocationList {
    pub fn from_json(bytes: &[u8]) -> anyhow::Result<Self> {
        let l: RevocationList = serde_json::from_slice(bytes)?;
        l.validate()?;
        Ok(l)
    }

    pub fn validate(&self) -> anyhow::Result<()> {
        anyhow::ensure!(self.format == FORMAT_VERSION, "unsupported revocation list format {}", self.format);
        anyhow::ensure!(self.sequence > 0, "revocation list sequence must be at least 1");
        for r in &self.revoked {
            anyhow::ensure!(
                r.sha256.len() == 64 && r.sha256.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b)),
                "revoked entry {:?}: sha256 must be 64 lowercase hex characters",
                r.sha256
            );
            anyhow::ensure!(
                r.reason.len() <= 500 && !r.reason.contains('\n'),
                "revoked entry {}: reason too long",
                r.sha256
            );
            anyhow::ensure!(r.level > 0, "revoked entry {}: level 0", r.sha256);
        }
        Ok(())
    }

    pub fn find(&self, sha256: &str) -> Option<&Revoked> {
        self.revoked.iter().find(|r| r.sha256 == sha256)
    }

    /// Add an entry (or update its reason) and bump the sequence.
    pub fn revoke(&mut self, entry: Revoked, now: DateTime<Utc>) {
        self.revoked.retain(|r| r.sha256 != entry.sha256);
        self.revoked.push(entry);
        self.revoked.sort_by(|a, b| (&a.kernel, a.level).cmp(&(&b.kernel, b.level)));
        self.sequence += 1;
        self.issued = now;
    }

    /// Add every entry of `other` that is not in `self` (by sha256; an
    /// entry already here is kept) and take the higher sequence. Entries
    /// are never removed, so merging cannot un-revoke anything. Returns the
    /// number added. `issued` is left alone: the caller re-issues.
    pub fn merge(&mut self, other: &RevocationList) -> usize {
        let missing: Vec<Revoked> = other.revoked.iter().filter(|r| self.find(&r.sha256).is_none()).cloned().collect();
        let added = missing.len();
        self.revoked.extend(missing);
        self.revoked.sort_by(|a, b| (&a.kernel, a.level).cmp(&(&b.kernel, b.level)));
        self.sequence = self.sequence.max(other.sequence);
        added
    }

    /// Publish the same entries again with a new sequence and issue time,
    /// so that agents can tell the list is current (they refuse new loads
    /// when `issued` is too old).
    pub fn reissue(&mut self, now: DateTime<Utc>) {
        self.sequence += 1;
        self.issued = now;
    }

    pub fn to_json_pretty(&self) -> String {
        let mut s = serde_json::to_string_pretty(self).expect("revocation list serializes");
        s.push('\n');
        s
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn entry(sha: char, level: u32) -> Revoked {
        Revoked {
            sha256: sha.to_string().repeat(64),
            kernel: "7.3.5-1-pve".into(),
            level,
            reason: "regression in the field".into(),
            revoked: Utc::now(),
        }
    }

    #[test]
    fn roundtrip_and_revoke() {
        let mut l = RevocationList::default();
        l.revoke(entry('b', 2), Utc::now());
        l.revoke(entry('a', 1), Utc::now());
        l.revoke(entry('a', 1), Utc::now());
        assert_eq!(l.sequence, 3);
        assert_eq!(l.revoked.len(), 2);
        assert_eq!(l.revoked[0].level, 1);
        let back = RevocationList::from_json(l.to_json_pretty().as_bytes()).unwrap();
        assert_eq!(back, l);
        assert!(back.find(&"b".repeat(64)).is_some());
    }

    #[test]
    fn reissue_bumps_sequence_and_time_only() {
        let mut l = RevocationList::default();
        l.revoke(entry('a', 1), "2026-01-01T00:00:00Z".parse().unwrap());
        let before = l.revoked.clone();
        let now = "2026-02-01T00:00:00Z".parse().unwrap();
        l.reissue(now);
        assert_eq!((l.sequence, l.issued, &l.revoked), (2, now, &before));
        l.validate().unwrap();
    }

    #[test]
    fn rejects_bad_entries() {
        let mut l = RevocationList::default();
        assert!(l.validate().is_err(), "sequence 0");
        l.revoke(entry('a', 1), Utc::now());
        l.revoked[0].sha256 = "A".repeat(64);
        assert!(l.validate().is_err());
        assert!(
            RevocationList::from_json(br#"{"format":1,"sequence":1,"issued":"2026-11-24T00:00:00Z","x":1}"#).is_err()
        );
    }

    #[test]
    fn merge_adds_missing_and_never_removes() {
        let t1 = "2026-01-01T00:00:00Z".parse().unwrap();
        let mut a = RevocationList::default();
        a.revoke(entry('a', 1), t1);
        let mut b = RevocationList::default();
        b.revoke(entry('b', 2), t1);
        b.revoke(entry('c', 1), t1);
        let mut dup = entry('a', 1);
        dup.reason = "other reason".into();
        b.revoke(dup, t1);
        assert_eq!(b.sequence, 3);
        let kept = a.find(&"a".repeat(64)).unwrap().clone();
        assert_eq!(a.merge(&b), 2);
        assert_eq!(a.revoked.len(), 3);
        assert_eq!(a.find(&"a".repeat(64)), Some(&kept), "existing entry kept");
        assert_eq!(a.sequence, 3, "max sequence");
        assert_eq!(a.issued, t1, "issued unchanged");
        assert!(a.revoked.windows(2).all(|w| (&w[0].kernel, w[0].level) <= (&w[1].kernel, w[1].level)));
        assert_eq!(a.merge(&b), 0, "idempotent");
        assert_eq!(a.revoked.len(), 3);
        // a lower sequence does not lower ours
        let mut low = RevocationList::default();
        low.revoke(entry('d', 5), t1);
        assert_eq!(a.merge(&low), 1);
        assert_eq!(a.sequence, 3);
    }
}
