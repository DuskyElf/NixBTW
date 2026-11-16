//! Terminal output: colour, headings, human sizes. Colours are used only when
//! stdout is a tty and `NO_COLOR` is not set, and can always be turned off with
//! `--no-color`.

use std::cell::Cell;
use std::io::IsTerminal;

const BOLD: &str = "\x1b[1m";
const DIM: &str = "\x1b[2m";
const RED: &str = "\x1b[31m";
const GREEN: &str = "\x1b[32m";
const YELLOW: &str = "\x1b[33m";
const CYAN: &str = "\x1b[36m";
const RESET: &str = "\x1b[0m";

pub struct Ui {
    color: bool,
    verbose: bool,
    ok_count: Cell<usize>,
    warn_count: Cell<usize>,
    bad_count: Cell<usize>,
}

impl Ui {
    pub fn new(no_color: bool, verbose: bool) -> Self {
        let color = !no_color
            && std::env::var_os("NO_COLOR").map_or(true, |v| v.is_empty())
            && std::io::stdout().is_terminal();
        Ui {
            color,
            verbose,
            ok_count: Cell::new(0),
            warn_count: Cell::new(0),
            bad_count: Cell::new(0),
        }
    }

    pub fn verbose(&self) -> bool {
        self.verbose
    }

    pub fn counts(&self) -> (usize, usize, usize) {
        (
            self.ok_count.get(),
            self.warn_count.get(),
            self.bad_count.get(),
        )
    }

    fn paint(&self, code: &str, s: &str) -> String {
        if self.color {
            format!("{code}{s}{RESET}")
        } else {
            s.to_string()
        }
    }

    pub fn bold(&self, s: &str) -> String {
        self.paint(BOLD, s)
    }
    pub fn dim(&self, s: &str) -> String {
        self.paint(DIM, s)
    }
    pub fn red(&self, s: &str) -> String {
        self.paint(RED, s)
    }
    pub fn green(&self, s: &str) -> String {
        self.paint(GREEN, s)
    }
    pub fn yellow(&self, s: &str) -> String {
        self.paint(YELLOW, s)
    }
    pub fn cyan(&self, s: &str) -> String {
        self.paint(CYAN, s)
    }

    pub fn heading(&self, s: &str) {
        println!("\n{}", self.bold(&format!("▸ {s}")));
    }

    pub fn sub(&self, s: &str) {
        println!("{}", self.dim(&format!("  {s}")));
    }

    /// A key/value line. Keys are padded so a block reads as a table.
    pub fn kv(&self, key: &str, value: &str) {
        println!("{:<18} {}", format!("{key}:"), value);
    }

    pub fn ok(&self, label: &str, value: &str) {
        self.ok_count.set(self.ok_count.get() + 1);
        println!("{:<18} {} {}", format!("{label}:"), self.green("✓"), value);
    }

    pub fn warn(&self, label: &str, value: &str) {
        self.warn_count.set(self.warn_count.get() + 1);
        println!("{:<18} {} {}", format!("{label}:"), self.yellow("!"), value);
    }

    pub fn bad(&self, label: &str, value: &str) {
        self.bad_count.set(self.bad_count.get() + 1);
        println!("{:<18} {} {}", format!("{label}:"), self.red("✗"), value);
    }

    pub fn note(&self, s: &str) {
        println!("{}", self.dim(s));
    }

    pub fn alert(&self, s: &str) {
        self.warn_count.set(self.warn_count.get() + 1);
        println!("{}", self.red(&self.bold(s)));
    }

    /// The closing verdict: counts, then one free-form line of consequences.
    pub fn summary(&self, consequence: &str) {
        let (ok, warn, bad) = self.counts();
        let mut parts = vec![self.green(&format!("✓ {ok} passed"))];
        if warn > 0 {
            parts.push(self.yellow(&format!("! {warn} warning(s)")));
        }
        if bad > 0 {
            parts.push(self.red(&format!("✗ {bad} failed")));
        }
        println!();
        println!("{}", self.dim(&"─".repeat(72)));
        println!("{}", parts.join("   "));
        if !consequence.is_empty() {
            println!("{consequence}");
        }
    }
}

/// Human readable byte count, matching the shape nix prints in closure diffs.
pub fn human_size(bytes: u64) -> String {
    const UNITS: [&str; 6] = ["B", "KiB", "MiB", "GiB", "TiB", "PiB"];
    if bytes < 1024 {
        return format!("{bytes} B");
    }
    let mut value = bytes as f64;
    let mut unit = 0;
    while value >= 1024.0 && unit + 1 < UNITS.len() {
        value /= 1024.0;
        unit += 1;
    }
    format!("{value:.1} {}", UNITS[unit])
}

/// Signed byte delta for closure diffs, e.g. `+1.2 MiB` / `-4.0 KiB`.
pub fn human_delta(delta: i64) -> String {
    if delta == 0 {
        return "0 B".to_string();
    }
    let magnitude = human_size(delta.unsigned_abs());
    if delta > 0 {
        format!("+{magnitude}")
    } else {
        format!("-{magnitude}")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn human_sizes() {
        assert_eq!(human_size(0), "0 B");
        assert_eq!(human_size(1023), "1023 B");
        assert_eq!(human_size(1024), "1.0 KiB");
        assert_eq!(human_size(1536), "1.5 KiB");
        assert_eq!(human_size(125_829), "122.9 KiB");
        assert_eq!(human_size(1024 * 1024), "1.0 MiB");
        assert_eq!(human_size(10_380_902), "9.9 MiB");
        assert_eq!(human_size(1024 * 1024 * 1024), "1.0 GiB");
    }

    #[test]
    fn deltas() {
        assert_eq!(human_delta(0), "0 B");
        assert_eq!(human_delta(4096), "+4.0 KiB");
        assert_eq!(human_delta(-4096), "-4.0 KiB");
    }

    #[test]
    fn ui_never_paints_when_disabled() {
        let ui = Ui::new(true, false);
        assert_eq!(ui.red("x"), "x");
        assert_eq!(ui.bold("x"), "x");
    }
}
