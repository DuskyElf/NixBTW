//! `scripts/power.sh` is the one thing on this machine that runs as root from a
//! keybind, so it gets its own stage.
//!
//! This module is deliberately a *static* reader. It can show what the script
//! writes to, what it kills, what it invokes, and whether the store copy the
//! system will link is byte-identical to the source. It cannot prove the script
//! is safe; it makes the surface small enough to read. The decisive evidence is
//! the diff and the byte-identical store copy, not the scan's silence.

use anyhow::{bail, Result};
use serde_json::Value;
use std::path::{Path, PathBuf};

/// Where an absolute-path write lands.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WriteClass {
    /// Expected sysfs target: the script's documented job.
    Sysfs,
    /// A device, not state: `/dev/null` and friends.
    Device,
    /// Anything else. This is the finding that needs a human.
    Flagged,
}

#[derive(Debug, Clone)]
pub struct AbsWrite {
    pub line: usize,
    pub target: String,
    pub class: WriteClass,
}

#[derive(Debug, Clone, Default)]
pub struct Scan {
    pub set_euo: Option<usize>,
    pub writes: Vec<AbsWrite>,
    pub privileged: Vec<(String, usize)>,
    pub substitutions: Vec<(usize, String)>,
    pub dangerous: Vec<(String, usize)>,
    pub unguarded_kills: Vec<usize>,
    pub commands: Vec<(String, usize)>,
    pub functions: Vec<String>,
}

impl Scan {
    pub fn invoked(&self) -> Vec<String> {
        let mut names: Vec<String> = self.commands.iter().map(|(c, _)| c.clone()).collect();
        names.sort();
        names.dedup();
        names
    }

    pub fn flagged_writes(&self) -> Vec<&AbsWrite> {
        self.writes
            .iter()
            .filter(|w| w.class == WriteClass::Flagged)
            .collect()
    }

    /// Commands in the network-tool set. A root helper has no business with
    /// them, so any hit is reported separately from the generic warnings.
    pub fn network_commands(&self) -> Vec<(String, usize)> {
        self.dangerous
            .iter()
            .filter(|(w, _)| {
                matches!(
                    w.as_str(),
                    "curl" | "wget" | "nc" | "ssh" | "ncat" | "socat"
                )
            })
            .cloned()
            .collect()
    }
}

const DANGEROUS: &[&str] = &[
    "eval",
    "exec",
    "source",
    ".",
    "curl",
    "wget",
    "nc",
    "ncat",
    "socat",
    "ssh",
    "base64",
    "rm",
    "chmod",
    "chown",
    "dd",
    "mount",
    "umount",
    "useradd",
    "passwd",
    "systemctl",
    "iptables",
    "nft",
    "tee",
    // Interpreters and file movers turn a fixed script into a launcher: any
    // string in the file can become a command, and any absolute path can
    // become a write. A root helper has no business with them.
    "bash",
    "sh",
    "python",
    "perl",
    "node",
    "install",
    "cp",
    "mv",
    "ln",
    "busybox",
];

const SYSFS_PREFIXES: &[&str] = &[
    "/sys/class/backlight/",
    "/sys/bus/pci/devices/",
    "/sys/bus/pci/rescan",
];

const DEVICE_PREFIXES: &[&str] = &[
    "/dev/null",
    "/dev/stdout",
    "/dev/stderr",
    "/dev/tty",
    "/dev/zero",
    "/dev/random",
    "/dev/urandom",
];

fn is_keyword(word: &str) -> bool {
    matches!(
        word,
        "if" | "then"
            | "else"
            | "elif"
            | "fi"
            | "do"
            | "done"
            | "while"
            | "until"
            | "for"
            | "select"
            | "in"
            | "case"
            | "esac"
            | "function"
            | "time"
            | "!"
            | "{"
            | "}"
    )
}

fn is_builtin(word: &str) -> bool {
    matches!(
        word,
        "[" | "[["
            | "test"
            | "echo"
            | "printf"
            | "local"
            | "export"
            | "readonly"
            | "declare"
            | "typeset"
            | "set"
            | "shift"
            | "unset"
            | "cd"
            | "true"
            | "false"
            | ":"
            | "return"
            | "exit"
            | "read"
            | "trap"
            | "break"
            | "continue"
            | "wait"
    )
}

fn is_assignment(word: &str) -> bool {
    let Some((name, _)) = word.split_once('=') else {
        return false;
    };
    !name.is_empty()
        && name.chars().all(|c| c.is_ascii_alphanumeric() || c == '_')
        && !name.starts_with(|c: char| c.is_ascii_digit())
}

fn flag_takes_value(flag: &str) -> bool {
    matches!(
        flag,
        "-u" | "-g" | "-p" | "-U" | "-C" | "-T" | "-r" | "-t" | "-h"
    )
}

/// Cut the comment at an unquoted `#` that starts a word.
pub fn strip_comment(line: &str) -> &str {
    let mut single = false;
    let mut double = false;
    let mut prev_was_space = true;
    for (i, c) in line.char_indices() {
        match c {
            '\'' if !double => single = !single,
            '"' if !single => double = !double,
            '#' if !single && !double && prev_was_space => return &line[..i],
            _ => {}
        }
        prev_was_space = c.is_whitespace();
    }
    line
}

#[derive(Debug, Clone, PartialEq, Eq)]
enum Tok {
    Word(String),
    Sep,
    SubOpen,
    SubClose,
}

struct Lexer<'a> {
    chars: &'a [char],
    i: usize,
}

impl<'a> Lexer<'a> {
    fn peek(&self, offset: usize) -> Option<char> {
        self.chars.get(self.i + offset).copied()
    }

    fn lex(&mut self, out: &mut Vec<Tok>, stop_at_paren: bool) {
        while let Some(c) = self.peek(0) {
            match c {
                ' ' | '\t' => self.i += 1,
                ';' => {
                    out.push(Tok::Sep);
                    self.i += 1;
                }
                '|' | '&' => {
                    out.push(Tok::Sep);
                    self.i += 1;
                    if matches!(self.peek(0), Some('|') | Some('&')) {
                        self.i += 1;
                    }
                }
                '(' | ')' | '<' | '>' => {
                    if stop_at_paren && c == ')' {
                        self.i += 1;
                        return;
                    }
                    out.push(Tok::Sep);
                    self.i += 1;
                    if c == '>' || c == '<' {
                        // `>&2`, `>>` and `2>` should not merge with the target.
                        while matches!(self.peek(0), Some('>') | Some('&') | Some('2')) {
                            self.i += 1;
                        }
                    }
                }
                '$' if self.peek(1) == Some('(') => {
                    self.i += 2;
                    out.push(Tok::SubOpen);
                    self.lex(out, true);
                    out.push(Tok::SubClose);
                }
                '\'' => {
                    self.i += 1;
                    let mut word = String::new();
                    while let Some(c) = self.peek(0) {
                        self.i += 1;
                        if c == '\'' {
                            break;
                        }
                        word.push(c);
                    }
                    out.push(Tok::Word(word));
                }
                '"' => {
                    self.i += 1;
                    let mut word = String::new();
                    while let Some(c) = self.peek(0) {
                        if c == '"' {
                            self.i += 1;
                            break;
                        }
                        if c == '$' && self.peek(1) == Some('(') {
                            if !word.is_empty() {
                                out.push(Tok::Word(std::mem::take(&mut word)));
                            }
                            self.i += 2;
                            out.push(Tok::SubOpen);
                            self.lex(out, true);
                            out.push(Tok::SubClose);
                            continue;
                        }
                        word.push(c);
                        self.i += 1;
                    }
                    if !word.is_empty() {
                        out.push(Tok::Word(word));
                    }
                }
                _ => {
                    let mut word = String::new();
                    while let Some(c) = self.peek(0) {
                        if c.is_whitespace() || ";|&()<>'\"".contains(c) {
                            break;
                        }
                        if c == '$' && self.peek(1) == Some('(') {
                            if !word.is_empty() {
                                out.push(Tok::Word(std::mem::take(&mut word)));
                            }
                            self.i += 2;
                            out.push(Tok::SubOpen);
                            self.lex(out, true);
                            out.push(Tok::SubClose);
                            continue;
                        }
                        word.push(c);
                        self.i += 1;
                    }
                    if !word.is_empty() {
                        // `2>` / `2<` is an fd prefix on a redirect, not a word.
                        let fd_prefix = word.chars().all(|c| c.is_ascii_digit())
                            && matches!(self.peek(0), Some('<') | Some('>'));
                        if !fd_prefix {
                            out.push(Tok::Word(word));
                        }
                    } else {
                        // A character the word scanner refuses to consume would
                        // loop forever; step over it.
                        self.i += 1;
                    }
                }
            }
        }
    }
}

fn tokenize(code: &str) -> Vec<Tok> {
    let chars: Vec<char> = code.chars().collect();
    let mut lexer = Lexer {
        chars: &chars,
        i: 0,
    };
    let mut out = Vec::new();
    lexer.lex(&mut out, false);
    out
}

/// Absolute-path redirection targets written by one line.
pub fn absolute_writes(line: &str) -> Vec<String> {
    let code = strip_comment(line);
    let chars: Vec<char> = code.chars().collect();
    let mut targets = Vec::new();
    let mut single = false;
    let mut double = false;
    let mut i = 0;
    while i < chars.len() {
        let c = chars[i];
        match c {
            '\'' if !double => single = !single,
            '"' if !single => double = !double,
            '>' if !single && !double => {
                // Skip `>&1` style fd duplication.
                if chars.get(i + 1) == Some(&'&') {
                    i += 1;
                } else {
                    let mut j = i + 1;
                    if chars.get(j) == Some(&'>') {
                        j += 1;
                    }
                    while chars.get(j).map_or(false, |c| *c == ' ') {
                        j += 1;
                    }
                    let mut target = String::new();
                    while let Some(&c) = chars.get(j) {
                        if c.is_whitespace() || ";|&()<>".contains(c) {
                            break;
                        }
                        // Stop at a closing quote of an outer context.
                        target.push(c);
                        j += 1;
                    }
                    let cleaned = target.trim_matches(|c| c == '"' || c == '\'').to_string();
                    if cleaned.starts_with('/') {
                        targets.push(cleaned);
                    }
                    i = j;
                    continue;
                }
            }
            _ => {}
        }
        i += 1;
    }
    targets
}

fn classify(target: &str) -> WriteClass {
    if SYSFS_PREFIXES.iter().any(|p| target.starts_with(p)) {
        WriteClass::Sysfs
    } else if DEVICE_PREFIXES.iter().any(|p| target.starts_with(p)) {
        WriteClass::Device
    } else {
        WriteClass::Flagged
    }
}

fn command_lines(tokens: &[Tok], line: usize, scan: &mut Scan, delegating: &[String]) {
    let mut expect = true;
    let mut header = false;
    let mut i = 0;
    while i < tokens.len() {
        match &tokens[i] {
            Tok::Sep | Tok::SubOpen | Tok::SubClose => {
                expect = true;
                header = false;
                i += 1;
            }
            Tok::Word(word) => {
                if header {
                    i += 1;
                    continue;
                }
                if !expect {
                    i += 1;
                    continue;
                }
                if is_keyword(word) {
                    if word == "for" || word == "select" || word == "case" {
                        header = true;
                        expect = false;
                    } else if word == "function" {
                        if let Some(Tok::Word(name)) = tokens.get(i + 1) {
                            scan.functions.push(name.clone());
                        }
                        expect = false;
                    } else {
                        expect = true;
                    }
                    i += 1;
                    continue;
                }
                if is_assignment(word) {
                    i += 1;
                    continue;
                }
                if word == "sudo" {
                    scan.commands.push(("sudo".to_string(), line));
                    i += 1;
                    while let Some(Tok::Word(flag)) = tokens.get(i) {
                        if !flag.starts_with('-') {
                            break;
                        }
                        let takes = flag_takes_value(flag);
                        i += 1;
                        if takes {
                            i += 1;
                        }
                    }
                    continue;
                }
                if word.starts_with('/') || word.starts_with('$') {
                    expect = false;
                    i += 1;
                    continue;
                }
                if is_builtin(word) {
                    expect = false;
                    i += 1;
                    continue;
                }
                scan.commands.push((word.clone(), line));
                // A wrapper function that runs `"$@"` executes its first
                // argument as a command, so that argument is an invoked command
                // too. `run_user_cmd notify-send …` is the shape this covers.
                if delegating.iter().any(|f| f == word) {
                    if let Some(Tok::Word(argument)) = tokens.get(i + 1) {
                        if !argument.starts_with('-') {
                            scan.commands.push((argument.clone(), line));
                        }
                    }
                }
                expect = false;
                i += 1;
            }
        }
    }
}

/// Functions whose body passes `"$@"` through: their arguments are commands.
fn delegating_functions(lines: &[&str]) -> Vec<String> {
    let mut out = Vec::new();
    for (idx, line) in lines.iter().enumerate() {
        let trimmed = line.trim();
        let Some(paren) = trimmed.find("()") else {
            continue;
        };
        let name = trimmed[..paren].trim();
        if name.is_empty() || !name.chars().all(|c| c.is_alphanumeric() || c == '_') {
            continue;
        }
        let end = (idx + 12).min(lines.len());
        if lines[idx..end]
            .iter()
            .any(|l| l.contains("\"$@\"") || l.contains("$@"))
        {
            out.push(name.to_string());
        }
    }
    out
}

fn detect_functions(tokens: &[Tok]) -> Vec<String> {
    let mut out = Vec::new();
    for window in tokens.windows(3) {
        if let [Tok::Word(name), Tok::Sep, Tok::Sep] = window {
            out.push(name.clone());
        }
    }
    out
}

fn guarded_kill(lines: &[&str], kill_index: usize) -> bool {
    let start = kill_index.saturating_sub(15);
    for line in &lines[start..kill_index] {
        let code = strip_comment(line);
        let mentions_comm = code.contains("comm");
        let equality = code.contains("-qx")
            || code.contains("-q ")
            || code.contains("==")
            || code.contains("!=")
            || code.contains(" = ");
        if mentions_comm && equality {
            return true;
        }
    }
    false
}

pub fn scan_source(text: &str) -> Scan {
    let lines: Vec<&str> = text.lines().collect();
    let mut scan = Scan::default();
    let delegating = delegating_functions(&lines);

    for (idx, raw) in lines.iter().enumerate() {
        let line_no = idx + 1;
        let code = strip_comment(raw);

        if scan.set_euo.is_none() {
            let trimmed = code.trim();
            if trimmed.starts_with("set ") && trimmed.contains("pipefail") {
                let flags = trimmed.split_whitespace().collect::<Vec<_>>();
                if flags.iter().any(|f| f.contains('e')) && flags.iter().any(|f| f.contains('u')) {
                    scan.set_euo = Some(line_no);
                }
            }
        }

        for target in absolute_writes(raw) {
            let class = classify(&target);
            scan.writes.push(AbsWrite {
                line: line_no,
                target,
                class,
            });
        }

        let tokens = tokenize(code);
        for name in detect_functions(&tokens) {
            if !scan.functions.contains(&name) {
                scan.functions.push(name);
            }
        }
        command_lines(&tokens, line_no, &mut scan, &delegating);

        // Privileged operations, by exact word.
        for (i, token) in tokens.iter().enumerate() {
            let Tok::Word(word) = token else { continue };
            let label: Option<&str> = match word.as_str() {
                "kill" => Some("kill"),
                "modprobe" => Some(
                    if matches!(tokens.get(i + 1), Some(Tok::Word(w)) if w == "-r") {
                        "modprobe -r"
                    } else {
                        "modprobe"
                    },
                ),
                "rmmod" => Some("rmmod"),
                "insmod" => Some("insmod"),
                "auto-cpufreq" => Some("auto-cpufreq"),
                "sudo" => Some("sudo"),
                "id" => Some("id"),
                "notify-send" => Some("notify-send"),
                _ => None,
            };
            if let Some(label) = label {
                scan.privileged.push((label.to_string(), line_no));
            }
        }

        // Command substitutions: `$(` and backticks. Quote-aware, so a `$(` in
        // a single-quoted sed expression is not a substitution.
        let mut single = false;
        let mut double = false;
        let chars: Vec<char> = code.chars().collect();
        let mut i = 0;
        while i < chars.len() {
            match chars[i] {
                '\'' if !double => single = !single,
                '"' if !single => double = !double,
                '`' if !single => {
                    scan.substitutions.push((line_no, "`…`".to_string()));
                }
                '$' if !single && chars.get(i + 1) == Some(&'(') => {
                    let snippet: String = chars
                        .iter()
                        .skip(i)
                        .take(40)
                        .collect::<String>()
                        .replace('\n', " ");
                    scan.substitutions
                        .push((line_no, format!("$({}", snippet.trim_start_matches("$("))));
                }
                _ => {}
            }
            i += 1;
        }

        // Dangerous capabilities by word.
        for token in &tokens {
            if let Tok::Word(word) = token {
                if DANGEROUS.contains(&word.as_str()) {
                    scan.dangerous.push((word.clone(), line_no));
                }
            }
        }
        for window in tokens.windows(2) {
            if let [Tok::Word(shell), Tok::Word(flag)] = window {
                if matches!(shell.as_str(), "sh" | "bash" | "zsh") && flag == "-c" {
                    scan.dangerous.push((format!("{shell} -c"), line_no));
                }
            }
        }
    }

    // Duplicate privileged entries are noise; keep the first of each (kind, line).
    let mut seen = std::collections::BTreeSet::new();
    scan.privileged
        .retain(|(kind, line)| seen.insert((kind.clone(), *line)));
    scan.dangerous.sort_by_key(|(_, line)| *line);

    for (idx, raw) in lines.iter().enumerate() {
        if strip_comment(raw).split_whitespace().any(|w| w == "kill") {
            if !guarded_kill(&lines, idx) {
                scan.unguarded_kills.push(idx + 1);
            }
        }
    }

    scan
}

/// One `ln -sfn <target> <link>` pair from an activation script.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ActivationLink {
    pub target: String,
    pub link: String,
}

pub fn parse_activation_links(text: &str) -> Vec<ActivationLink> {
    let mut out = Vec::new();
    for line in text.lines() {
        let parts: Vec<&str> = line.split_whitespace().collect();
        if parts.len() >= 4 && parts[0] == "ln" && parts[1] == "-sfn" {
            out.push(ActivationLink {
                target: parts[2].to_string(),
                link: parts[3].to_string(),
            });
        }
    }
    out
}

/// The script body of a `writeShellApplication` output: drop the generated
/// shebang, the `set -o` lines from `bashOptions` and the `export PATH=` line
/// from `runtimeInputs`, keeping exactly the module's text.
pub fn store_body(store_text: &str) -> String {
    let mut lines = store_text.lines();
    let _shebang = lines.next();
    let mut body: Vec<&str> = Vec::new();
    let mut in_preamble = true;
    for line in lines {
        let trimmed = line.trim();
        if in_preamble
            && (trimmed.is_empty()
                || trimmed.starts_with("export PATH=")
                || trimmed.starts_with("set -o "))
        {
            continue;
        }
        in_preamble = false;
        body.push(line);
    }
    body.join("\n")
}

/// Is the store copy's script body identical to the source body?
///
/// `writeShellApplication` writes a generated shebang and an `export PATH=` line
/// from `runtimeInputs`, then the module's text (which had the source shebang
/// stripped) and one trailing newline. Everything it generates is skipped; what
/// remains must match the source byte for byte.
#[derive(Debug, Clone)]
pub struct BodyCompare {
    pub equal: bool,
    pub store_bytes: usize,
    pub source_bytes: usize,
    pub note: String,
}

pub fn compare_bodies(store_text: &str, source_text: &str) -> BodyCompare {
    let source_body: Vec<&str> = {
        let mut lines = source_text.lines();
        let first = lines.next().unwrap_or("");
        if first.starts_with("#!") {
            lines.collect()
        } else {
            std::iter::once(first).chain(lines).collect()
        }
    };

    let store_joined = store_body(store_text);
    let source_joined = source_body.join("\n");
    let equal = store_joined.trim_end_matches('\n') == source_joined.trim_end_matches('\n');
    let note = if equal {
        "byte-identical after the generated shebang/PATH preamble".to_string()
    } else {
        "content differs from the source".to_string()
    };

    BodyCompare {
        equal,
        store_bytes: store_text.len(),
        source_bytes: source_text.len(),
        note,
    }
}

/// Cut a Nix comment. Tracks double-quoted strings so `"#1e1e2e"` survives.
///
/// The multi-line `''` string is not modelled, so a `#` inside one still cuts
/// the line and this can see *less* text than the file holds. That is one of
/// the reasons the source grep below is informational only: the composed
/// sudoers text and the evaluated settings are the authority.
pub fn strip_nix_comment(line: &str) -> &str {
    let mut quoted = false;
    let mut escaped = false;
    for (i, c) in line.char_indices() {
        if escaped {
            escaped = false;
            continue;
        }
        match c {
            '\\' if quoted => escaped = true,
            '"' => quoted = !quoted,
            '#' if !quoted => return &line[..i],
            _ => {}
        }
    }
    line
}

/// One user spec from the composed sudoers file.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SudoSpec {
    pub line: usize,
    pub text: String,
    pub user: String,
    pub host: String,
    pub runas: Option<String>,
    pub tags: Vec<String>,
    pub command: String,
}

/// The audit of `config.security.sudo.configFile`.
///
/// The composed file is the ground truth: it is what sudo reads. `extraRules`
/// is one of several writers, and a source grep can be evaded by a rule that
/// lives in `extraConfig`, in another module, or by a non-`.nix` file, so
/// neither can be authoritative.
#[derive(Debug, Clone, Default)]
pub struct SudoersAudit {
    pub problems: Vec<String>,
    pub nopasswd: Vec<SudoSpec>,
    pub timeout_ok: bool,
}

impl SudoersAudit {
    pub fn ok(&self) -> bool {
        self.problems.is_empty()
    }

    /// The single accepted spec, rendered for the audit output.
    pub fn spec_line(&self) -> Option<String> {
        self.nopasswd.first().map(|spec| spec.text.clone())
    }
}

fn squeeze(text: &str) -> String {
    text.split_whitespace().collect::<Vec<_>>().join(" ")
}

/// Join `\` continuations, drop comments, and squeeze whitespace, so one entry
/// is one logical sudoers line.
fn sudoers_logical_lines(text: &str) -> Vec<(usize, String)> {
    let mut out = Vec::new();
    let mut buf = String::new();
    let mut start = 0usize;
    for (idx, raw) in text.lines().enumerate() {
        let line_no = idx + 1;
        let trimmed_end = raw.trim_end();
        let continues = trimmed_end.ends_with('\\');
        let piece = if continues {
            trimmed_end.trim_end_matches('\\')
        } else {
            raw
        };
        if buf.is_empty() {
            start = line_no;
        }
        buf.push_str(piece);
        if continues {
            buf.push(' ');
            continue;
        }
        let joined = strip_sudoers_comment(&squeeze(&buf));
        buf.clear();
        if !joined.is_empty() {
            out.push((start, joined));
        }
    }
    if !buf.is_empty() {
        let joined = strip_sudoers_comment(&squeeze(&buf));
        if !joined.is_empty() {
            out.push((start, joined));
        }
    }
    out
}

/// `#` starts a sudoers comment at the start of a line or after whitespace.
fn strip_sudoers_comment(line: &str) -> String {
    let bytes: Vec<char> = line.chars().collect();
    for (i, c) in bytes.iter().enumerate() {
        if *c == '#' && (i == 0 || bytes[i - 1].is_whitespace()) {
            return line
                .chars()
                .take(i)
                .collect::<String>()
                .trim_end()
                .to_string();
        }
    }
    line.trim_end().to_string()
}

/// Index of the first `needle` that is not inside parentheses.
fn find_outside_parens(line: &str, needle: char) -> Option<usize> {
    let mut depth = 0i32;
    for (i, c) in line.char_indices() {
        match c {
            '(' => depth += 1,
            ')' => depth -= 1,
            _ if c == needle && depth == 0 => return Some(i),
            _ => {}
        }
        if depth < 0 {
            return None;
        }
    }
    None
}

/// Parse the shape `<users> <hosts>=<runas>?<tags>: <command>`.
///
/// Anything that does not fit is a problem rather than a parse failure to be
/// ignored: an unparseable NOPASSWD line is exactly the case this audit exists
/// for.
fn parse_sudo_spec(line_no: usize, line: &str) -> Result<SudoSpec, String> {
    let eq = find_outside_parens(line, '=').ok_or_else(|| {
        format!("line {line_no}: no `=` between the user/host list and the command")
    })?;
    let left = line[..eq].trim();
    let right = line[eq + 1..].trim();

    let left_tokens: Vec<&str> = left.split_whitespace().collect();
    if left_tokens.len() != 2 {
        return Err(format!(
            "line {line_no}: expected `<user> <host>` before `=`, found {:?}",
            left
        ));
    }

    let mut rest = right;
    let mut runas = None;
    if rest.starts_with('(') {
        let close = rest
            .find(')')
            .ok_or_else(|| format!("line {line_no}: unbalanced `(` in the runas spec"))?;
        runas = Some(rest[..=close].to_string());
        rest = rest[close + 1..].trim();
    }

    let mut tags = Vec::new();
    loop {
        let Some(token) = rest.split_whitespace().next() else {
            break;
        };
        let Some(tag) = token.strip_suffix(':') else {
            break;
        };
        tags.push(tag.to_string());
        rest = rest[token.len()..].trim();
    }

    Ok(SudoSpec {
        line: line_no,
        text: squeeze(line),
        user: left_tokens[0].to_string(),
        host: left_tokens[1].to_string(),
        runas,
        tags,
        command: rest.to_string(),
    })
}

/// Audit the composed sudoers text: exactly one NOPASSWD spec, for the login
/// user, on `ALL`, with no extra tags and exactly the power.sh link as its one
/// command, plus `Defaults timestamp_timeout=0`.
pub fn audit_sudoers(text: &str, user: &str, power_link: &str) -> SudoersAudit {
    let mut audit = SudoersAudit::default();
    let lines = sudoers_logical_lines(text);

    if lines.is_empty() {
        audit
            .problems
            .push("the composed sudoers file is empty".to_string());
        return audit;
    }

    // An include pulls in rules this text does not show, so the audit would be
    // reading a subset of what sudo accepts. Fail closed.
    for (idx, raw) in text.lines().enumerate() {
        let trimmed = raw.trim_start().to_ascii_lowercase();
        if trimmed.starts_with("#include")
            || trimmed.starts_with("#includedir")
            || trimmed.starts_with("@include")
            || trimmed.starts_with("@includedir")
        {
            audit.problems.push(format!(
                "line {}: the composed sudoers file includes another file ({:?}); included rules \
                 are not audited",
                idx + 1,
                raw.trim()
            ));
        }
    }

    // `!authenticate` turns off password checking for whatever it applies to,
    // which is the same grant as NOPASSWD without the keyword.
    for (line_no, line) in &lines {
        if line.contains("!authenticate") {
            audit.problems.push(format!(
                "line {line_no}: {:?} disables sudo authentication; that is a passwordless root \
                 path outside the audited rule",
                line
            ));
        }
    }

    // Effective-value check, not presence: sudo applies Defaults in order and
    // a later assignment overrides an earlier one. Exactly one global
    // assignment, value 0. `Defaults:user`/`Defaults>host` do not disable the
    // login user's cache.
    let mut timeouts: Vec<(usize, bool, String)> = Vec::new();
    for (line_no, line) in &lines {
        let trimmed = line.trim();
        if !trimmed.starts_with("Defaults") {
            continue;
        }
        let rest = trimmed["Defaults".len()..].trim_start();
        // `Defaults!command` is command-scoped and does not disable the login
        // user's cache either; treat it like `:user`/`>host`/`@host`.
        let global = !rest.starts_with([':', '>', '@', '!']);
        let tokens: Vec<&str> = trimmed
            .split(|c: char| c.is_whitespace() || c == ',')
            .filter(|t| !t.is_empty())
            .collect();
        for (idx, token) in tokens.iter().enumerate() {
            let (key, inline) = match token.find('=') {
                Some(eq) => (&token[..eq], Some(token[eq + 1..].trim())),
                None => (*token, None),
            };
            if key.trim_end_matches(['+', '-']).trim() != "timestamp_timeout" {
                continue;
            }
            // sudoers permits spaces around `=`, so `timestamp_timeout = 600`
            // is three tokens and the value lives after the `=`.
            let mut value = inline.unwrap_or("").to_string();
            if value.is_empty() {
                for next in &tokens[idx + 1..] {
                    let next = next.strip_prefix('=').unwrap_or(next).trim();
                    if !next.is_empty() {
                        value = next.to_string();
                        break;
                    }
                }
            }
            timeouts.push((*line_no, global, value));
        }
    }
    audit.timeout_ok = timeouts.len() == 1 && timeouts[0].1 && timeouts[0].2 == "0";
    if !audit.timeout_ok {
        let detail = if timeouts.is_empty() {
            "no timestamp_timeout assignment".to_string()
        } else {
            timeouts
                .iter()
                .map(|(line, global, value)| {
                    format!(
                        "line {line}: {}timestamp_timeout={value}",
                        if *global { "" } else { "scoped " }
                    )
                })
                .collect::<Vec<_>>()
                .join(", ")
        };
        audit.problems.push(format!(
            "the sudo credential cache must be disabled by exactly one global \
             `Defaults timestamp_timeout=0`; found {detail}"
        ));
    }

    let nopasswd_lines: Vec<&(usize, String)> = lines
        .iter()
        .filter(|(_, l)| l.contains("NOPASSWD"))
        .collect();
    if nopasswd_lines.len() != 1 {
        audit.problems.push(format!(
            "expected exactly one spec containing NOPASSWD in the composed sudoers file, found {}: {}",
            nopasswd_lines.len(),
            nopasswd_lines
                .iter()
                .map(|(l, text)| format!("line {l}: {text}"))
                .collect::<Vec<_>>()
                .join(" | ")
        ));
        return audit;
    }

    let (line_no, line) = nopasswd_lines[0];
    let spec = match parse_sudo_spec(*line_no, line) {
        Ok(spec) => spec,
        Err(err) => {
            audit.problems.push(err);
            return audit;
        }
    };
    audit.nopasswd.push(spec.clone());

    if spec.user.starts_with('%') {
        audit.problems.push(format!(
            "line {}: the NOPASSWD spec applies to the group {}, not the login user {user}",
            spec.line, spec.user
        ));
    } else if spec.user != user {
        audit.problems.push(format!(
            "line {}: the NOPASSWD spec applies to {:?}, expected the login user {:?}",
            spec.line, spec.user, user
        ));
    }

    if spec.host != "ALL" {
        audit.problems.push(format!(
            "line {}: the NOPASSWD spec is limited to host {:?}, expected ALL",
            spec.line, spec.host
        ));
    }

    const RUNAS: &[&str] = &["(ALL)", "(ALL:ALL)", "(root)", "(root:root)"];
    match spec.runas.as_deref() {
        Some(runas) if RUNAS.contains(&runas) => {}
        Some(other) => audit.problems.push(format!(
            "line {}: runas {other:?} is not one of (ALL), (ALL:ALL), (root), (root:root)",
            spec.line
        )),
        None => audit.problems.push(format!(
            "line {}: the NOPASSWD spec has no explicit runas; expected (root) or (ALL)",
            spec.line
        )),
    }

    if spec.tags != vec!["NOPASSWD".to_string()] {
        audit.problems.push(format!(
            "line {}: the NOPASSWD spec carries tags {:?}; only NOPASSWD is allowed (no SETENV, \
             NOEXEC, FOLLOW, PASSWD, LOG_INPUT, LOG_OUTPUT, MAIL or anything else)",
            spec.line, spec.tags
        ));
    }

    if spec.command.is_empty() {
        audit.problems.push(format!(
            "line {}: the NOPASSWD spec has no command",
            spec.line
        ));
    } else if spec.command != power_link {
        audit.problems.push(format!(
            "line {}: the NOPASSWD command is {:?}, expected exactly {:?} (no wildcard, no ALL, \
             no second command)",
            spec.line, spec.command, power_link
        ));
    }

    audit
}

/// A non-authoritative grep: how many NOPASSWD mentions the checked-in sources
/// carry, and which app modules mention sudo. A rule can be added by a module
/// this list does not know, or by a file that is not `.nix`, so these numbers
/// are context, not evidence.
#[derive(Debug, Clone, Default)]
pub struct SourceHits {
    pub nopasswd: Vec<(String, usize)>,
    pub sudo_mentions: Vec<String>,
}

pub fn scan_sources(files: &[(String, String)], apps_rel: &[String]) -> SourceHits {
    let mut hits = SourceHits::default();
    for (path, text) in files {
        // Only Nix expressions can generate a sudoers rule; Rust tests and docs
        // mentioning the word would drown the count that matters.
        if !path.ends_with(".nix") {
            continue;
        }
        for (idx, line) in text.lines().enumerate() {
            if line.contains("NOPASSWD") {
                hits.nopasswd.push((path.clone(), idx + 1));
            }
        }
    }
    for rel in apps_rel {
        let Some((_, text)) = files.iter().find(|(path, _)| path == rel) else {
            continue;
        };
        for (idx, line) in text.lines().enumerate() {
            if line.contains("sudo") {
                hits.sudo_mentions.push(format!("{rel}:{}", idx + 1));
            }
        }
    }
    hits
}

/// Runtime link facts: where the path resolves, who owns it, and whether it is
/// writable by anyone but root.
#[derive(Debug, Clone)]
pub struct LinkState {
    pub link: String,
    pub resolved: Option<String>,
    pub uid: Option<u32>,
    pub mode: Option<u32>,
    pub problems: Vec<String>,
}

impl LinkState {
    pub fn ok(&self) -> bool {
        self.problems.is_empty()
    }
}

pub fn inspect_link(link: &str) -> LinkState {
    use std::os::unix::fs::MetadataExt;
    let mut state = LinkState {
        link: link.to_string(),
        resolved: None,
        uid: None,
        mode: None,
        problems: Vec::new(),
    };

    // A link the login user owns or can write is not a root helper boundary.
    if let Some(home) = std::env::var_os("HOME") {
        let home = PathBuf::from(home);
        if Path::new(link).starts_with(&home) {
            state.problems.push(format!(
                "{link} is under $HOME ({}): the sudo rule must point outside the user's own tree",
                home.display()
            ));
        }
    }

    // lstat the link itself: it has to exist and be the symlink activation made.
    match std::fs::symlink_metadata(link) {
        Ok(md) if !md.file_type().is_symlink() => state
            .problems
            .push(format!("{link} exists but is not a symlink")),
        Ok(_) => {}
        Err(err) => {
            state
                .problems
                .push(format!("{link} does not exist or is not readable: {err}"));
            return state;
        }
    }

    // The parent chain decides whether anyone but root can replace the link.
    let mut parent = Path::new(link).parent();
    while let Some(dir) = parent {
        if dir.as_os_str().is_empty() || dir == Path::new("/") {
            break;
        }
        match std::fs::metadata(dir) {
            Ok(md) => {
                if md.uid() != 0 {
                    state.problems.push(format!(
                        "{} (parent of {link}) is owned by uid {}, not root",
                        dir.display(),
                        md.uid()
                    ));
                }
                if md.mode() & 0o022 != 0 {
                    state.problems.push(format!(
                        "{} (parent of {link}) is group/other writable (mode {:04o})",
                        dir.display(),
                        md.mode() & 0o7777
                    ));
                }
            }
            Err(err) => {
                state.problems.push(format!(
                    "cannot stat {} (parent of {link}): {err}",
                    dir.display()
                ));
                break;
            }
        }
        parent = dir.parent();
    }

    let Ok(resolved) = std::fs::canonicalize(link) else {
        state
            .problems
            .push(format!("{link} does not exist or does not resolve"));
        return state;
    };
    let resolved_str = resolved.display().to_string();
    if !resolved_str.starts_with("/nix/store/") {
        state.problems.push(format!(
            "{link} resolves to {resolved_str}, which is outside /nix/store and writable in principle"
        ));
    }
    match std::fs::metadata(&resolved) {
        Ok(md) => {
            state.uid = Some(md.uid());
            state.mode = Some(md.mode());
            if md.uid() != 0 {
                state
                    .problems
                    .push(format!("{resolved_str} is owned by uid {}", md.uid()));
            }
            if md.mode() & 0o022 != 0 {
                state.problems.push(format!(
                    "{resolved_str} is group/other writable (mode {:04o})",
                    md.mode() & 0o7777
                ));
            }
        }
        Err(err) => state
            .problems
            .push(format!("cannot stat {resolved_str}: {err}")),
    }
    state.resolved = Some(resolved_str);
    state
}

/// Commands the closure provides, mapped to the store path that ships them.
pub fn closure_commands(paths: &[String]) -> std::collections::BTreeMap<String, String> {
    let mut map = std::collections::BTreeMap::new();
    for path in paths {
        for dir in ["bin", "sbin"] {
            let Ok(entries) = std::fs::read_dir(Path::new(path).join(dir)) else {
                continue;
            };
            for entry in entries.flatten() {
                if let Some(name) = entry.file_name().to_str() {
                    map.insert(name.to_string(), path.clone());
                }
            }
        }
    }
    map
}

/// Which provider package the invoked command came from, given the closure.
pub fn provider<'a>(
    command: &str,
    available: &'a std::collections::BTreeMap<String, String>,
) -> Option<&'a str> {
    available.get(command).map(String::as_str)
}

/// Does the provider correspond to one of the module's `runtimeInputs`?
pub fn in_runtime_inputs(provider_path: &str, runtime_inputs: &[String]) -> bool {
    let Some(sp) = crate::storepath::parse(provider_path) else {
        return false;
    };
    let (name, _) = sp.split();
    runtime_inputs
        .iter()
        .any(|ri| name == *ri || name.ends_with(&format!("-{ri}")))
}

pub fn shellcheck(file: &Path) -> Result<Option<String>> {
    if crate::cmd::which("shellcheck").is_none() {
        return Ok(None);
    }
    let out = crate::cmd::run(
        "shellcheck",
        &[
            "-S".to_string(),
            "warning".to_string(),
            "-f".to_string(),
            "gcc".to_string(),
            file.display().to_string(),
        ],
    )?;
    let mut text = out.stdout.trim().to_string();
    let stderr = out.stderr.trim();
    if !stderr.is_empty() {
        if !text.is_empty() {
            text.push('\n');
        }
        text.push_str(stderr);
    }
    Ok(Some(text))
}

pub fn unified_diff(old_path: &Path, new_text: &str, label: &str) -> Result<String> {
    let tmp = crate::cmd::temp_file(label)?;
    let result = (|| -> Result<String> {
        std::fs::write(&tmp, new_text)?;
        let diff = crate::cmd::diff()?;
        let out = crate::cmd::run(
            &diff,
            &[
                "-u".to_string(),
                old_path.display().to_string(),
                tmp.display().to_string(),
            ],
        )?;
        // 0 = same, 1 = different; anything else is diff failing and an empty
        // diff would otherwise read as "no change".
        if !matches!(out.status.code(), Some(0) | Some(1)) {
            bail!(
                "diff failed ({}): {}",
                out.status,
                crate::cmd::tail(&out.stderr, 10)
            );
        }
        Ok(out.stdout)
    })();
    let _ = std::fs::remove_file(&tmp);
    result
}

/// One sudo invocation found in the compositor configuration.
#[derive(Debug, Clone, Default)]
pub struct KeybindAudit {
    pub problems: Vec<String>,
    pub sudo_calls: usize,
}

impl KeybindAudit {
    pub fn ok(&self) -> bool {
        self.problems.is_empty()
    }
}

fn is_sudo_option(token: &str) -> bool {
    token.starts_with('-')
}

fn audit_sudo_string(value: &str, path: &str, power_link: &str, audit: &mut KeybindAudit) {
    if !value.contains("sudo") {
        return;
    }
    let tokens: Vec<&str> = value.split_whitespace().collect();
    let positions: Vec<usize> = tokens
        .iter()
        .enumerate()
        .filter(|(_, token)| **token == "sudo")
        .map(|(idx, _)| idx)
        .collect();
    if positions.is_empty() {
        audit.problems.push(format!(
            "{path}: mentions `sudo` but not as a whitespace-delimited command word"
        ));
        return;
    }
    for idx in positions {
        audit.sudo_calls += 1;
        match tokens.get(idx + 1) {
            None => audit
                .problems
                .push(format!("{path}: `sudo` with no command")),
            Some(next) if is_sudo_option(next) => audit.problems.push(format!(
                "{path}: `sudo {next}` passes a sudo option; the keybind must call {power_link} \
                 directly"
            )),
            Some(next) if *next != power_link => audit.problems.push(format!(
                "{path}: `sudo {next}` does not target {power_link}"
            )),
            Some(_) => {}
        }
    }
}

fn walk_sudo(value: &Value, path: &str, power_link: &str, audit: &mut KeybindAudit) {
    match value {
        Value::Array(items) => {
            // The argv shape: `spawn [ "sudo" <link> ... ]`. Matching it as one
            // unit avoids reading its elements as free-standing strings.
            if items.first().and_then(Value::as_str) == Some("sudo") {
                audit.sudo_calls += 1;
                match items.get(1).and_then(Value::as_str) {
                    Some(second) if second == power_link => {}
                    Some(second) if is_sudo_option(second) => audit.problems.push(format!(
                        "{path}: argv `sudo {second}` passes a sudo option; the keybind must call \
                         {power_link} directly"
                    )),
                    Some(second) => audit.problems.push(format!(
                        "{path}: argv `sudo {second}` does not target {power_link}"
                    )),
                    None => audit
                        .problems
                        .push(format!("{path}: argv `sudo` with no command")),
                }
                return;
            }
            for (idx, item) in items.iter().enumerate() {
                walk_sudo(item, &format!("{path}[{idx}]"), power_link, audit);
            }
        }
        Value::Object(map) => {
            for (key, item) in map {
                walk_sudo(item, &format!("{path}.{key}"), power_link, audit);
            }
        }
        Value::String(text) => audit_sudo_string(text, path, power_link, audit),
        _ => {}
    }
}

/// Every sudo call in the evaluated compositor settings must target the power
/// link, with no sudo options in between.
///
/// The source grep this replaces missed the `argv = [ "sudo" <link> ... ]`
/// shape and tabs; the evaluated tree is the same data the compositor reads.
pub fn audit_keybinds(settings: &Value, power_link: &str) -> KeybindAudit {
    let mut audit = KeybindAudit::default();
    walk_sudo(settings, "settings", power_link, &mut audit);
    audit
}

/// Scan the rendered niri config for sudo calls. This is the authoritative
/// keybind check: `programs.niri.config` overrides `settings` wholesale, so the
/// KDL that niri reads is the only source that cannot be shadowed.
pub fn audit_niri_config(config: &str, power_link: &str) -> KeybindAudit {
    let mut audit = KeybindAudit::default();
    // A full-line KDL comment is documentation, not a spawn. (Inline `//`
    // stripping would need quote awareness; the renderer emits none here.)
    let config = config
        .lines()
        .filter(|line| !line.trim_start().starts_with("//"))
        .collect::<Vec<_>>()
        .join("\n");
    let bytes = config.as_bytes();
    let is_word = |b: u8| b.is_ascii_alphanumeric() || b == b'_' || b == b'-';
    let mut i = 0usize;
    while i + 4 <= bytes.len() {
        let Some(rel) = config[i..].find("sudo") else {
            break;
        };
        let start = i + rel;
        let end = start + 4;
        let before_ok = start == 0 || !is_word(bytes[start - 1]);
        let after_ok = end == bytes.len() || !is_word(bytes[end]);
        i = end;
        if !before_ok || !after_ok {
            continue;
        }
        audit.sudo_calls += 1;

        // Skip whitespace and the quote that closes this token: both
        // `spawn-at-startup "sudo" "/path"` and `"sudo /path"` reduce to the
        // next bare token.
        let mut chars = config[end..].char_indices().peekable();
        while let Some((_, c)) = chars.peek() {
            if c.is_whitespace() || *c == '"' || *c == '\'' {
                chars.next();
            } else {
                break;
            }
        }
        let mut token = String::new();
        while let Some((_, c)) = chars.peek() {
            if c.is_whitespace() || matches!(c, '"' | '\'' | ';' | '{' | '}') {
                break;
            }
            token.push(*c);
            chars.next();
        }
        if token.is_empty() {
            audit
                .problems
                .push("`sudo` with no command in the rendered niri config".to_string());
        } else if is_sudo_option(&token) {
            audit.problems.push(format!(
                "`sudo {token}` passes an option; the keybind must call {power_link} directly"
            ));
        } else if token != power_link {
            audit.problems.push(format!(
                "the rendered niri config calls `sudo {token}`, not {power_link}"
            ));
        }
    }
    audit
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn real_power_sh() -> String {
        // The nix build bakes the live script in, so the sandbox scans the real
        // helper rather than a fixture that may have drifted.
        if let Some(text) = option_env!("DOTS_POWER_SH") {
            return text.to_string();
        }
        if let Some(dir) = std::env::var_os("DOTS_DOTFILES") {
            let path = Path::new(&dir).join("scripts/power.sh");
            if let Ok(text) = std::fs::read_to_string(&path) {
                return text;
            }
        }
        include_str!("../tests/fixtures/power.sh").to_string()
    }

    #[test]
    fn scans_the_real_power_script() {
        let text = real_power_sh();
        let scan = scan_source(&text);

        assert!(scan.set_euo.is_some(), "set -euo pipefail must be found");

        let targets: Vec<&str> = scan.writes.iter().map(|w| w.target.as_str()).collect();
        assert!(targets.contains(&"/sys/class/backlight/asus_screenpad/bl_power"));
        assert!(targets.contains(&"/sys/bus/pci/devices/0000:01:00.0/remove"));
        assert!(targets.contains(&"/sys/bus/pci/rescan"));
        assert!(
            scan.flagged_writes().is_empty(),
            "unexpected absolute writes: {:?}",
            scan.flagged_writes()
        );
        assert!(scan
            .writes
            .iter()
            .all(|w| w.class == WriteClass::Sysfs || w.class == WriteClass::Device));

        let privileged: Vec<&str> = scan.privileged.iter().map(|(k, _)| k.as_str()).collect();
        assert!(privileged.contains(&"modprobe -r"));
        assert!(privileged.contains(&"modprobe"));
        assert!(privileged.contains(&"kill"));
        assert!(privileged.contains(&"auto-cpufreq"));
        assert!(privileged.contains(&"notify-send"));

        // Both kills sit behind a /proc/<pid>/comm equality guard.
        assert_eq!(
            scan.privileged.iter().filter(|(k, _)| k == "kill").count(),
            2
        );
        assert!(
            scan.unguarded_kills.is_empty(),
            "unguarded kills: {:?}",
            scan.unguarded_kills
        );

        // No network tools, no destructive general-purpose commands.
        assert!(scan.network_commands().is_empty());
        assert!(
            scan.dangerous.is_empty(),
            "unexpected capability words: {:?}",
            scan.dangerous
        );

        // Substitutions: the sudo uid lookup and the pid enumeration twice.
        assert_eq!(
            scan.substitutions
                .iter()
                .map(|(line, _)| *line)
                .collect::<Vec<_>>(),
            vec![14, 40, 57]
        );

        let invoked = scan.invoked();
        for cmd in [
            "auto-cpufreq",
            "grep",
            "id",
            "kill",
            "ls",
            "lsmod",
            "modprobe",
            "notify-send",
            "sed",
            "sleep",
            "sort",
            "sudo",
        ] {
            assert!(
                invoked.contains(&cmd.to_string()),
                "missing invoked command {cmd}: {invoked:?}"
            );
        }
        // Shell functions are called like commands and are defined in the script.
        assert!(scan.functions.contains(&"run_user_cmd".to_string()));
        // Builtins and keywords are not commands.
        assert!(!invoked.contains(&"echo".to_string()));
        assert!(!invoked.contains(&"if".to_string()));
        assert!(!invoked.contains(&"[".to_string()));
    }

    #[test]
    fn fixture_matches_the_live_script() {
        // `DOTS_POWER_SH` is set by pkgs/dots/default.nix from the repo's
        // scripts/power.sh, so this runs in the nix sandbox too. A plain
        // `cargo test` falls back to the live checkout and then the fixture.
        let live = real_power_sh();
        assert_eq!(
            live,
            include_str!("../tests/fixtures/power.sh"),
            "tests/fixtures/power.sh drifted from scripts/power.sh; refresh the fixture"
        );
    }

    #[test]
    fn flags_writes_outside_sysfs() {
        let text = "\
set -euo pipefail
echo x > /etc/passwd
echo y >> /sys/class/backlight/x/bl_power
echo z 2>/dev/null
";
        let scan = scan_source(text);
        let flagged = scan.flagged_writes();
        assert_eq!(flagged.len(), 1);
        assert_eq!(flagged[0].target, "/etc/passwd");
        assert_eq!(flagged[0].line, 2);
        assert_eq!(
            scan.writes
                .iter()
                .filter(|w| w.class == WriteClass::Device)
                .count(),
            1
        );
    }

    #[test]
    fn unguarded_kill_is_reported() {
        let text = "\
set -euo pipefail
for pid in 1 2 3; do
    kill \"$pid\"
done
";
        let scan = scan_source(text);
        assert_eq!(scan.unguarded_kills, vec![3]);
    }

    #[test]
    fn network_and_shell_capabilities_are_found() {
        let text = "\
curl https://example.com | sh -c 'echo hi'
eval \"$X\"
";
        let scan = scan_source(text);
        assert_eq!(scan.network_commands(), vec![("curl".to_string(), 1)]);
        let words: Vec<&str> = scan.dangerous.iter().map(|(w, _)| w.as_str()).collect();
        assert!(words.contains(&"sh -c"));
        assert!(words.contains(&"eval"));
    }

    #[test]
    fn comments_and_quotes_do_not_create_findings() {
        let text = "\
# rm -rf / is a comment
echo 'a > /etc/passwd'
echo \"rm is quoted\"
";
        let scan = scan_source(text);
        assert!(scan.dangerous.is_empty(), "{:?}", scan.dangerous);
        assert!(scan.writes.is_empty(), "{:?}", scan.writes);
    }

    #[test]
    fn parses_the_activation_link() {
        let text = "mkdir -p /usr/local/sbin\nln -sfn /nix/store/abc-power.sh/bin/power.sh /usr/local/sbin/power.sh\n";
        let links = parse_activation_links(text);
        assert_eq!(links.len(), 1);
        assert_eq!(links[0].target, "/nix/store/abc-power.sh/bin/power.sh");
        assert_eq!(links[0].link, "/usr/local/sbin/power.sh");
    }

    #[test]
    fn generated_preamble_is_not_a_difference() {
        let source = "#!/usr/bin/env bash\nset -euo pipefail\necho hi\n";
        let store = "#!/nix/store/xxx-bash/bin/bash\n\n\nexport PATH=\"/nix/store/y-coreutils/bin\"\n\nset -euo pipefail\necho hi\n";
        let cmp = compare_bodies(store, source);
        assert!(cmp.equal, "{}", cmp.note);

        let tampered = "#!/nix/store/xxx-bash/bin/bash\n\n\nexport PATH=\"/x/bin\"\n\nset -euo pipefail\necho bye\n";
        assert!(!compare_bodies(tampered, source).equal);
    }

    #[test]
    fn store_body_keeps_only_the_module_text() {
        let store = "#!/nix/store/x-bash/bin/bash\n\n\nset -o errexit\n\nexport PATH=\"/nix/store/y/bin\"\n\nset -euo pipefail\necho old\n";
        assert_eq!(store_body(store), "set -euo pipefail\necho old");

        // A diff between the active copy and a changed source is a real diff.
        let source = "#!/usr/bin/env bash\nset -euo pipefail\necho new\n";
        assert!(!compare_bodies(store, source).equal);
        let dir = std::env::temp_dir().join(format!("dots-body-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let prev = dir.join("prev");
        std::fs::write(&prev, store_body(store)).unwrap();
        let diff = unified_diff(&prev, source, "body").unwrap();
        assert!(diff.contains("-echo old"), "{diff}");
        assert!(diff.contains("+echo new"), "{diff}");
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// The composed sudoers text this machine evaluates, verbatim. The parser
    /// must accept the real output, not a hand-simplified approximation.
    const REAL_SUDOERS: &str = "\
# Don't edit this file. Set the NixOS options ‘security.sudo.configFile’
# or ‘security.sudo.extraRules’ instead.

root     ALL=(ALL:ALL)    SETENV: ALL
%wheel  ALL=(ALL:ALL)    SETENV: ALL
duskyelf     ALL=(ALL:ALL)    NOPASSWD: /usr/local/sbin/power.sh


# extraConfig
Defaults timestamp_timeout=0
Defaults env_keep+=NIXOS_NO_CHECK



# Keep terminfo database for root and %wheel.
Defaults:root,%wheel env_keep+=TERMINFO_DIRS
Defaults:root,%wheel env_keep+=TERMINFO

";

    const USER: &str = "duskyelf";
    const LINK: &str = "/usr/local/sbin/power.sh";

    fn composed_with_rule(rule: &str) -> String {
        REAL_SUDOERS.replace(
            "duskyelf     ALL=(ALL:ALL)    NOPASSWD: /usr/local/sbin/power.sh",
            rule,
        )
    }

    #[test]
    fn accepts_the_real_composed_sudoers_file() {
        let audit = audit_sudoers(REAL_SUDOERS, USER, LINK);
        assert!(audit.ok(), "{:?}", audit.problems);
        assert_eq!(audit.nopasswd.len(), 1);
        assert!(audit.timeout_ok);
        let spec = audit.spec_line().unwrap();
        assert_eq!(
            spec,
            "duskyelf ALL=(ALL:ALL) NOPASSWD: /usr/local/sbin/power.sh"
        );
    }

    #[test]
    fn line_continuations_are_joined() {
        let text = composed_with_rule(
            "duskyelf     ALL=(ALL:ALL)    NOPASSWD: \\\n    /usr/local/sbin/power.sh",
        );
        let audit = audit_sudoers(&text, USER, LINK);
        assert!(audit.ok(), "{:?}", audit.problems);
    }

    #[test]
    fn a_second_nopasswd_hidden_in_extra_config_is_a_failure() {
        let text = format!(
            "{REAL_SUDOERS}Defaults timestamp_timeout=0\n{USER} ALL=(ALL) NOPASSWD: /bin/sh\n"
        );
        let audit = audit_sudoers(&text, USER, LINK);
        assert!(!audit.ok());
        assert!(
            audit
                .problems
                .iter()
                .any(|p| p.contains("exactly one spec containing NOPASSWD")),
            "{:?}",
            audit.problems
        );

        // The same rule hidden behind a group is no better.
        let group = format!("{REAL_SUDOERS}%wheel ALL=(ALL:ALL) NOPASSWD: ALL\n");
        let audit = audit_sudoers(&group, USER, LINK);
        assert!(!audit.ok());
    }

    #[test]
    fn a_group_grant_replacing_the_login_user_is_a_failure() {
        let text = composed_with_rule("%wheel ALL=(ALL:ALL) NOPASSWD: /usr/local/sbin/power.sh");
        let audit = audit_sudoers(&text, USER, LINK);
        assert!(!audit.ok());
        assert!(
            audit.problems.iter().any(|p| p.contains("group %wheel")),
            "{:?}",
            audit.problems
        );
    }

    #[test]
    fn a_second_user_is_a_failure() {
        let text = composed_with_rule(
            "duskyelf,backdoor ALL=(ALL:ALL) NOPASSWD: /usr/local/sbin/power.sh",
        );
        let audit = audit_sudoers(&text, USER, LINK);
        assert!(!audit.ok());
        assert!(
            audit
                .problems
                .iter()
                .any(|p| p.contains("expects the login user")
                    || p.contains("expected the login user")),
            "{:?}",
            audit.problems
        );
    }

    #[test]
    fn a_second_command_is_a_failure() {
        let text = composed_with_rule(
            "duskyelf ALL=(ALL:ALL) NOPASSWD: /usr/local/sbin/power.sh, /bin/sh",
        );
        let audit = audit_sudoers(&text, USER, LINK);
        assert!(!audit.ok());
        assert!(
            audit
                .problems
                .iter()
                .any(|p| p.contains("expected exactly")),
            "{:?}",
            audit.problems
        );
    }

    #[test]
    fn extra_tags_are_a_failure() {
        for tags in [
            "NOPASSWD: SETENV: /usr/local/sbin/power.sh",
            "SETENV: NOPASSWD: /usr/local/sbin/power.sh",
            "NOPASSWD: NOEXEC: FOLLOW: /usr/local/sbin/power.sh",
        ] {
            let text = composed_with_rule(&format!("duskyelf ALL=(ALL:ALL) {tags}"));
            let audit = audit_sudoers(&text, USER, LINK);
            assert!(!audit.ok(), "tags {tags:?} were accepted");
            assert!(
                audit.problems.iter().any(|p| p.contains("carries tags")),
                "{tags:?}: {:?}",
                audit.problems
            );
        }
    }

    #[test]
    fn a_wildcard_command_is_a_failure() {
        let text = composed_with_rule("duskyelf ALL=(ALL:ALL) NOPASSWD: /usr/local/sbin/*");
        let audit = audit_sudoers(&text, USER, LINK);
        assert!(!audit.ok());
        assert!(
            audit.problems.iter().any(|p| p.contains("no wildcard")),
            "{:?}",
            audit.problems
        );

        let all = composed_with_rule("duskyelf ALL=(ALL:ALL) NOPASSWD: ALL");
        assert!(!audit_sudoers(&all, USER, LINK).ok());
    }

    #[test]
    fn a_different_host_or_runas_is_a_failure() {
        let host =
            composed_with_rule("duskyelf localhost=(ALL:ALL) NOPASSWD: /usr/local/sbin/power.sh");
        assert!(!audit_sudoers(&host, USER, LINK).ok());

        let runas = composed_with_rule("duskyelf ALL=(nobody) NOPASSWD: /usr/local/sbin/power.sh");
        assert!(!audit_sudoers(&runas, USER, LINK).ok());

        // (root) and (ALL:ALL) are both accepted: the command is what is pinned.
        for ok_runas in ["(ALL)", "(ALL:ALL)", "(root)", "(root:root)"] {
            let text = composed_with_rule(&format!(
                "duskyelf ALL={ok_runas} NOPASSWD: /usr/local/sbin/power.sh"
            ));
            let audit = audit_sudoers(&text, USER, LINK);
            assert!(audit.ok(), "{ok_runas}: {:?}", audit.problems);
        }
    }

    #[test]
    fn the_credential_cache_must_be_disabled() {
        let text = REAL_SUDOERS.replace("Defaults timestamp_timeout=0\n", "");
        let audit = audit_sudoers(&text, USER, LINK);
        assert!(!audit.ok());
        assert!(audit
            .problems
            .iter()
            .any(|p| p.contains("timestamp_timeout=0")));

        // A later assignment overrides the earlier one, even with spaces.
        for evil in [
            "Defaults timestamp_timeout = 600\n",
            "Defaults timestamp_timeout=600\n",
            "Defaults:duskyelf timestamp_timeout=600\n",
        ] {
            let text = format!("{REAL_SUDOERS}{evil}");
            let audit = audit_sudoers(&text, USER, LINK);
            assert!(!audit.ok(), "{evil:?} must be rejected");
        }

        // Scoped assignments do not disable the login user's cache.
        for scoped in [
            "Defaults:root timestamp_timeout=0\n",
            "Defaults>root timestamp_timeout=0\n",
            "Defaults!/usr/local/sbin/power.sh timestamp_timeout=0\n",
        ] {
            let text = text.clone() + scoped;
            let audit = audit_sudoers(&text, USER, LINK);
            assert!(!audit.ok(), "{scoped:?} must be rejected");
        }

        // Spaced `= 0`, and a spaced global zero, are valid sudoers.
        let spaced = format!(
            "{}Defaults timestamp_timeout = 0\n",
            REAL_SUDOERS.replace("Defaults timestamp_timeout=0\n", "")
        );
        assert!(audit_sudoers(&spaced, USER, LINK).ok());
    }

    #[test]
    fn the_composed_parser_rejects_an_empty_file() {
        assert!(!audit_sudoers("", USER, LINK).ok());
        assert!(!audit_sudoers("# no rules here\n", USER, LINK).ok());
    }

    #[test]
    fn included_files_and_authentication_off_are_failures() {
        for directive in [
            "@include /etc/sudoers.d/evil",
            "@includedir /etc/sudoers.d",
            "#include /etc/sudoers.d/evil",
            "#includedir /etc/sudoers.d",
        ] {
            let text = format!("{REAL_SUDOERS}{directive}\n");
            let audit = audit_sudoers(&text, USER, LINK);
            assert!(!audit.ok(), "{directive} was accepted");
            assert!(
                audit
                    .problems
                    .iter()
                    .any(|p| p.contains("includes another")),
                "{directive}: {:?}",
                audit.problems
            );
        }

        let text = format!("{REAL_SUDOERS}Defaults:{USER} !authenticate\n");
        let audit = audit_sudoers(&text, USER, LINK);
        assert!(!audit.ok());
        assert!(
            audit.problems.iter().any(|p| p.contains("!authenticate")),
            "{:?}",
            audit.problems
        );
    }

    #[test]
    fn source_grep_is_only_a_counter() {
        let files = vec![
            (
                "base/system.nix".to_string(),
                "          options = [ \"NOPASSWD\" ];\n".to_string(),
            ),
            (
                "apps/niri/settings.nix".to_string(),
                "          argv = [ \"sudo\" hostConfig.powerScriptPath ];\n".to_string(),
            ),
        ];
        let hits = scan_sources(&files, &["apps/niri/settings.nix".to_string()]);
        assert_eq!(hits.nopasswd.len(), 1);
        assert_eq!(hits.sudo_mentions, vec!["apps/niri/settings.nix:1"]);
        assert!(scan_sources(&[], &[]).nopasswd.is_empty());
    }

    #[test]
    fn the_keybind_walk_sees_every_sudo_shape() {
        let settings = json!({
            "binds": {
                "Mod+1": { "action": { "spawn": ["bash", "-c",
                    "sudo\t/usr/local/sbin/power.sh screenpad on"] } },
                "Mod+8": { "action": { "spawn": ["bash", "-c",
                    "sudo /usr/local/sbin/power.sh powersave"] } },
                "Mod+2": { "action": { "spawn": ["bash", "-c",
                    "sudo /usr/local/sbin/power.sh a; sudo /bin/sh"] } },
                "Mod+3": { "action": { "spawn": ["bash", "-c",
                    "pseudo-sudo launcher"] } }
            },
            "spawn-at-startup": [
                { "argv": ["sudo", "/usr/local/sbin/power.sh", "screenpad", "off"] },
                { "argv": ["sudo", "-n", "/usr/local/sbin/power.sh"] },
                { "argv": ["sudo", "/tmp/evil"] }
            ]
        });
        let audit = audit_keybinds(&settings, LINK);
        // Mod+1, Mod+8, both in Mod+2, and three argv = 7 calls.
        assert_eq!(audit.sudo_calls, 7);
        let joined = audit.problems.join("\n");
        assert!(
            joined.contains("does not target /usr/local/sbin/power.sh"),
            "{joined}"
        );
        assert!(joined.contains("passes a sudo option"), "{joined}");
        assert!(joined.contains("mentions `sudo` but not"), "{joined}");
        assert!(
            audit
                .problems
                .iter()
                .any(|p| p.contains("spawn-at-startup[2]")),
            "{joined}"
        );
    }

    #[test]
    fn the_keybind_walk_accepts_the_real_shapes() {
        let settings = json!({
            "binds": {
                "Mod+8": { "action": { "spawn": ["bash", "-c",
                    "sudo /usr/local/sbin/power.sh powersave"] } },
                "Mod+1": { "action": { "spawn": ["bash", "-c",
                    "if [ 1 = 1 ]; then\n  sudo /usr/local/sbin/power.sh screenpad off || true\nfi"] } },
                "Mod+T": { "action": { "spawn": ["kitty"] } }
            },
            "spawn-at-startup": [
                { "argv": ["sudo", "/usr/local/sbin/power.sh", "screenpad", "off"] }
            ]
        });
        let audit = audit_keybinds(&settings, LINK);
        assert!(audit.ok(), "{:?}", audit.problems);
        assert_eq!(audit.sudo_calls, 3);
    }

    #[test]
    fn rendered_niri_config_is_the_authority() {
        // The shape niri actually reads: binds as shell strings, startup as argv.
        let ok = r#"
            // sudo /bin/rm is documentation, not a spawn
            Mod+8 { spawn "bash" "-c" "sudo /usr/local/sbin/power.sh powersave"; }
            spawn-at-startup "sudo" "/usr/local/sbin/power.sh" "screenpad" "off"
        "#;
        let audit = audit_niri_config(ok, LINK);
        assert_eq!(audit.sudo_calls, 2);
        assert!(audit.ok(), "{:?}", audit.problems);

        let bad = r#"
            Mod+8 { spawn "bash" "-c" "sudo /usr/local/sbin/power.sh a; sudo /bin/sh"; }
            spawn-at-startup "sudo" "-n" "/usr/local/sbin/power.sh"
            Mod+9 { spawn "bash" "-c" "pseudo-sudo launcher"; }
        "#;
        let audit = audit_niri_config(bad, LINK);
        assert_eq!(audit.sudo_calls, 3);
        let joined = audit.problems.join("\n");
        assert!(joined.contains("passes an option"), "{joined}");
        assert!(joined.contains("not /usr/local/sbin/power.sh"), "{joined}");
    }

    #[test]
    fn inspect_link_refuses_a_link_under_home() {
        let home = std::env::var("HOME").unwrap();
        let link = format!("{home}/power.sh");
        let state = inspect_link(&link);
        assert!(!state.ok());
        assert!(
            state.problems.iter().any(|p| p.contains("under $HOME")),
            "{:?}",
            state.problems
        );
    }

    #[test]
    fn inspect_link_refuses_a_writable_parent_and_a_regular_file() {
        let dir = std::env::temp_dir().join(format!("dots-link-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();

        let regular = dir.join("not-a-link");
        std::fs::write(&regular, b"#!/bin/sh\n").unwrap();
        let state = inspect_link(regular.to_str().unwrap());
        assert!(!state.ok());
        assert!(
            state
                .problems
                .iter()
                .any(|p| p.contains("is not a symlink") || p.contains("not root")),
            "{:?}",
            state.problems
        );

        let link = dir.join("power.sh");
        std::os::unix::fs::symlink(dir.join("target"), &link).unwrap();
        let state = inspect_link(link.to_str().unwrap());
        assert!(!state.ok());
        assert!(
            state
                .problems
                .iter()
                .any(|p| p.contains("parent of") && p.contains("not root")),
            "{:?}",
            state.problems
        );

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn runtime_input_matching_uses_the_package_name() {
        let inputs = vec![
            "auto-cpufreq".to_string(),
            "coreutils".to_string(),
            "gnugrep".to_string(),
            "kmod".to_string(),
            "libnotify".to_string(),
            "sudo".to_string(),
        ];
        assert!(in_runtime_inputs(
            "/nix/store/kwc34h21my8mf7xbqm9gxs1xfx07xb4i-coreutils-9.11",
            &inputs
        ));
        assert!(in_runtime_inputs(
            "/nix/store/jll702873clqmdkrfvap4lc592mpi0r4-python3.13-auto-cpufreq-3.0.0",
            &inputs
        ));
        assert!(!in_runtime_inputs(
            "/nix/store/kp6p38x6zb21n7gdlnp9nsm2aagq7sg2-python3-3.13.17",
            &inputs
        ));
    }
}
