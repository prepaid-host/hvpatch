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

fn list_json(seq: u64, shas: &[char]) -> String {
    let e: Vec<String> = shas
        .iter()
        .map(|c| {
            format!(
                r#"{{"sha256":"{}","kernel":"7.3.5-1-pve","level":2,"reason":"bad","revoked":"2020-01-01T00:00:00Z"}}"#,
                c.to_string().repeat(64)
            )
        })
        .collect();
    format!(r#"{{"format":1,"sequence":{seq},"issued":"2020-01-01T00:00:00Z","revoked":[{}]}}"#, e.join(","))
}

fn merge(list: &std::path::Path, from: &[&std::path::Path]) -> std::process::Output {
    let mut c = Command::new(env!("CARGO_BIN_EXE_hvpatch-tool"));
    c.args(["merge-revocations", "--list"]).arg(list);
    for f in from {
        c.arg("--from").arg(f);
    }
    c.output().unwrap()
}

#[test]
fn merge_adds_missing_entry_and_takes_max_sequence() {
    let dir = tempfile::tempdir().unwrap();
    let (list, from) = (dir.path().join("revoked.json"), dir.path().join("known.json"));
    std::fs::write(&list, list_json(5, &['a'])).unwrap();
    std::fs::write(&from, list_json(2, &['a', 'b'])).unwrap();
    let out = merge(&list, &[&from]);
    assert!(out.status.success());
    assert_eq!(String::from_utf8_lossy(&out.stdout).trim(), "1");
    let v: serde_json::Value = serde_json::from_slice(&std::fs::read(&list).unwrap()).unwrap();
    assert_eq!(v["sequence"], 5);
    assert_eq!(v["revoked"].as_array().unwrap().len(), 2);
    assert_eq!(v["issued"], "2020-01-01T00:00:00Z");
    assert_eq!(String::from_utf8_lossy(&merge(&list, &[&from]).stdout).trim(), "0");
}

#[test]
fn merge_with_invalid_from_fails_and_keeps_list() {
    let dir = tempfile::tempdir().unwrap();
    let (list, good, bad) = (dir.path().join("l.json"), dir.path().join("g.json"), dir.path().join("b.json"));
    let before = list_json(1, &['a']);
    std::fs::write(&list, &before).unwrap();
    std::fs::write(&good, list_json(1, &['b'])).unwrap();
    std::fs::write(&bad, "{}").unwrap();
    assert!(!merge(&list, &[&good, &bad]).status.success(), "invalid");
    assert!(!merge(&list, &[&good, &dir.path().join("none.json")]).status.success(), "missing");
    assert_eq!(std::fs::read_to_string(&list).unwrap(), before);
}

#[test]
fn merge_needs_an_existing_list() {
    let dir = tempfile::tempdir().unwrap();
    let (list, from) = (dir.path().join("l.json"), dir.path().join("f.json"));
    std::fs::write(&from, list_json(1, &['b'])).unwrap();
    assert!(!merge(&list, &[&from]).status.success());
    assert!(!list.exists());
}
