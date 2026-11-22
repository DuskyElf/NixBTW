#!/usr/bin/env python3
"""The caller-facing half of Crawl4AI.

The container behind this (apps/crawl4ai/system.nix) returns one JSON document
per crawl with the page text, the images it found and a base64 screenshot. A
caller wants none of that shape: it wants the text, and it wants pictures it can
open by path. This server is that translation, and it is the only part of the
service the tailnet reaches.

    POST /fetch   {"url": ..., "want": ["text"|"image", ...],
                   "query": ..., "fresh": bool}
      -> {"url", "status", "text", "text_file", "images": [path, ...],
          "screenshot": path|null, "fetched_at", "filter", "llm", "llm_error"}

    GET  /health                 liveness of this process and the container
    GET  /artifacts/<run>/<file> the bytes of a path this server returned, for a
                                 caller on another machine

`fresh` is accepted and does nothing: every fetch already bypasses the
container's cache, so a second call re-reads the page. `want: ["image"]` still
answers with the text; the list only adds the screenshot and the page's images.

Everything is written under the workspace and returned as an absolute path,
because T3 Code's viewer opens images by path and a URL that has already
expired is worse than no answer. A caller on another machine cannot open such a
path, so it pulls the bytes from `/artifacts/<run>/<file>`, where `<run>` is the
last path component of the file's directory. Runs are deleted after a day, and
the workspace as a whole is kept under its size cap by dropping the oldest.

The tailnet is the only authentication either route has. A `query` with a
configured model spends the OpenCode Go key, so any tailnet peer can spend it.

The LLM is optional and lives in Crawl4AI, not here: a `query` is passed to the
container's own LLM content filter when `models` names one and `llm.env` holds a
key. Otherwise the query falls back to a keyword filter over the markdown, which
needs no credential and no model. The container reads the key once at start, so
`/health` reporting `llm: "on"` means configured, not that the container
accepted it; after a key change restart podman-crawl4ai.

`status` is the page's HTTP status, not this server's. A URL that resolves to a
private, loopback or tailnet address is refused with 400, by this server and by
the container, so fetching this host or a LAN page is not possible on purpose.
"""

import base64
import http.client
import ipaddress
import json
import os
import re
import shutil
import socket
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

UPSTREAM = os.environ.get("CRAWL4AI_UPSTREAM", "http://127.0.0.1:11235").rstrip("/")
TOKEN = os.environ.get("CRAWL4AI_API_TOKEN", "")
WORKSPACE = os.environ.get("CRAWL4AI_WORKSPACE", "")
MODELS_FILE = os.environ.get("CRAWL4AI_MODELS", "")
LLM_ENV_FILE = os.environ.get("CRAWL4AI_LLM_ENV", "")
PORT = int(os.environ.get("CRAWL4AI_PORT", "10001"))

MAX_IMAGES = 8
MAX_IMAGE_ATTEMPTS = 12
MAX_IMAGE_BYTES = 12 * 1024 * 1024
MAX_BODY_BYTES = 64 * 1024
KEEP_RUNS_SECONDS = 24 * 3600
WORKSPACE_MAX_BYTES = 256 * 1024 * 1024
LLM_BUDGET_SECONDS = 120
UPSTREAM_TIMEOUT = 180
IMAGE_TIMEOUT = 10

IMAGE_EXTENSIONS = {
    "image/png": ".png",
    "image/jpeg": ".jpg",
    "image/gif": ".gif",
    "image/webp": ".webp",
    "image/avif": ".avif",
    "image/svg+xml": ".svg",
}


class BadRequest(Exception):
    pass


class UpstreamError(Exception):
    def __init__(self, status, detail):
        super().__init__(detail)
        self.status = status
        self.detail = detail


def now():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def run_dir():
    prune_runs()
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    path = os.path.join(WORKSPACE, "runs", f"{stamp}-{os.urandom(3).hex()}")
    os.makedirs(path, exist_ok=True)
    return path


def directory_size(path):
    total = 0
    for base, _, files in os.walk(path):
        for name in files:
            try:
                total += os.path.getsize(os.path.join(base, name))
            except OSError:
                pass
    return total


def prune_runs():
    """Drop runs older than a day, then the oldest until the workspace fits.

    The workspace lives in the checkout, and a `path:` flake copies the checkout
    on every switch, so an unbounded run dir is paid for on the next rebuild.
    """
    root = os.path.join(WORKSPACE, "runs")
    cutoff = time.time() - KEEP_RUNS_SECONDS
    try:
        names = os.listdir(root)
    except OSError:
        return
    runs = []
    for name in names:
        path = os.path.join(root, name)
        try:
            runs.append((os.path.getmtime(path), path))
        except OSError:
            pass
    total = 0
    for mtime, path in sorted(runs, reverse=True):
        size = directory_size(path)
        if mtime < cutoff or total + size > WORKSPACE_MAX_BYTES:
            shutil.rmtree(path, ignore_errors=True)
        else:
            total += size


def upstream(path, payload=None, timeout=UPSTREAM_TIMEOUT):
    data = None if payload is None else json.dumps(payload).encode()
    headers = {"Content-Type": "application/json"}
    if TOKEN:
        headers["Authorization"] = f"Bearer {TOKEN}"
    request = urllib.request.Request(
        UPSTREAM + path,
        data=data,
        headers=headers,
        method="POST" if data is not None else "GET",
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return json.load(response)
    except urllib.error.HTTPError as exc:
        raise UpstreamError(exc.code, exc.read(4096).decode("utf-8", "replace"))
    except (ValueError, http.client.HTTPException) as exc:
        # A container that restarted mid-response, or answered with something
        # that is not JSON, is an upstream failure, not a bug in this process.
        raise UpstreamError(502, "bad response from the container: %s" % exc)
    except OSError as exc:
        raise UpstreamError(503, str(exc))


def llm_models():
    """Models to try for a query, best first, or [] when no LLM is usable.

    `models` is read per request so a model can be added or dropped while the
    service runs; the free list on OpenCode Go changes without notice. A model
    line is written the way opencode names it (`opencode-go/<model>`). The key
    is checked here only for presence: the container reads the value itself.
    """
    if not (MODELS_FILE and LLM_ENV_FILE):
        return []
    key = ""
    try:
        with open(LLM_ENV_FILE, encoding="utf-8") as handle:
            for line in handle:
                if line.startswith("OPENAI_API_KEY="):
                    key = line.split("=", 1)[1].strip()
    except OSError:
        return []
    if not key:
        return []
    models = []
    try:
        with open(MODELS_FILE, encoding="utf-8") as handle:
            for line in handle:
                line = line.strip()
                if line and not line.startswith("#"):
                    models.append(line)
    except OSError:
        return []
    return models


def upstream_provider(model):
    """`opencode-go/<model>` -> the OpenAI-compatible name the container uses.

    apps/crawl4ai/system.nix points the container's OPENAI_BASE_URL at the Go
    endpoint, so the family has to be `openai` for Crawl4AI to spend the key it
    was started with.
    """
    name = model.split("/", 1)[1] if "/" in model else model
    return "openai/" + name


def keyword_filter(text, query):
    """Keep the paragraphs that mention the query. No model, no network."""
    words = [word for word in re.findall(r"[a-z0-9]{3,}", query.lower())]
    if not words:
        return text, False
    blocks = re.split(r"\n\s*\n", text)
    kept = [block for block in blocks if any(word in block.lower() for word in words)]
    if not kept:
        return text, False
    return "\n\n".join(kept), True


class _PublicRedirects(urllib.request.HTTPRedirectHandler):
    """Re-check every hop: a public host may answer 302 to loopback."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        if not is_public(newurl):
            raise urllib.error.HTTPError(newurl, code, "redirect to a non-public address", headers, fp)
        return super().redirect_request(req, fp, code, msg, headers, newurl)


OPENER = urllib.request.build_opener(_PublicRedirects())


def is_public(source):
    """Whether a URL may be downloaded from.

    The container refuses private, loopback and shared-address destinations for
    the pages it renders; an image the page points at must not get a second,
    unchecked path to this host's own services or another tailnet peer. Every
    address the name resolves to has to be global, because a name that resolves
    to both a CDN and 127.0.0.1 is a rebinding trick. A name that does not
    resolve at all is left to the request to fail: nothing can be reached
    through it.
    """
    try:
        host = urllib.parse.urlparse(source).hostname
        if not host:
            return False
        addresses = {info[4][0] for info in socket.getaddrinfo(host, None)}
    except (OSError, ValueError):
        return True
    return bool(addresses) and all(
        ipaddress.ip_address(address.split("%", 1)[0]).is_global for address in addresses
    )


def peer_is_public(response):
    """The connected address, when the socket still exposes it."""
    try:
        address = response.fp.raw._sock.getpeername()[0]
        return ipaddress.ip_address(address.split("%", 1)[0]).is_global
    except (AttributeError, IndexError, OSError, ValueError):
        return True


def decode_image(data):
    """Screenshot bytes from either raw base64 or a data: URI, or None."""
    if data.startswith("data:"):
        header, comma, payload = data.partition(",")
        if not comma:
            return None
        data = payload
    if len(data) > MAX_IMAGE_BYTES * 4 // 3 + 4:
        return None
    try:
        body = base64.b64decode(data, validate=True)
    except ValueError:
        return None
    return body if 0 < len(body) <= MAX_IMAGE_BYTES else None


def save_image(source, page_url, directory, index):
    """Download one image the page references and return its path, or None."""
    if not source:
        return None
    if source.startswith("//"):
        # Protocol-relative, as Wikimedia and most CDNs serve them.
        source = "https:" + source
    elif not source.startswith(("http://", "https://", "data:")):
        source = urllib.parse.urljoin(page_url, source)
    try:
        if source.startswith("data:"):
            header, comma, payload = source.partition(",")
            if not comma or len(payload) > MAX_IMAGE_BYTES * 4 // 3 + 4:
                return None
            mime = header[5:].split(";", 1)[0]
            body = base64.b64decode(payload, validate=True)
        elif source.startswith(("http://", "https://")):
            if not is_public(source):
                return None
            request = urllib.request.Request(source, headers={"User-Agent": "crawl4ai-fetch/1"})
            with OPENER.open(request, timeout=IMAGE_TIMEOUT) as response:
                if not peer_is_public(response):
                    return None
                mime = (response.headers.get("Content-Type") or "").split(";", 1)[0]
                body = response.read(MAX_IMAGE_BYTES + 1)
        else:
            return None
    except (OSError, ValueError):
        return None
    if not body or len(body) > MAX_IMAGE_BYTES:
        return None
    extension = IMAGE_EXTENSIONS.get(mime, ".img")
    name = "image-%02d%s" % (index, extension)
    path = os.path.join(directory, name)
    with open(path, "wb") as handle:
        handle.write(body)
    return path


def result_text(result):
    markdown = result.get("markdown")
    if isinstance(markdown, dict):
        return markdown.get("fit_markdown") or markdown.get("raw_markdown") or ""
    if isinstance(markdown, str):
        return markdown
    return ""


def fetch(body):
    url = body.get("url")
    if not isinstance(url, str) or not url.startswith(("http://", "https://")):
        raise BadRequest("url must be an absolute http or https URL")

    want = body.get("want") or ["text"]
    if isinstance(want, str):
        want = [want]
    if not isinstance(want, list):
        raise BadRequest('want must be a list of "text" and/or "image"')
    want = [item for item in want if item in ("text", "image")]
    if not want:
        raise BadRequest('want must list "text" and/or "image"')

    query = body.get("query")
    query = query.strip() if isinstance(query, str) and query.strip() else None

    # The container refuses these too, but as a failed crawl it would come back
    # as a 502 and read like the service is broken; this is the caller's URL.
    if not is_public(url):
        raise BadRequest("url must resolve to a public http or https address")

    directory = run_dir()
    answer = {
        "url": url,
        "status": None,
        "text": "",
        "text_file": None,
        "images": [],
        "screenshot": None,
        "fetched_at": None,
        "filter": "none",
        "llm": None,
        "llm_error": None,
    }

    # networkidle, not the default domcontentloaded: a page that fills itself
    # with an XHR (search.nixos.org, most dashboards) is still empty when the
    # DOM is ready. page_timeout caps a page whose polling never settles.
    crawler_config = {"cache_mode": "bypass", "wait_until": "networkidle", "page_timeout": 60000}
    if "image" in want:
        crawler_config.update(
            {"screenshot": True, "screenshot_wait_for": 2, "wait_for_images": True}
        )

    try:
        response = upstream("/crawl", {"urls": [url], "crawler_config": crawler_config})
    except UpstreamError as exc:
        raise UpstreamError(exc.status if exc.status != 503 else 502, exc.detail)

    result = (response.get("results") or [{}])[0]
    answer["status"] = result.get("status_code") or (200 if result.get("success") else 502)
    answer["fetched_at"] = now()
    text = result_text(result)
    if not result.get("success") and not text:
        # A page that did not load is not a 200 with an empty body.
        raise UpstreamError(502, result.get("error_message") or "the container could not load the page")

    if "image" in want:
        media = result.get("media") or {}
        # Attempts are capped as well as successes: a page that lists hundreds
        # of image URLs would otherwise hold a thread for hours.
        for index, item in enumerate((media.get("images") or [])[:MAX_IMAGE_ATTEMPTS]):
            if len(answer["images"]) >= MAX_IMAGES:
                break
            source = item.get("src") if isinstance(item, dict) else None
            path = save_image(source, url, directory, index + 1)
            if path:
                answer["images"].append(path)
        body = decode_image(result["screenshot"]) if result.get("screenshot") else None
        if body:
            path = os.path.join(directory, "screenshot.png")
            with open(path, "wb") as handle:
                handle.write(body)
            answer["screenshot"] = path

    if query:
        # A model that answers replaces the text; a model that fails costs
        # another render of the page, so the whole phase has one budget and a
        # key the endpoint refuses ends it.
        deadline = time.monotonic() + LLM_BUDGET_SECONDS
        for model in llm_models():
            remaining = deadline - time.monotonic()
            if remaining < 5:
                answer["llm_error"] = answer["llm_error"] or "no time left for another model"
                break
            try:
                filtered = upstream(
                    "/md",
                    {
                        "url": url,
                        "f": "llm",
                        "q": query,
                        "provider": upstream_provider(model),
                        "c": str(int(time.time())),
                    },
                    timeout=min(UPSTREAM_TIMEOUT, remaining),
                )
            except UpstreamError as exc:
                answer["llm_error"] = "%s: HTTP %s %s" % (model, exc.status, exc.detail[:300])
                if exc.status in (401, 403):
                    break
                continue
            markdown = filtered.get("markdown")
            if isinstance(markdown, str) and markdown.strip():
                text = markdown
                answer["llm"] = model
                answer["llm_error"] = None
                break
            answer["llm_error"] = f"{model}: empty answer"
        if answer["llm"]:
            answer["filter"] = "llm"
        else:
            text, matched = keyword_filter(text, query)
            answer["filter"] = "keyword" if matched else "none"

    answer["text"] = text
    if text:
        path = os.path.join(directory, "text.md")
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(text)
        answer["text_file"] = path

    return answer


def health():
    try:
        upstream("/health", timeout=5)
        container = True
    except UpstreamError:
        container = False
    return {
        "ok": True,
        "container": container,
        "llm": "on" if llm_models() else "off",
        "workspace": WORKSPACE,
    }


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "crawl4ai-fetch/1"

    def log_message(self, fmt, *args):
        sys.stderr.write("%s %s\n" % (now(), fmt % args))

    def send_json(self, status, payload):
        body = json.dumps(payload, indent=1).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path == "/health":
            self.send_json(200, health())
            return
        if parsed.path.startswith("/artifacts/"):
            self.send_artifact(parsed.path[len("/artifacts/") :])
            return
        self.send_json(404, {"error": "no such route"})

    def send_artifact(self, relative):
        parts = relative.split("/")
        if len(parts) != 2 or not all(
            re.fullmatch(r"[A-Za-z0-9._-]{1,80}", part) and part not in (".", "..")
            for part in parts
        ):
            self.send_json(404, {"error": "no such artifact"})
            return
        root = os.path.realpath(os.path.join(WORKSPACE, "runs"))
        path = os.path.realpath(os.path.join(root, parts[0], parts[1]))
        if os.path.dirname(path) != os.path.join(root, parts[0]) or not os.path.isfile(path):
            self.send_json(404, {"error": "no such artifact"})
            return
        with open(path, "rb") as handle:
            body = handle.read()
        self.send_response(200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        # The body is read before anything is decided, so an error answer does
        # not leave unread bytes on a kept-alive connection for the next
        # request to parse as a method.
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            self.close_connection = True
            self.send_json(400, {"error": "bad Content-Length"})
            return
        if length < 1 or length > MAX_BODY_BYTES:
            self.close_connection = True
            self.send_json(400, {"error": "body must be 1 byte to %d" % MAX_BODY_BYTES})
            return
        raw = self.rfile.read(length)
        if urllib.parse.urlparse(self.path).path != "/fetch":
            self.send_json(404, {"error": "no such route"})
            return
        try:
            body = json.loads(raw)
        except (ValueError, UnicodeDecodeError):
            self.send_json(400, {"error": "body must be JSON"})
            return
        if not isinstance(body, dict):
            self.send_json(400, {"error": "body must be a JSON object"})
            return
        try:
            self.send_json(200, fetch(body))
        except BadRequest as exc:
            self.send_json(400, {"error": str(exc)})
        except UpstreamError as exc:
            self.send_json(exc.status, {"error": exc.detail, "upstream_status": exc.status})
        except Exception as exc:  # a crash must answer, not drop the socket
            self.send_json(500, {"error": "%s: %s" % (type(exc).__name__, exc)})


def main():
    if not WORKSPACE:
        raise SystemExit("CRAWL4AI_WORKSPACE is not set")
    os.makedirs(os.path.join(WORKSPACE, "runs"), exist_ok=True)
    prune_runs()
    server = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    server.daemon_threads = True
    print(f"crawl4ai-fetch listening on 0.0.0.0:{PORT}, upstream {UPSTREAM}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
