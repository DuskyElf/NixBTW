// Guardian "photos of the day" source: RSS feed discovery + gallery HTML
// parsing. This is the deep module of the wallpaper pipeline: all cheerio and
// rss-parser complexity hides behind parseGalleryPage (pure, feed it HTML) and
// fetchPhotos (orchestrates RSS -> gallery pages -> dedup).
//
// Photo = { hash, url, width, loc, desc }
//   hash  i.guim.co.uk media hash (40 hex chars), the pool file name
//   url   the srcSet variant to download (largest ?width=)
//   width the CDN query width, which controls the actual downloaded resolution
//   loc   photo location, from the figure's <h2>
//   desc  photo description, the figcaption's bare text minus location/credit
//
// A gallery figure is <figure> with a <figcaption>: location in its <h2>,
// description as the caption text, credit in <small>, share button in a
// <gu-island>. The hero/lead figure has an empty figcaption and is skipped.
// Images live in <picture> <source srcSet>/<img src>.

import { load } from "cheerio";
import Parser from "rss-parser";
import { fetchText } from "./http.mjs";

const SERIES_DEFAULT =
  "https://www.theguardian.com/news/series/ten-best-photographs-of-the-day";
const GUIM = /i\.guim\.co\.uk/;
const DROP_VARIANT = /overlay|precrop/;
const HASH_RE = /\/media\/([a-f0-9]{40})\//;
const QUERY_W_RE = /[?&]width=(\d+)/;

// Pick the widest srcSet variant for a figure. The CDN's ?width= query sets the
// actual downloaded resolution; master/<W> is only the source's native size, so
// it is ignored. Among equal-width variants prefer one without an explicit
// height (odd crops). Returns { hash, url, width } or null.
function pickVariant($, $f) {
  let best = null;
  $f.find("img, source").each((_, im) => {
    const $im = $(im);
    const urls = [];
    const src = $im.attr("src");
    if (src) urls.push(src);
    const ss = $im.attr("srcset");
    if (ss) for (const part of ss.split(",")) urls.push(part.trim().split(/\s+/)[0]);
    for (const u of urls) {
      if (!GUIM.test(u)) continue;
      if (DROP_VARIANT.test(u)) continue;
      const hash = HASH_RE.exec(u);
      if (!hash) continue;
      const qw = QUERY_W_RE.exec(u);
      const width = qw ? +qw[1] : 0;
      const noHeight = /[?&]height=/.test(u) ? 0 : 1;
      if (!best || width > best.width || (width === best.width && noHeight > best.noHeight))
        best = { hash: hash[1], url: u, width };
    }
  });
  return best;
}

// Extract the location (first h1/h2/h3 in the figcaption) and the bare
// description (caption text with chrome stripped: headings, credit, share
// button, images).
function captionFields($, $cap) {
  const loc = $cap.find("h1, h2, h3").first().text().replace(/\s+/g, " ").trim();
  const $c = $cap.clone();
  $c.find("h1, h2, h3, small, gu-island, button, svg, picture").remove();
  $c.find("[class]")
    .filter((_, d) => /share/i.test($(d).attr("class") || ""))
    .remove();
  let desc = $c.text().replace(/\s+/g, " ").trim();
  desc = desc.replace(/View image in fullscreen/gi, "").replace(/Share\s*$/i, "").trim();
  return { loc, desc };
}

// Pure: parse one gallery page into its Photo list. No network, feed it HTML.
export function parseGalleryPage(html) {
  const $ = load(html);
  const photos = [];
  $("figure").each((_, el) => {
    const $f = $(el);
    const $cap = $f.find("figcaption");
    if (!$cap.length) return; // hero/lead figure has none
    const best = pickVariant($, $f);
    if (!best) return;
    const { loc, desc } = captionFields($, $cap);
    photos.push({ hash: best.hash, url: best.url, width: best.width, loc, desc });
  });
  return photos;
}

// Orchestrator: read the RSS feed, pick galleries in the window, fetch each
// page, dedup across galleries (widest url per hash, first non-empty caption
// per hash). Throws on RSS failure so the caller can abort without wiping the
// pool; a single gallery page whose fetch fails is skipped.
export async function fetchPhotos({ days, seriesUrl = SERIES_DEFAULT, log = () => {} }) {
  const parser = new Parser();
  let feed;
  try {
    feed = await parser.parseURL(`${seriesUrl}/rss`);
  } catch (e) {
    throw new Error(`RSS fetch failed: ${e && e.message ? e.message : e}`);
  }

  const cutoff = Date.now() - days * 86400_000;
  const links = [];
  for (const item of feed.items) {
    if (!/photos? of the day|photos? of the weekend/i.test(item.title || "")) continue;
    if (!/\/gallery\//.test(item.link || "")) continue;
    const ts = new Date(item.isoDate || item.pubDate || item.date || 0).getTime();
    if (Number.isFinite(ts) && ts >= cutoff) links.push(item.link);
  }
  const galleries = [...new Set(links)];
  log(`${galleries.length} galleries in the ${days}-day window`);

  const byHash = new Map(); // hash -> widest {hash,url,width}
  const caps = new Map(); // hash -> first non-empty {loc,desc}
  for (const g of galleries) {
    let html = await fetchText(g);
    if (html == null) html = await fetchText(g + ".json"); // some pages serve via .json
    if (html == null) continue;
    for (const p of parseGalleryPage(html)) {
      const cur = byHash.get(p.hash);
      if (!cur || p.width > cur.width) byHash.set(p.hash, p);
      if (!caps.has(p.hash) && (p.loc || p.desc)) caps.set(p.hash, { loc: p.loc, desc: p.desc });
    }
  }

  const photos = [];
  for (const p of byHash.values()) {
    const c = caps.get(p.hash) || { loc: p.loc, desc: p.desc };
    photos.push({ hash: p.hash, url: p.url, width: p.width, loc: c.loc, desc: c.desc });
  }
  return photos;
}
