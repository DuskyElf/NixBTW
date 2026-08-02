import process from "node:process";

// Shared network helpers. Retry + timeout + a browser User-Agent, so callers
// don't repeat the failure handling. Two functions, nothing else.

const UA =
  "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36";

export async function fetchText(url, tries = 2) {
  for (let i = 0; i < tries; i++) {
    const ac = new AbortController();
    const t = setTimeout(() => ac.abort(), 45000);
    try {
      const r = await fetch(url, { headers: { "User-Agent": UA }, signal: ac.signal });
      if (!r.ok) throw new Error("HTTP " + r.status);
      return await r.text();
    } catch {
      if (i === tries - 1) return null;
      await new Promise((r) => setTimeout(r, 1000 * (i + 1)));
    } finally {
      clearTimeout(t);
    }
  }
  return null;
}

export async function fetchBuffer(url, tries = 3) {
  for (let i = 0; i < tries; i++) {
    const ac = new AbortController();
    const t = setTimeout(() => ac.abort(), 120000);
    try {
      const r = await fetch(url, { headers: { "User-Agent": UA }, signal: ac.signal });
      if (!r.ok) throw new Error("HTTP " + r.status);
      return Buffer.from(await r.arrayBuffer());
    } catch {
      if (i === tries - 1) return null;
      await new Promise((r) => setTimeout(r, 1500 * (i + 1)));
    } finally {
      clearTimeout(t);
    }
  }
  return null;
}

void process; // (kept for clarity if logging is later added here)
