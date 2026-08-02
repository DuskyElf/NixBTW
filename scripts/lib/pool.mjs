// Photo store for the wallpaper pipeline. Hides the pool dir layout
// (<hash>.<ext> files, mtime pruning), the captions.tsv index, and the
// caption.txt overlay file behind a small object interface. Injectable
// `download` keeps it testable without a network.

import * as fs from "node:fs";
import path from "node:path";
import { fetchBuffer } from "./http.mjs";

const EXT_RE = /\/master\/\d+\.(jpg|png)/;

export function openPool(dir, { minWidth = 600, download = fetchBuffer, log = () => {} } = {}) {
  fs.mkdirSync(dir, { recursive: true });

  // Photos on disk: <hash>.<ext> files, plus current / caption.txt / captions.tsv.
  function list() {
    const out = [];
    for (const f of fs.readdirSync(dir))
      if (/\.(jpg|png)$/.test(f)) out.push(path.join(dir, f));
    return out;
  }

  function count() {
    return list().length;
  }

  // Download photos that aren't already on disk (or are empty/corrupt). Skips
  // anything narrower than minWidth. Returns the number actually downloaded.
  async function save(photos) {
    let n = 0;
    for (const p of photos) {
      if (p.width < minWidth) continue;
      const ext = (EXT_RE.exec(p.url) || [])[1] || "jpg";
      const f = path.join(dir, `${p.hash}.${ext}`);
      if (fs.existsSync(f) && fs.statSync(f).size > 0) continue;
      const buf = await download(p.url);
      if (buf) {
        fs.writeFileSync(f, buf);
        n++;
      }
    }
    return n;
  }

  // Remove photo files older than maxAgeMs (mtime-based). Returns count removed.
  function prune(maxAgeMs) {
    const cutoff = Date.now() - maxAgeMs;
    let removed = 0;
    for (const f of fs.readdirSync(dir)) {
      if (!/\.(jpg|png)$/.test(f)) continue;
      const fp = path.join(dir, f);
      try {
        if (fs.statSync(fp).mtimeMs < cutoff) {
          fs.rmSync(fp);
          removed++;
        }
      } catch {
        /* gone */
      }
    }
    return removed;
  }

  function current() {
    try {
      return fs.readFileSync(path.join(dir, "current"), "utf8").trim();
    } catch {
      return "";
    }
  }

  function setCurrent(f) {
    fs.writeFileSync(path.join(dir, "current"), f + "\n");
  }

  // Full paths of photos shown since the last cycle reset, one per line. Lets
  // `next` pick a fresh photo until every one has been shown (then resets).
  function used() {
    try {
      return fs
        .readFileSync(path.join(dir, "used"), "utf8")
        .split("\n")
        .filter(Boolean);
    } catch {
      return [];
    }
  }

  function markUsed(f) {
    fs.appendFileSync(path.join(dir, "used"), f + "\n");
  }

  function resetUsed() {
    fs.writeFileSync(path.join(dir, "used"), "");
  }

  // Write the captions.tsv index: one row per hash, first non-empty desc wins.
  // Rows: <hash>\t<loc>\t<desc>.
  function indexMeta(photos) {
    const seen = new Set();
    const lines = [];
    for (const p of photos) {
      if (seen.has(p.hash)) continue;
      if (!p.desc) continue; // skip empties so the first non-empty wins
      seen.add(p.hash);
      lines.push(`${p.hash}\t${p.loc || ""}\t${p.desc}`);
    }
    fs.writeFileSync(path.join(dir, "captions.tsv"), lines.length ? lines.join("\n") + "\n" : "");
  }

  function readIndex() {
    try {
      return fs
        .readFileSync(path.join(dir, "captions.tsv"), "utf8")
        .split("\n")
        .filter(Boolean)
        .map((l) => {
          const [hash, loc, ...rest] = l.split("\t");
          return { hash, loc: loc || "", desc: rest.join("\t") };
        });
    } catch {
      return [];
    }
  }

  function meta(hash) {
    return readIndex().find((c) => c.hash === hash);
  }

  // Refresh the caption.txt overlay (read by Quickshell): "LOC: desc" when the
  // photo has a location, bare desc otherwise, or remove the file if none.
  function writeCaptionFor(hash) {
    const c = meta(hash);
    const capFile = path.join(dir, "caption.txt");
    if (c && c.desc) {
      fs.writeFileSync(capFile, (c.loc ? `${c.loc}: ${c.desc}` : c.desc) + "\n");
    } else {
      try {
        fs.rmSync(capFile);
      } catch {
        /* none */
      }
    }
  }

  void log;
  return { save, list, count, prune, current, setCurrent, indexMeta, meta, writeCaptionFor, used, markUsed, resetUsed };
}
