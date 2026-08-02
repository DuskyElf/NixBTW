// Serialize fetch/next over the pool dir via proper-lockfile. Returns false
// (and logs) when another run holds the lock, true after fn runs and releases.

import lockfile from "proper-lockfile";

export async function withLock(dir, fn, { log = () => {} } = {}) {
  let release;
  try {
    release = await lockfile.lock(dir, { stale: 60000, update: 30000, realpath: false });
  } catch {
    log("another run is in progress, skipping");
    return false;
  }
  try {
    await fn();
  } finally {
    await release();
  }
  return true;
}
