//! Every nix/nix-store invocation.
//!
//! The wrapper flake is the installable and the live tree arrives as an
//! override: `builtins.getFlake` plus `--override-input` silently evaluates the
//! stale lock, so that combination is never used here. Anything that walks the
//! live tree goes through `path:<deploy>#...` with
//! `--override-input my-dotfiles path:<dotfiles>`.

use crate::cmd::{self, Out};
use crate::deploy::Ctx;
use anyhow::{anyhow, bail, Context, Result};
use serde::Deserialize;
use serde_json::Value;
use std::collections::BTreeMap;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Target {
    System,
    Home,
}

impl Target {
    pub fn label(self) -> &'static str {
        match self {
            Target::System => "system",
            Target::Home => "home",
        }
    }

    /// Whether this target's activation links `power.sh` (only the system
    /// activation does).
    pub fn touches_root(self) -> bool {
        matches!(self, Target::System)
    }
}

#[derive(Debug, Clone)]
pub struct DeclaredPkg {
    pub name: String,
    pub out: String,
    pub position: Option<String>,
}

#[derive(Debug, Clone, Deserialize, Default)]
pub struct PathInfo {
    #[serde(default, rename = "narSize")]
    pub nar_size: u64,
    #[serde(default)]
    pub signatures: Vec<String>,
}

#[derive(Debug, Clone)]
pub struct SystemCore {
    /// The activation snippet that declares the power.sh link.
    pub power_script: String,
    /// Every activation script merged, which is what the switch actually runs.
    pub activation_text: String,
    /// `config.security.sudo.configFile`: the composed sudoers file, which is
    /// the only authority on what sudo will accept. `extraRules` and a source
    /// grep can both miss rules that another module or `extraConfig` added.
    pub sudo_config: String,
    /// `config.system.build.toplevel.drvPath`, to bind the eval to the build.
    pub toplevel_drv: String,
}

fn override_args(ctx: &Ctx) -> Vec<String> {
    vec![
        "--override-input".to_string(),
        "my-dotfiles".to_string(),
        format!("path:{}", ctx.dotfiles.display()),
    ]
}

fn installable(ctx: &Ctx, suffix: &str) -> String {
    format!("path:{}{}", ctx.deploy.display(), suffix)
}

/// Run a nix command and remember its stderr warnings for the audit.
fn nix(ctx: &Ctx, args: &[String]) -> Result<Out> {
    let nix = cmd::nix()?;
    let out = cmd::run(&nix, args)?;
    ctx.collect_warnings(&out.stderr);
    Ok(out)
}

fn eval_out(ctx: &Ctx, suffix: &str, apply: Option<&str>) -> Result<Out> {
    let mut args = vec![
        "eval".to_string(),
        "--json".to_string(),
        installable(ctx, suffix),
    ];
    if let Some(expr) = apply {
        args.push("--apply".into());
        args.push(expr.to_string());
    }
    args.extend(override_args(ctx));
    // Every flake call carries this: a manual run must never rewrite the
    // private wrapper's lock (the daily timer owns it).
    args.push("--no-write-lock-file".to_string());
    let out = nix(ctx, &args)?;
    if !out.ok() {
        bail!(
            "nix eval {} failed ({}):\n{}",
            suffix,
            out.status,
            cmd::tail(&out.stderr, 40)
        );
    }
    Ok(out)
}

pub fn eval_json(ctx: &Ctx, suffix: &str, apply: Option<&str>) -> Result<Value> {
    let out = eval_out(ctx, suffix, apply)?;
    serde_json::from_str(out.stdout.trim())
        .with_context(|| format!("parsing nix eval output for {suffix}"))
}

/// Names of the flake outputs, discovered once at runtime so no host or user
/// name is baked into the crate.
#[derive(Debug, Clone)]
pub struct Names {
    pub host: String,
    pub home: String,
    pub user: String,
}

pub fn discover_names(ctx: &Ctx) -> Result<Names> {
    let hosts = eval_json(ctx, "#nixosConfigurations", Some("builtins.attrNames"))?;
    let homes = eval_json(ctx, "#homeConfigurations", Some("builtins.attrNames"))?;
    let to_vec = |value: &Value| -> Vec<String> {
        value
            .as_array()
            .map(|a| {
                a.iter()
                    .filter_map(|v| v.as_str().map(str::to_string))
                    .collect()
            })
            .unwrap_or_default()
    };
    let hosts = to_vec(&hosts);
    let homes = to_vec(&homes);

    let host = match hosts.as_slice() {
        [one] => one.clone(),
        [] => bail!("the wrapper flake declares no nixosConfigurations"),
        many => bail!(
            "the wrapper flake declares several hosts ({}); dots deploys one machine at a time",
            many.join(", ")
        ),
    };
    let home = homes
        .iter()
        .find(|h| h.ends_with(&format!("@{host}")))
        .or_else(|| (homes.len() == 1).then(|| &homes[0]))
        .cloned()
        .ok_or_else(|| anyhow!("no homeConfiguration matches host {host}"))?;
    let user = home
        .split('@')
        .next()
        .filter(|u| !u.is_empty())
        .ok_or_else(|| anyhow!("cannot derive the login user from homeConfiguration {home}"))?
        .to_string();

    Ok(Names { host, home, user })
}

fn system_apply(ctx: &Ctx, body: &str) -> String {
    format!(
        "n: let c = builtins.getAttr \"{}\" n; in {body}",
        ctx.names.host
    )
}

pub fn eval_system_core(ctx: &Ctx) -> Result<SystemCore> {
    let apply = system_apply(
        ctx,
        "{ powerScript = \
             let p = c.config.system.activationScripts.powerScript; \
             in if builtins.isString p then p else p.text; \
           activationText = \
             let scripts = c.config.system.activationScripts; \
                 flatten = v: if builtins.isString v then v else v.text; \
                 composed = scripts.script or null; \
             in if composed != null then flatten composed \
                else builtins.concatStringsSep \"\\n\" \
                       (map flatten (builtins.attrValues scripts)); \
           sudoers = c.config.security.sudo.configFile; \
           toplevelDrv = c.config.system.build.toplevel.drvPath; }",
    );
    let value = eval_json(ctx, "#nixosConfigurations", Some(&apply))?;
    Ok(SystemCore {
        power_script: value
            .get("powerScript")
            .and_then(Value::as_str)
            .context("activation script for power.sh is missing")?
            .to_string(),
        activation_text: value
            .get("activationText")
            .and_then(Value::as_str)
            .context("the merged activation text did not evaluate")?
            .to_string(),
        sudo_config: value
            .get("sudoers")
            .and_then(Value::as_str)
            .context("config.security.sudo.configFile did not evaluate to text")?
            .to_string(),
        toplevel_drv: value
            .get("toplevelDrv")
            .and_then(Value::as_str)
            .context("config.system.build.toplevel.drvPath is missing")?
            .to_string(),
    })
}

/// The drv path of whatever a target builds, so `nix build` can be bound to
/// the evaluation that was audited.
pub fn eval_drv(ctx: &Ctx, target: Target) -> Result<String> {
    let apply = match target {
        Target::System => system_apply(ctx, "c.config.system.build.toplevel.drvPath"),
        Target::Home => format!(
            "n: let c = builtins.getAttr \"{}\" n; in c.config.home.activationPackage.drvPath",
            ctx.names.home
        ),
    };
    let suffix = match target {
        Target::System => "#nixosConfigurations",
        Target::Home => "#homeConfigurations",
    };
    let value = eval_json(ctx, suffix, Some(&apply))?;
    value
        .as_str()
        .map(str::to_string)
        .context("build drv path did not evaluate to a string")
}

/// Every string, array and nested value the compositor configuration ships.
/// Keybinds live in `binds`, startup commands in `spawn-at-startup`, and both
/// can carry a sudo invocation, so the walk covers the whole settings tree.
pub fn eval_niri_config(ctx: &Ctx) -> Result<String> {
    // `programs.niri.config` completely overrides `programs.niri.settings`, and
    // `finalConfig` is the rendered KDL niri actually reads. Auditing settings
    // alone would miss a config-string override entirely.
    let apply = format!(
        "n: let c = builtins.getAttr \"{}\" n; in c.config.programs.niri.finalConfig",
        ctx.names.home
    );
    let value = eval_json(ctx, "#homeConfigurations", Some(&apply))?;
    value
        .as_str()
        .map(str::to_string)
        .context("programs.niri.finalConfig is not a string")
}

/// The deriver recorded for a store path, if the store knows one.
pub fn deriver(path: &str) -> Result<String> {
    let nix_store = cmd::nix_store()?;
    let out = cmd::run(
        &nix_store,
        &["-q".to_string(), "--deriver".to_string(), path.to_string()],
    )
    .with_context(|| format!("nix-store -q --deriver {path}"))?;
    if !out.ok() {
        bail!(
            "nix-store -q --deriver {path} failed ({}):\n{}",
            out.status,
            cmd::tail(&out.stderr, 20)
        );
    }
    Ok(out.stdout.trim().to_string())
}

fn packages_from(value: &Value) -> Vec<DeclaredPkg> {
    value
        .as_array()
        .map(|items| {
            items
                .iter()
                .filter_map(|p| {
                    Some(DeclaredPkg {
                        name: p.get("name")?.as_str()?.to_string(),
                        out: p.get("out")?.as_str()?.to_string(),
                        position: p
                            .get("position")
                            .and_then(Value::as_str)
                            .map(str::to_string),
                    })
                })
                .collect()
        })
        .unwrap_or_default()
}

pub fn eval_system_packages(ctx: &Ctx) -> Result<Vec<DeclaredPkg>> {
    let apply = system_apply(
        ctx,
        "map (p: { name = p.name; out = p.outPath; position = p.meta.position or null; }) \
         c.config.environment.systemPackages",
    );
    let value = eval_json(ctx, "#nixosConfigurations", Some(&apply))?;
    Ok(packages_from(&value))
}

pub fn eval_home_packages(ctx: &Ctx) -> Result<Vec<DeclaredPkg>> {
    let apply = format!(
        "n: let c = builtins.getAttr \"{}\" n; in \
         map (p: {{ name = p.name; out = p.outPath; position = p.meta.position or null; }}) \
         c.config.home.packages",
        ctx.names.home
    );
    let value = eval_json(ctx, "#homeConfigurations", Some(&apply))?;
    Ok(packages_from(&value))
}

pub fn packages(ctx: &Ctx, target: Target) -> Result<Vec<DeclaredPkg>> {
    match target {
        Target::System => eval_system_packages(ctx),
        Target::Home => eval_home_packages(ctx),
    }
}

pub fn build_attr(ctx: &Ctx, target: Target) -> String {
    match target {
        Target::System => format!(
            "nixosConfigurations.{}.\
             config.system.build.toplevel",
            ctx.names.host
        ),
        Target::Home => format!(
            "homeConfigurations.\"{}\".activationPackage",
            ctx.names.home
        ),
    }
}

/// Build one target without creating a `result` link, returning the store path.
pub fn build(ctx: &Ctx, target: Target) -> Result<String> {
    let attr = build_attr(ctx, target);
    let mut args = vec![
        "build".to_string(),
        "--no-link".to_string(),
        "--print-out-paths".to_string(),
        format!("path:{}#{attr}", ctx.deploy.display()),
    ];
    args.extend(override_args(ctx));
    args.push("--no-write-lock-file".to_string());
    let out = nix(ctx, &args)?;
    if !out.ok() {
        bail!(
            "nix build of {} failed ({}):\n{}",
            target.label(),
            out.status,
            cmd::tail(&out.stderr, 40)
        );
    }
    let path = out
        .stdout
        .trim()
        .lines()
        .last()
        .unwrap_or("")
        .trim()
        .to_string();
    if !path.starts_with("/nix/store/") {
        bail!(
            "nix build for {} printed no store path: {:?}",
            target.label(),
            out.stdout
        );
    }
    Ok(path)
}

/// Flake inputs and where their sources landed, nested names included
/// (`my-dotfiles/nixpkgs-fast-release` and friends).
pub fn archive_inputs(ctx: &Ctx) -> Result<Vec<(String, String)>> {
    let mut args = vec![
        "flake".to_string(),
        "archive".to_string(),
        "--json".to_string(),
    ];
    args.extend(override_args(ctx));
    args.push(format!("path:{}", ctx.deploy.display()));
    args.push("--no-write-lock-file".to_string());
    let out = nix(ctx, &args)?;
    if !out.ok() {
        bail!(
            "nix flake archive failed ({}):\n{}",
            out.status,
            cmd::tail(&out.stderr, 30)
        );
    }
    let value: Value = serde_json::from_str(out.stdout.trim()).context("parsing flake archive")?;
    let mut flat = Vec::new();
    flatten_inputs(&value, "", &mut flat);
    Ok(flat)
}

fn flatten_inputs(node: &Value, prefix: &str, out: &mut Vec<(String, String)>) {
    if let Some(inputs) = node.get("inputs").and_then(Value::as_object) {
        for (name, input) in inputs {
            let full = if prefix.is_empty() {
                name.clone()
            } else {
                format!("{prefix}/{name}")
            };
            if let Some(path) = input.get("path").and_then(Value::as_str) {
                out.push((full.clone(), path.to_string()));
            }
            flatten_inputs(input, &full, out);
        }
    }
}

pub fn closure(path: &str) -> Result<Vec<String>> {
    let nix_store = cmd::nix_store()?;
    let out = cmd::run(&nix_store, &["-qR".to_string(), path.to_string()])
        .with_context(|| format!("nix-store -qR {path}"))?;
    if !out.ok() {
        bail!(
            "nix-store -qR {path} failed ({}):\n{}",
            out.status,
            cmd::tail(&out.stderr, 20)
        );
    }
    Ok(out
        .stdout
        .lines()
        .map(str::trim)
        .filter(|l| l.starts_with("/nix/store/"))
        .map(str::to_string)
        .collect())
}

pub fn path_info(paths: &[String]) -> Result<BTreeMap<String, PathInfo>> {
    let existing: Vec<String> = paths
        .iter()
        .filter(|p| std::path::Path::new(p).exists())
        .cloned()
        .collect();
    if existing.is_empty() {
        return Ok(BTreeMap::new());
    }
    let mut args = vec![
        "path-info".to_string(),
        "--json".to_string(),
        "--sigs".to_string(),
        "--json-format".to_string(),
        "1".to_string(),
    ];
    args.extend(existing);
    let out = cmd::run(&cmd::nix()?, &args)?;
    if !out.ok() {
        bail!(
            "nix path-info failed ({}):\n{}",
            out.status,
            cmd::tail(&out.stderr, 20)
        );
    }
    let value: Value = serde_json::from_str(out.stdout.trim()).context("parsing nix path-info")?;
    let mut map = BTreeMap::new();
    if let Some(obj) = value.as_object() {
        for (path, info) in obj {
            let parsed: PathInfo = serde_json::from_value(info.clone()).unwrap_or_default();
            map.insert(path.clone(), parsed);
        }
    }
    Ok(map)
}

pub fn diff_closures(old: &str, new: &str) -> Result<String> {
    let out = cmd::run(
        &cmd::nix()?,
        &[
            "store".to_string(),
            "diff-closures".to_string(),
            old.to_string(),
            new.to_string(),
        ],
    )?;
    if !out.ok() {
        bail!(
            "nix store diff-closures failed ({}):\n{}",
            out.status,
            cmd::tail(&out.stderr, 20)
        );
    }
    Ok(out.stdout)
}

pub fn store_verify(path: &str) -> Result<()> {
    let out = cmd::run(
        &cmd::nix()?,
        &["store".to_string(), "verify".to_string(), path.to_string()],
    )?;
    if !out.ok() {
        bail!(
            "nix store verify {path} failed ({}):\n{}",
            out.status,
            cmd::tail(&out.stderr, 20)
        );
    }
    Ok(())
}

/// Read `base/system.nix`'s `runtimeInputs = [ ... ]` attribute names. The
/// identifier also appears in prose comments, so the assignment is required.
pub fn read_runtime_inputs(module: &str) -> Vec<String> {
    let mut start = None;
    for (idx, _) in module.match_indices("runtimeInputs") {
        let after = &module[idx + "runtimeInputs".len()..];
        if after.trim_start().starts_with('=') {
            start = Some(idx);
            break;
        }
    }
    let Some(start) = start else {
        return Vec::new();
    };
    let rest = &module[start..];
    let Some(open) = rest.find('[') else {
        return Vec::new();
    };
    let Some(close) = rest[open..].find(']') else {
        return Vec::new();
    };
    rest[open + 1..open + close]
        .split_whitespace()
        .filter_map(|token| {
            let name = token.trim();
            let name = name.strip_prefix("pkgs.").unwrap_or(name);
            let name = name.trim_end_matches(';');
            if name.is_empty() || name.starts_with('#') {
                None
            } else {
                Some(name.to_string())
            }
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn flattens_nested_inputs() {
        let value = json!({
            "inputs": {
                "my-dotfiles": {
                    "path": "/nix/store/aaa-source",
                    "inputs": {
                        "nixpkgs-fast-release": { "path": "/nix/store/bbb-source" }
                    }
                },
                "nixpkgs": { "path": "/nix/store/ccc-source" }
            },
            "path": "/nix/store/ddd-source"
        });
        let mut flat = Vec::new();
        flatten_inputs(&value, "", &mut flat);
        flat.sort();
        assert_eq!(
            flat,
            vec![
                (
                    "my-dotfiles".to_string(),
                    "/nix/store/aaa-source".to_string()
                ),
                (
                    "my-dotfiles/nixpkgs-fast-release".to_string(),
                    "/nix/store/bbb-source".to_string()
                ),
                ("nixpkgs".to_string(), "/nix/store/ccc-source".to_string()),
            ]
        );
    }

    #[test]
    fn runtime_inputs_are_read_from_the_module() {
        let module = r#"
          powerScript = pkgs.writeShellApplication {
            runtimeInputs = [
              pkgs.auto-cpufreq
              pkgs.coreutils
              pkgs.kmod
            ];
          };
        "#;
        assert_eq!(
            read_runtime_inputs(module),
            vec!["auto-cpufreq", "coreutils", "kmod"]
        );
        assert!(read_runtime_inputs("nothing here").is_empty());
    }

    #[test]
    fn build_attrs_use_discovered_names() {
        assert_eq!(Target::System.label(), "system");
        assert!(Target::System.touches_root());
        assert!(!Target::Home.touches_root());
    }
}
