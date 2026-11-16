//! The CLI surface, as a user meets it. These run the real binary; the
//! interesting case is the refusal, because running an unverified `dots` is
//! exactly the bypass the self-check exists to stop.

use std::process::Command;

fn dots() -> Command {
    let mut cmd = Command::new(env!("CARGO_BIN_EXE_dots"));
    cmd.env_remove("DOTS_SKIP_SELF_CHECK");
    cmd
}

#[test]
fn version_succeeds() {
    let out = dots().arg("--version").output().expect("running dots");
    assert!(out.status.success(), "status {:?}", out.status);
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(stdout.contains("dots"), "{stdout}");
}

#[test]
fn help_succeeds() {
    let out = dots().arg("--help").output().expect("running dots");
    assert!(out.status.success(), "status {:?}", out.status);
    let stdout = String::from_utf8_lossy(&out.stdout);
    for subcommand in ["status", "audit", "system", "home", "both"] {
        assert!(
            stdout.contains(subcommand),
            "`{subcommand}` missing:\n{stdout}"
        );
    }
}

#[test]
fn status_from_a_cargo_build_refuses_to_run() {
    let out = dots().arg("status").output().expect("running dots");
    assert!(
        !out.status.success(),
        "target/debug/dots must not be trusted: {:?}",
        out.status
    );
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(stderr.contains("/nix/store"), "{stderr}");
    assert!(stderr.contains("not a /nix/store path"), "{stderr}");
    assert!(
        stderr.contains("/run/current-system/sw/bin/dots"),
        "the refusal must name the system binary: {stderr}"
    );
}
