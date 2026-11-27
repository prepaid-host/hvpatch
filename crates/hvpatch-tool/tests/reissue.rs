//! `reissue-revocations` against a list file.

use std::process::Command;

fn run(list: &std::path::Path) -> std::process::Output {
    Command::new(env!("CARGO_BIN_EXE_hvpatch-tool")).args(["reissue-revocations", "--list"]).arg(list).output().unwrap()
}

#[test]
fn reissue_bumps_sequence_and_keeps_entries() {
    let dir = tempfile::tempdir().unwrap();
    let list = dir.path().join("revoked.json");
    let sha = "a".repeat(64);
    std::fs::write(
        &list,
        format!(
            r#"{{"format":1,"sequence":4,"issued":"2020-01-01T00:00:00Z","revoked":[{{"sha256":"{sha}","kernel":"7.3.5-1-pve","level":2,"reason":"bad","revoked":"2020-01-01T00:00:00Z"}}]}}"#
        ),
    )
    .unwrap();
    let out = run(&list);
    assert!(out.status.success());
    assert_eq!(String::from_utf8_lossy(&out.stdout).trim(), "5");
    let v: serde_json::Value = serde_json::from_slice(&std::fs::read(&list).unwrap()).unwrap();
    assert_eq!(v["sequence"], 5);
    assert_ne!(v["issued"], "2020-01-01T00:00:00Z");
    assert_eq!(v["revoked"][0]["level"], 2);
}

#[test]
fn reissue_needs_an_existing_valid_list() {
    let dir = tempfile::tempdir().unwrap();
    let list = dir.path().join("revoked.json");
    assert!(!run(&list).status.success(), "missing");
    assert!(!list.exists());
    std::fs::write(&list, "{}").unwrap();
    assert!(!run(&list).status.success(), "invalid");
}
