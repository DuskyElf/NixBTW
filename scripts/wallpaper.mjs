#!/usr/bin/env node
// Guardian "photos of the day" wallpaper pool and slideshow. Thin composition
// root: wires the deep modules (source, pool, applier, lock) and dispatches the
// CLI. All parsing/download/locking complexity lives in lib/.
//
// Pool: ${XDG_CACHE_HOME:-$HOME/.cache}/wallpaper-guardian/
//   One file per photo, named by the i.guim.co.uk media hash. The pool rolls
//   over a 5-day window: the daily `fetch` adds new galleries and prunes files
//   older than 5 days.
//
// Commands:
//   fetch   pull galleries from the last 5 days, download new photos, prune old
//   next    pick a random photo other than the current one and apply it
//   apply F set the wallpaper to file F
//   status  pool stats

import * as fs from "node:fs";
import { realpathSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { execFileSync, spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import { fetchPhotos } from "./lib/source.mjs";
import { openPool } from "./lib/pool.mjs";
import { awwwApplier } from "./lib/applier.mjs";
import { withLock } from "./lib/lock.mjs";

const CACHE = `${process.env.XDG_CACHE_HOME || path.join(os.homedir(), ".cache")}/wallpaper-guardian`;
const DAYS = 5;
const MIN_WIDTH = 600; // related-list and og:image thumbs are <= 465px wide
const log = (m) => process.stderr.write("wallpaper: " + m + "\n");

fs.mkdirSync(path.join(CACHE, "tmp"), { recursive: true });

const pool = openPool(CACHE, { minWidth: MIN_WIDTH, log });
const applier = awwwApplier({
  exec: (bin, args, opts) => execFileSync(bin, args, opts),
  spawnFn: (bin, args, opts) => spawn(bin, args, opts),
  log,
});

// Shared fetch flow used by both `fetch` and `next` (empty pool). fetchPhotos
// throws on RSS failure so we keep the current pool and do NOT prune.
async function fetchFlow() {
  let photos;
  try {
    photos = await fetchPhotos({ days: DAYS, log });
  } catch (e) {
    log("RSS fetch failed, keeping current pool: " + e.message);
    return;
  }
  pool.indexMeta(photos);
  const n = await pool.save(photos);
  pool.prune(DAYS * 86400_000);
  log(`${n} new photos, pool is now ${pool.count()} files`);
}

async function apply(file) {
  if (!(await applier.ensure())) {
    log("no compositor session, awww query failed");
    return false;
  }
  try {
    applier.setWallpaper(file);
  } catch (e) {
    log("awww img failed: " + e.message);
    return false;
  }
  pool.setCurrent(file);
  const hash = path.basename(file).replace(/\.[^.]*$/, "");
  pool.writeCaptionFor(hash);
  return true;
}

function du(dir) {
  let total = 0;
  for (const f of fs.readdirSync(dir)) {
    const p = path.join(dir, f);
    const st = fs.statSync(p);
    total += st.isDirectory() ? du(p) : st.size;
  }
  return total;
}

function status() {
  log(`pool: ${pool.count()} photos in ${CACHE}`);
  log(`size: ${(du(CACHE) / 1024 / 1024).toFixed(1)}M`);
  log(`current: ${pool.current() || "none"}`);
}

async function main() {
  const cmd = process.argv[2] || "next";
  switch (cmd) {
    case "fetch":
      return withLock(CACHE, fetchFlow, { log });
    case "next":
      return withLock(CACHE, async () => {
        let files = pool.list();
        if (files.length === 0) {
          log("pool empty, fetching...");
          await fetchFlow();
          files = pool.list();
        }
        if (files.length === 0) {
          log("pool still empty after fetch");
          return;
        }
        const cur = pool.current();
        // Deck order: never pick a photo already shown this cycle. On
        // exhaustion, start a fresh cycle seeded with the current photo, so
        // the just-shown one can't repeat until the next full pass. That
        // makes every poolSize consecutive picks a distinct permutation.
        let used = pool.used();
        let candidates = files.filter((f) => !used.includes(f));
        if (candidates.length === 0) {
          pool.resetUsed();
          used = cur ? [cur] : [];
          if (cur) pool.markUsed(cur);
          candidates = files.filter((f) => !used.includes(f));
        }
        // Degenerate: pool holds only the current photo. Fall back to it.
        if (candidates.length === 0) candidates = files;
        const pick = candidates[Math.floor(Math.random() * candidates.length)];
        pool.markUsed(pick);
        await apply(pick);
      }, { log });
    case "apply":
      return apply(process.argv[3]);
    case "status":
      return status();
    default:
      log("usage: wallpaper.mjs <fetch|next|apply FILE|status>");
      process.exit(1);
  }
}

const isMain =
  process.argv[1] &&
  realpathSync(fileURLToPath(import.meta.url)) === realpathSync(process.argv[1]);
if (isMain) main();

export { CACHE, DAYS, fetchPhotos, fetchFlow, apply, status, pool };
