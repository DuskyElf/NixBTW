#!/usr/bin/env bash
set -euo pipefail

# Guardian "photos of the day" wallpaper pool and slideshow.
#
# Pool: ${XDG_CACHE_HOME:-$HOME/.cache}/wallpaper-guardian/
#   One file per photo, named by the i.guim.co.uk media hash. The pool rolls
#   over a 5-day window: the daily `fetch` adds new galleries and prunes files
#   older than 5 days.
#
# curl on this machine is the jailed wrapper (bwrap): network + cwd + the XDG
# dirs rw-bind. Every file this script touches lives under the pool dir, so
# the wrapper's mounts cover it. Never use /tmp here.
#
# Downloads use image URLs exactly as the Guardian page embeds them: the CDN
# signatures cannot be altered, so the largest embedded width per photo wins.
#
# Commands:
#   fetch   pull galleries from the last 5 days, download new photos, prune old
#   next    pick a random photo other than the current one and apply it
#   apply F set the wallpaper to file F
#   status  pool stats

CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/wallpaper-guardian"
SERIES="https://www.theguardian.com/news/series/ten-best-photographs-of-the-day"
DAYS=5
MIN_WIDTH=600   # related-list and og:image thumbs are <= 465px wide

mkdir -p "$CACHE/tmp"

# --- helpers ----------------------------------------------------------------

lock() {
  exec 9>"$CACHE/lock"
  if ! flock -n 9; then
    echo "wallpaper: another run is in progress, skipping" >&2
    exit 0
  fi
}

ensure_daemon() {
  if ! awww query > /dev/null 2>&1; then
    echo "wallpaper: starting awww-daemon" >&2
    # 9>&- keeps the daemon from inheriting the flock fd (exec 9> in lock());
    # otherwise the long-lived daemon holds the lock forever and every
    # subsequent run reports "another run is in progress".
    awww-daemon > /dev/null 2>&1 9>&- &
    sleep 1
  fi
  awww query > /dev/null 2>&1
}

parse_html() {
  # stdin: page HTML. stdout: hash<TAB>width<TAB>url per embedded image.
  sed 's/&amp;/\&/g' |
    grep -oE 'https://i\.guim\.co\.uk/img/media/[a-f0-9]+/[0-9_]+/master/[0-9]+\.(jpg|png)[^"<> ]*' |
    while IFS= read -r url; do
      # og:image promo cards carry overlay-base64 (Guardian logo) + precrop;
      # the same photo always has clean full-aspect variants, drop these.
      case "$url" in *overlay*|*precrop*) continue ;; esac
      hash=$(printf '%s' "$url" | sed -n 's:.*/media/\([a-f0-9]*\)/.*:\1:p')
      width=$(printf '%s' "$url" | sed -n 's:.*[?&]width=\([0-9]*\).*:\1:p')
      [ -n "$hash" ] || continue
      [ -n "$width" ] || width=0
      printf '%s\t%s\t%s\n' "$hash" "$width" "$url"
    done || true
}

scrape_page() {
  # $1 = gallery URL. Print hash<TAB>width<TAB>url for every embedded image.
  local html
  html=$(curl -sf --max-time 30 "$1" 2>/dev/null || true)
  if [ -z "$html" ]; then
    html=$(curl -sf --max-time 30 "$1.json" 2>/dev/null || true)
  fi
  [ -n "$html" ] || return 0
  printf '%s\n' "$html" | parse_html
}

# --- RSS --------------------------------------------------------------------

select_galleries() {
  # $1 = rss file, $2 = output file of gallery URLs within the $DAYS window.
  local cutoff
  cutoff=$(date -d "$DAYS days ago" +%s)

  # Items as dc:date<TAB>title<TAB>link; keep "photos of the day|weekend"
  # galleries published within the last $DAYS days.
  awk '
    /<item>/ { blk = ""; on = 1 }
    on       { blk = blk $0 "\n" }
    /<\/item>/ {
      on = 0
      link  = blk; sub(/^.*<link>/,  "", link);  sub(/<\/link>.*$/, "", link)
      title = blk; sub(/^.*<title>/, "", title); sub(/<\/title>.*$/, "", title)
      d     = blk; sub(/^.*<dc:date>/, "", d);   sub(/<\/dc:date>.*$/, "", d)
      if (link ~ /\/gallery\//) print d "\t" title "\t" link
    }' "$1" > "$1.items"

  : > "$2"
  while IFS=$'\t' read -r d title link; do
    [ -n "$link" ] || continue
    local lc
    lc=$(printf '%s' "$title" | tr 'A-Z' 'a-z')
    case "$lc" in
      *"photos of the day"*|*"photos of the weekend"*) ;;
      *) continue ;;
    esac
    ts=$(date -d "$d" +%s 2>/dev/null || echo 0)
    [ "$ts" -ge "$cutoff" ] || continue
    echo "$link"
  done < "$1.items" | sort -u > "$2"
  rm -f "$1.items"
}

# --- fetch ------------------------------------------------------------------

fetch_unlocked() {
  local rss="$CACHE/tmp/rss.xml"
  if ! curl -sf --max-time 30 "$SERIES/rss" > "$rss"; then
    echo "wallpaper: RSS fetch failed, keeping current pool" >&2
    return 1
  fi

  select_galleries "$rss" "$CACHE/tmp/galleries.txt"

  local ng
  ng=$(wc -l < "$CACHE/tmp/galleries.txt" | tr -d ' ')
  echo "wallpaper: $ng galleries in the $DAYS-day window" >&2

  # Scrape every gallery, keep the widest variant per photo hash.
  while IFS= read -r gal; do
    scrape_page "$gal"
  done < "$CACHE/tmp/galleries.txt" > "$CACHE/tmp/scraped.tsv"

  # Widest per hash; on a width tie prefer no explicit height (full aspect).
  awk -F'\t' '
    {
      key = $1; w = $2 + 0
      nh = ($3 ~ /[?&]height=/) ? 0 : 1
      if (!(key in line) || w > best[key] || (w == best[key] && nh > nhbest[key]))
        { line[key] = $0; best[key] = w; nhbest[key] = nh }
    }
    END { for (k in line) print line[k] }
  ' "$CACHE/tmp/scraped.tsv" > "$CACHE/tmp/wanted.tsv"

  local nw
  nw=$(wc -l < "$CACHE/tmp/wanted.tsv" | tr -d ' ')
  echo "wallpaper: $nw unique photos scraped" >&2

  # Download new photos; skip existing, junk under MIN_WIDTH, bad extensions.
  local found=0
  while IFS=$'\t' read -r hash width url; do
    [ "$width" -ge "$MIN_WIDTH" ] || continue
    local ext
    ext=$(printf '%s' "$url" | sed -n 's:.*/master/[0-9]*\.\(jpg\|png\).*:\1:p')
    [ -n "$ext" ] || continue
    local f="$CACHE/$hash.$ext"
    if [ ! -s "$f" ]; then
      if curl -sfL --retry 3 --max-time 90 > "$f" "$url"; then
        found=$((found + 1))
      else
        rm -f "$f"
      fi
    fi
  done < "$CACHE/tmp/wanted.tsv"

  # Prune photos older than the window, never the state files (current, lock).
  # Failure-safe: a missed day lingers until it ages out instead of being
  # wiped by a transient fetch failure.
  find "$CACHE" -maxdepth 1 -type f \
    \( -name '*.jpg' -o -name '*.png' \) -mtime +"$DAYS" -delete

  echo "wallpaper: $found new photos, pool is now $(pool_count) files"
}

fetch() {
  lock
  fetch_unlocked
}

# --- apply ------------------------------------------------------------------

pool_count() {
  find "$CACHE" -maxdepth 1 -type f \( -name '*.jpg' -o -name '*.png' \) | wc -l
}

next() {
  lock
  ensure_daemon || { echo "wallpaper: no compositor session, awww query failed" >&2; exit 0; }
  local pool cur pick
  pool=$(find "$CACHE" -maxdepth 1 -type f \( -name '*.jpg' -o -name '*.png' \) | shuf)
  if [ -z "$pool" ]; then
    echo "wallpaper: pool empty, fetching..." >&2
    fetch_unlocked || exit 1
    pool=$(find "$CACHE" -maxdepth 1 -type f \( -name '*.jpg' -o -name '*.png' \) | shuf)
  fi
  [ -n "$pool" ] || { echo "wallpaper: pool still empty after fetch" >&2; exit 1; }
  cur=$(cat "$CACHE/current" 2>/dev/null || true)
  pick=$(printf '%s\n' "$pool" | grep -vxF "$cur" | head -1)
  [ -n "$pick" ] || pick=$(printf '%s\n' "$pool" | head -1)
  apply "$pick"
}

apply() {
  ensure_daemon || exit 0
  awww img --transition-type fade --transition-duration 2 "$1"
  printf '%s\n' "$1" > "$CACHE/current"
}

status() {
  echo "pool: $(pool_count) photos in $CACHE"
  echo "size: $(du -sh "$CACHE" 2>/dev/null | cut -f1)"
  echo "current: $(cat "$CACHE/current" 2>/dev/null || echo none)"
}

case "${1:-next}" in
  fetch) fetch ;;
  next) next ;;
  apply) shift; apply "$1" ;;
  status) status ;;
  *) echo "usage: wallpaper.sh <fetch|next|apply FILE|status>"; exit 1 ;;
esac
