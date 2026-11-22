#!/usr/bin/env python3
"""One search endpoint over Tavily, Exa and TinyFish.

SearXNG is gone: the engines it scrapes refuse this box's address (google
answers "access denied", duckduckgo a CAPTCHA, Bing an SEO farm for the same
query when it is not refusing outright), and every public instance in
searx.space either blocks an API client or has JSON turned off. What is left is
the search APIs themselves, so this is the small thing in front of them.

    POST /search  {"query": "...", "limit": 10, "freshness": "day|week|month|year",
                   "provider": "tavily|exa|tinyfish"}
      -> {"query", "provider", "results": [{"title", "url", "content",
          "published_at"}], "took_ms"}

    GET /health   -> {"ok", "providers": {"tavily": bool, ...}}

Each request picks one of the providers that has a key at random, so three free
tiers are spent evenly instead of one being drained, and falls through to the
next provider when the chosen one refuses (401, 402, 429, 5xx, timeout). That is
the rate-limit handling: a provider that says no costs one attempt in a request
that still answers. `provider` forces one, which is how the tests and a caller
that knows what it wants pin a source.

Keys are read from SEARCH_KEYS on every request, so writing one takes effect on
the next request with no restart:
    TAVILY_API_KEY=tvly-...
    EXA_API_KEY=...
    TINYFISH_API_KEY=...
A provider with no key is never chosen. SEARCH_TIMEOUT (per socket operation,
default 10s) and SEARCH_BUDGET (what the attempts share, default 20s) are what
the test uses to exercise a slow provider without waiting.

Free tiers, as of November 2026: TinyFish 12,000 requests/day, Tavily 1,000
credits/month, Exa $10 of credit per month that resets. The response says which
provider answered so a caller can tell them apart.
"""

import email.utils
import json
import os
import random
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

KEYS_FILE = os.environ.get("SEARCH_KEYS", "")
PORT = int(os.environ.get("SEARCH_PORT", "10001"))
TIMEOUT = float(os.environ.get("SEARCH_TIMEOUT", "10"))
# The caller waits for the whole request, not for each attempt: three providers
# at ten seconds each would be half a minute. This is the budget the attempts
# share.
BUDGET = float(os.environ.get("SEARCH_BUDGET", "20"))
MAX_BODY_BYTES = 16 * 1024
MAX_QUERY_CHARS = 500
MAX_CONTENT_CHARS = 1200
MAX_LIMIT = 20

FRESHNESS_DAYS = {"day": 1, "week": 7, "month": 30, "year": 365}

TAVILY_URL = os.environ.get("SEARCH_TAVILY_URL", "https://api.tavily.com/search")
EXA_URL = os.environ.get("SEARCH_EXA_URL", "https://api.exa.ai/search")
TINYFISH_URL = os.environ.get("SEARCH_TINYFISH_URL", "https://api.search.tinyfish.ai")


class BadRequest(Exception):
    pass


class ProviderError(Exception):
    def __init__(self, status, detail):
        super().__init__(detail)
        self.status = status
        self.detail = detail


class AllFailed(ProviderError):
    """Every provider that had a key refused; the list says how."""

    def __init__(self, errors):
        # A request the budget cut short before any provider answered is the
        # aggregator's own timeout, not a bad gateway.
        code = 504 if errors and all(error["status"] == 504 for error in errors) else 502
        super().__init__(code, "every provider failed")
        self.errors = errors


def now_iso():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def text(value):
    """A display string, whatever a provider put in the field."""
    return "" if value is None else str(value)


def clean(text):
    return " ".join(str(text or "").split())[:MAX_CONTENT_CHARS]


def iso_date(value):
    """A published date as ISO 8601 when it can be read, else as given."""
    if not value:
        return None
    if not isinstance(value, str):
        return str(value)
    try:
        return email.utils.parsedate_to_datetime(value).astimezone(timezone.utc).strftime(
            "%Y-%m-%dT%H:%M:%SZ"
        )
    except (TypeError, ValueError):
        return str(value)


def read_keys():
    """The provider keys, re-read per request so a new one needs no restart."""
    keys = {}
    if not KEYS_FILE:
        return keys
    try:
        with open(KEYS_FILE, encoding="utf-8") as handle:
            for line in handle:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                name, _, value = line.partition("=")
                keys[name.strip().removeprefix("export ")] = value.strip().strip("'\"")
    except (OSError, UnicodeDecodeError):
        return {}
    return {name: value for name, value in keys.items() if value}


def call(request, timeout=TIMEOUT):
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            data = json.load(response)
    except urllib.error.HTTPError as exc:
        try:
            detail = exc.read(2048).decode("utf-8", "replace")
        except OSError:
            # The provider stalled or dropped the body of its own error.
            detail = ""
        raise ProviderError(exc.code, detail)
    except (OSError, ValueError) as exc:
        raise ProviderError(502, "%s: %s" % (type(exc).__name__, exc))
    # A 200 whose body is not an object is a refusal like any other: without
    # this the attribute access in each provider would escape as a 500 and the
    # request would lose the next provider that could have answered. The same
    # goes for the results list, which every provider shares.
    if not isinstance(data, dict):
        raise ProviderError(502, "provider answered %s, not an object" % type(data).__name__)
    items = data.get("results")
    if not isinstance(items, list) or not all(isinstance(item, dict) for item in items):
        raise ProviderError(502, "provider answered with a malformed results list")
    return data


def post_json(url, payload, headers, timeout):
    body = json.dumps(payload).encode()
    headers = dict(headers, **{"Content-Type": "application/json"})
    return call(urllib.request.Request(url, data=body, headers=headers, method="POST"), timeout)


def search_tavily(key, query, limit, freshness, timeout):
    payload = {
        "query": query,
        "max_results": limit,
        "search_depth": "basic",
        "include_answer": False,
        "include_published_date": True,
    }
    if freshness:
        payload["time_range"] = freshness
    data = post_json(TAVILY_URL, payload, {"Authorization": f"Bearer {key}"}, timeout)
    return [
        {
            "title": text(item.get("title")),
            "url": text(item.get("url")),
            "content": clean(item.get("content")),
            "published_at": iso_date(item.get("published_date")),
        }
        for item in data.get("results") or []
    ][:limit]


def search_exa(key, query, limit, freshness, timeout):
    payload = {
        "query": query,
        "type": "lite",
        "numResults": limit,
        "contents": {"text": {"maxCharacters": MAX_CONTENT_CHARS}},
    }
    if freshness:
        start = datetime.now(timezone.utc) - timedelta(days=FRESHNESS_DAYS[freshness])
        payload["startPublishedDate"] = start.strftime("%Y-%m-%dT%H:%M:%S.000Z")
    data = post_json(EXA_URL, payload, {"Authorization": f"Bearer {key}"}, timeout)
    return [
        {
            "title": text(item.get("title")),
            "url": text(item.get("url")),
            "content": clean(item.get("text") or item.get("summary")),
            "published_at": iso_date(item.get("publishedDate")),
        }
        for item in data.get("results") or []
    ][:limit]


def search_tinyfish(key, query, limit, freshness, timeout):
    params = {"query": query, "language": "en", "page": 0}
    if freshness:
        params["recency_minutes"] = FRESHNESS_DAYS[freshness] * 24 * 60
    url = TINYFISH_URL + "?" + urllib.parse.urlencode(params)
    data = call(urllib.request.Request(url, headers={"X-API-Key": key}), timeout)
    return [
        {
            "title": text(item.get("title")),
            "url": text(item.get("url")),
            "content": clean(item.get("snippet")),
            "published_at": iso_date(item.get("date")),
        }
        for item in data.get("results") or []
    ][:limit]


# name -> (function, environment name in the keys file)
PROVIDERS = {
    "tavily": (search_tavily, "TAVILY_API_KEY"),
    "exa": (search_exa, "EXA_API_KEY"),
    "tinyfish": (search_tinyfish, "TINYFISH_API_KEY"),
}


def search(body):
    query = body.get("query")
    if not isinstance(query, str) or not query.strip():
        raise BadRequest("query must be a non-empty string")
    query = query.strip()
    if len(query) > MAX_QUERY_CHARS:
        raise BadRequest("query must be at most %d characters" % MAX_QUERY_CHARS)

    limit = body.get("limit", 10)
    if not isinstance(limit, int) or isinstance(limit, bool):
        raise BadRequest("limit must be an integer")
    limit = max(1, min(limit, MAX_LIMIT))

    freshness = body.get("freshness")
    if freshness is not None and (
        not isinstance(freshness, str) or freshness not in FRESHNESS_DAYS
    ):
        raise BadRequest('freshness must be one of "day", "week", "month", "year"')

    keys = read_keys()
    available = [name for name in PROVIDERS if keys.get(PROVIDERS[name][1])]

    forced = body.get("provider")
    if forced is not None:
        if not isinstance(forced, str) or forced not in PROVIDERS:
            raise BadRequest("provider must be one of %s" % ", ".join(PROVIDERS))
        if forced not in available:
            raise BadRequest("provider %s has no key in %s" % (forced, KEYS_FILE))
        order = [forced]
    else:
        if not available:
            raise ProviderError(503, "no provider key in %s" % KEYS_FILE)
        order = random.SystemRandom().sample(available, len(available))

    started = time.monotonic()
    deadline = started + BUDGET
    errors = []
    for name in order:
        func, env_name = PROVIDERS[name]
        left = deadline - time.monotonic()
        if left <= 0:
            errors.append(
                {"provider": name, "status": 504, "error": "no time left in the budget"}
            )
            continue
        try:
            results = func(keys[env_name], query, limit, freshness, min(TIMEOUT, left))
        except ProviderError as exc:
            errors.append({"provider": name, "status": exc.status, "error": exc.detail[:300]})
            continue
        return {
            "query": query,
            "provider": name,
            "results": results,
            "took_ms": int((time.monotonic() - started) * 1000),
        }
    raise AllFailed(errors)


def health():
    keys = read_keys()
    return {
        "ok": True,
        "providers": {name: bool(keys.get(env)) for name, (_, env) in PROVIDERS.items()},
    }


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "search-api/1"

    def log_message(self, fmt, *args):
        sys.stderr.write("%s %s\n" % (now_iso(), fmt % args))

    def send_json(self, status, payload):
        body = json.dumps(payload, indent=1).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        # The two paths that give up on the body set this before answering; say
        # so, or a client reuses a socket the handler is about to close.
        if self.close_connection:
            self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if urllib.parse.urlparse(self.path).path == "/health":
            self.send_json(200, health())
            return
        self.send_json(404, {"error": "no such route"})

    def do_POST(self):
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
        if urllib.parse.urlparse(self.path).path != "/search":
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
            self.send_json(200, search(body))
        except BadRequest as exc:
            self.send_json(400, {"error": str(exc)})
        except AllFailed as exc:
            self.send_json(exc.status, {"error": "every provider failed", "errors": exc.errors})
        except ProviderError as exc:
            self.send_json(exc.status, {"error": exc.detail})
        except Exception as exc:  # a crash must answer, not drop the socket
            self.send_json(500, {"error": "%s: %s" % (type(exc).__name__, exc)})


def main():
    server = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    server.daemon_threads = True
    print(f"search-api listening on 0.0.0.0:{PORT}, keys {KEYS_FILE}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
