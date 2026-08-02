#!/usr/bin/env node
// Wallpaper-overlay timers block. Quickshell runs this every 60s and renders
// stdout as Text.RichText. Two groups (USER, SYSTEM); each timer is a table row
// with the name, next-trigger and last-trigger in aligned columns. Relative
// times parsed straight from systemctl's LEFT/PASSED columns (no date math or
// timezone work). Color roles: name warm-white bold, next-trigger light,
// last-trigger dim grey, group header orange.
import { execFileSync } from "node:child_process";

// Compact systemctl's unit words ("1day 3h", "2 weeks") to 1d 3h / 2w.
// mark is "left" (future => "in X") or "ago".
function rel(s, mark) {
  const out = s
    .replace(/years?/g, "y")
    .replace(/months?/g, "mo")
    .replace(/weeks?/g, "w")
    .replace(/days?/g, "d")
    .replace(/hours?/g, "h")
    .replace(/minutes?/g, "min")
    .replace(/seconds?/g, "s")
    .replace(/\s+/g, " ")
    // drop the space between value and unit ("2 d" -> "2d")
    .replace(/(\d) ([a-zA-Z])/g, "$1$2")
    .trim();
  return mark === "left" ? `in ${out}` : `${out} ago`;
}

// One timer line from `systemctl [--user] list-timers --all --no-pager`.
// LAST/PASSED may be `-` for a timer that has not fired yet, so LAST accepts
// either a datetime or a dash, and LEFT is matched explicitly (not `.*`) so it
// cannot swallow the trailing dashes.
const dt = "[A-Z][a-z]{2} [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} [A-Z]{2,4}";
const leftRe = "(?:\\d+[a-z]+(?: \\d+[a-z]+)*|now|n/a|-)";
const lineRe = new RegExp(
  "^(" + dt + ") +(" + leftRe + ") +(" + dt + "|-) +(.*) +([^ ]+)\\.timer +([^ ]+)\\.service$"
);

function parseTimers(body) {
  const rows = [];
  for (const line of body.split("\n")) {
    const m = line.match(lineRe);
    if (!m) continue;
    const name = m[5];
    const leftRaw = m[2].trim();
    const left = / ago$/.test(leftRaw)
      ? rel(leftRaw.replace(/ ago$/, ""), "ago")
      : rel(leftRaw.replace(/ *left$/, ""), "left");
    const passedRaw = m[4].trim();
    const passed = / ago$/.test(passedRaw)
      ? rel(passedRaw.replace(/ ago$/, ""), "ago")
      : "";
    rows.push(
      `<tr>` +
        `<td width="170"><font color="#ebdbb2"><b>${name}</b></font></td>` +
        `<td width="150" align="right"><font color="#d4be98">${left}</font></td>` +
        `<td width="130" align="right"><font color="#928374">${passed}</font></td>` +
      `</tr>`
    );
  }
  return rows.join("");
}

function emitGroup(header, ...args) {
  let body;
  try {
    body = execFileSync("systemctl", [...args, "--all", "--no-pager"], {
      encoding: "utf8",
    });
  } catch {
    return "";
  }
  const timers = parseTimers(String(body));
  if (!timers) return "";
  return (
    `<tr><td colspan="3"><font color="#e78a4e"><b>${header}</b></font></td></tr>` +
    timers
  );
}

const showSystem = process.argv[2] === "all";
const spacer = `<tr><td colspan="3" height="6"></td></tr>`;
const out =
  `<table cellspacing="0" cellpadding="0">` +
  emitGroup("USER", "--user", "list-timers") +
  (showSystem ? spacer + emitGroup("SYSTEM", "list-timers") : "") +
  `</table>`;
process.stdout.write(out);
