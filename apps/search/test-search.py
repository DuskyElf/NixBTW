#!/usr/bin/env python3
"""End to end test for search.py against fake providers.

No network and no keys: three HTTP servers on loopback answer with the shape
each real API returns, and the service runs as its own process with
SEARCH_*_URL pointing at them. Run it after editing search.py:

    python3 apps/search/test-search.py

The scratch directory lives under the repo's .tmp/ and is removed on exit.
"""

import http.client
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))

# What each fake answers, and what it saw.
STATUS = {"tavily": 200, "exa": 200, "tinyfish": 200}
SEEN = {"tavily": [], "exa": [], "tinyfish": []}
# A delay before answering, a 200 whose body is `null` instead of an object, and
# a 200 whose results list is the wrong shape.
DELAY = {"tavily": 0, "exa": 0, "tinyfish": 0}
GARBAGE = {"tavily": False, "exa": False, "tinyfish": False}
BAD_RESULTS = {"tavily": False, "exa": False, "tinyfish": False}
BAD_FIELDS = {"tavily": False, "exa": False, "tinyfish": False}
# A refusal status whose body stalls halfway, which is how a real 429 looks when
# the provider is busy.
STALL_BODY = {"tavily": False, "exa": False, "tinyfish": False}
EMPTY = {"tavily": False, "exa": False, "tinyfish": False}


class Fake(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    name = ""

    def log_message(self, fmt, *args):
        pass

    def reply(self, status, payload):
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        try:
            self.wfile.write(body)
        except OSError:
            # The service timed out on this one and hung up; the write is the
            # only thing left to do.
            pass

    def do_GET(self):
        if self.name != "tinyfish":
            self.reply(404, {"error": "no"})
            return
        parsed = urllib.parse.urlparse(self.path)
        SEEN["tinyfish"].append(urllib.parse.parse_qs(parsed.query))
        time.sleep(DELAY["tinyfish"])
        if STATUS["tinyfish"] != 200:
            self.reply(STATUS["tinyfish"], {"error": "tinyfish refused"})
            return
        if EMPTY["tinyfish"]:
            self.reply(200, {"results": []})
            return
        self.reply(
            200,
            {
                "query": "q",
                "page": 0,
                "total_results": 2,
                "results": [
                    {
                        "position": 1,
                        "site_name": "tiny.example",
                        "title": "TinyFish result",
                        "snippet": "tiny   snippet\n with   spaces",
                        "url": "https://tiny.example/1",
                        "date": "2026-11-02",
                    },
                    {
                        "position": 2,
                        "site_name": "tiny.example",
                        "title": "Second",
                        "snippet": "second",
                        "url": "https://tiny.example/2",
                    },
                ],
            },
        )

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        body = json.loads(self.rfile.read(length) or b"{}")
        SEEN[self.name].append(body)
        time.sleep(DELAY[self.name])
        if GARBAGE[self.name]:
            self.reply(200, None)
            return
        if STALL_BODY[self.name]:
            self.send_response(429)
            self.send_header("Content-Length", "100")
            self.end_headers()
            self.wfile.write(b'{"error":')
            self.wfile.flush()
            time.sleep(2)
            return
        if BAD_RESULTS[self.name]:
            self.reply(200, {"results": 7})
            return
        if BAD_FIELDS[self.name]:
            self.reply(
                200,
                {
                    "results": [
                        {"content": 7, "title": {"k": 1}, "url": 9, "publishedDate": 5, "text": 8}
                    ]
                },
            )
            return
        if STATUS[self.name] != 200:
            self.reply(STATUS[self.name], {"error": "%s refused" % self.name})
            return
        if EMPTY[self.name]:
            self.reply(200, {"results": []})
            return
        if self.name == "tavily":
            self.reply(
                200,
                {
                    "query": body.get("query"),
                    "results": [
                        {
                            "title": "Tavily result",
                            "url": "https://tavily.example/1",
                            "content": "  tavily\n content ",
                            "published_date": "Tue, 11 Mar 2025 17:00:00 GMT",
                        }
                    ],
                },
            )
        else:
            self.reply(
                200,
                {
                    "results": [
                        {
                            "title": "Exa result",
                            "url": "https://exa.example/1",
                            "text": "exa text",
                            "publishedDate": "2026-11-01T00:00:00.000Z",
                        }
                    ]
                },
            )


def serve(name):
    server = ThreadingHTTPServer(("127.0.0.1", 0), type(name, (Fake,), {"name": name}))
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def post(port, path, payload):
    request = urllib.request.Request(
        f"http://127.0.0.1:{port}{path}",
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return response.status, json.load(response)
    except urllib.error.HTTPError as exc:
        return exc.code, json.load(exc)


def get(port, path):
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{port}{path}", timeout=30) as response:
            return response.status, json.load(response)
    except urllib.error.HTTPError as exc:
        return exc.code, json.load(exc)


def check(label, condition, detail=""):
    if not condition:
        raise AssertionError(f"{label}: {detail}")
    print(f"ok  {label}")


def wait_for(port):
    for _ in range(100):
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.2):
                return
        except OSError:
            time.sleep(0.05)
    raise AssertionError("search.py did not start listening")


def launch(servers, keys, port, overrides):
    env = dict(os.environ)
    env.update(
        {
            "SEARCH_KEYS": keys,
            "SEARCH_PORT": str(port),
            "SEARCH_TIMEOUT": "0.5",
            "SEARCH_TAVILY_URL": f"http://127.0.0.1:{servers['tavily'].server_address[1]}/search",
            "SEARCH_EXA_URL": f"http://127.0.0.1:{servers['exa'].server_address[1]}/search",
            "SEARCH_TINYFISH_URL": f"http://127.0.0.1:{servers['tinyfish'].server_address[1]}/",
        }
    )
    env.update(overrides)
    return subprocess.Popen(
        [sys.executable, os.path.join(HERE, "search.py")],
        env=env,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )


def main():
    os.makedirs(os.path.join(REPO, ".tmp"), exist_ok=True)
    scratch = tempfile.mkdtemp(prefix="test-search-", dir=os.path.join(REPO, ".tmp"))
    servers = {name: serve(name) for name in ("tavily", "exa", "tinyfish")}
    keys = os.path.join(scratch, "keys.env")
    with open(keys, "w") as handle:
        handle.write("# empty on purpose\n")

    port = free_port()
    service = launch(servers, keys, port, {})
    try:
        wait_for(port)

        status, body = get(port, "/health")
        check(
            "health reports three providers with no keys",
            status == 200 and body["providers"] == {"tavily": False, "exa": False, "tinyfish": False},
            body,
        )

        status, body = post(port, "/search", {"query": "nixos release date"})
        check("no key answers 503", status == 503, (status, body))

        # One key, written after the service started: it must be picked up
        # without a restart.
        with open(keys, "w") as handle:
            handle.write("TINYFISH_API_KEY=tf-test\n")
        status, body = post(port, "/search", {"query": "nixos release date"})
        check("a key written at run time is used", status == 200, (status, body))
        check("the only keyed provider answers", body["provider"] == "tinyfish", body)
        check("two results mapped", len(body["results"]) == 2, body["results"])
        check("title from tinyfish", body["results"][0]["title"] == "TinyFish result")
        check("content is collapsed whitespace", body["results"][0]["content"] == "tiny snippet with spaces")
        check("date passed through", body["results"][0]["published_at"] == "2026-11-02")
        check("tinyfish got the query", SEEN["tinyfish"][-1]["query"] == ["nixos release date"])

        status, body = post(port, "/search", {"query": "x", "provider": "tinyfish"})
        check("a forced provider that has a key answers", body["provider"] == "tinyfish", body)
        status, body = post(port, "/search", {"query": "x", "provider": "exa"})
        check("a forced provider without a key is a 400", status == 400 and "no key" in body["error"], body)
        status, body = post(port, "/search", {"query": "x", "provider": "nope"})
        check("an unknown provider is a 400", status == 400, body)

        # All three keyed: requests must spread across them.
        with open(keys, "w") as handle:
            handle.write("TAVILY_API_KEY=tv-test\nEXA_API_KEY=exa-test\nTINYFISH_API_KEY=tf-test\n")
        status, body = get(port, "/health")
        check("health sees all three keys", all(body["providers"].values()), body)

        picked = set()
        for _ in range(30):
            status, body = post(port, "/search", {"query": "spread"})
            check("a spread request answers", status == 200, body)
            picked.add(body["provider"])
        check("every provider gets chosen over 30 requests", picked == {"tavily", "exa", "tinyfish"}, picked)
        check(
            "tavily's date is normalised to iso",
            post(port, "/search", {"query": "x", "provider": "tavily"})[1]["results"][0]["published_at"]
            == "2025-03-11T17:00:00Z",
        )

        # Freshness reaches each provider in its own dialect.
        post(port, "/search", {"query": "x", "provider": "tavily", "freshness": "week"})
        check("tavily got time_range", SEEN["tavily"][-1].get("time_range") == "week", SEEN["tavily"][-1])
        post(port, "/search", {"query": "x", "provider": "exa", "freshness": "week"})
        check("exa got a start date", "startPublishedDate" in SEEN["exa"][-1], SEEN["exa"][-1])
        post(port, "/search", {"query": "x", "provider": "tinyfish", "freshness": "week"})
        check("tinyfish got recency minutes", SEEN["tinyfish"][-1].get("recency_minutes") == ["10080"], SEEN["tinyfish"][-1])

        # Two providers refuse, the third answers, and the request still does.
        STATUS["tavily"] = 500
        STATUS["exa"] = 429
        for _ in range(20):
            status, body = post(port, "/search", {"query": "failover"})
            check("a refusing provider falls through", status == 200 and body["provider"] == "tinyfish", body)

        # Every keyed provider refusing is a 502 that says why.
        STATUS["tinyfish"] = 429
        status, body = post(port, "/search", {"query": "all fail"})
        check("all providers failing is a 502", status == 502, status)
        check("the failure lists each provider", len(body.get("errors") or []) == 3, body)
        check("the statuses survive", {error["status"] for error in body["errors"]} == {500, 429}, body)

        # A 200 whose body is not an object must fail through like a refusal,
        # not escape as a 500 and lose the providers behind it.
        STATUS.update({"tavily": 200, "exa": 200, "tinyfish": 200})
        GARBAGE["tavily"] = True
        for _ in range(20):
            status, body = post(port, "/search", {"query": "garbage"})
            check(
                "a malformed provider body falls through",
                status == 200 and body["provider"] in {"exa", "tinyfish"},
                body,
            )
        status, body = post(port, "/search", {"query": "garbage", "provider": "tavily"})
        check("a malformed body alone is a 502", status == 502, body)
        check("the malformed body is recorded as a 502", body["errors"][0]["status"] == 502, body)
        GARBAGE["tavily"] = False

        # The same at one level down: a results list that is not a list of
        # objects must fail through instead of raising in the mapper.
        BAD_RESULTS["tavily"] = True
        status, body = post(port, "/search", {"query": "bad results"})
        check(
            "a malformed results list falls through",
            status == 200 and body["provider"] in {"exa", "tinyfish"},
            body,
        )
        status, body = post(port, "/search", {"query": "bad results", "provider": "tavily"})
        check("a malformed results list alone is a 502", status == 502, body)
        BAD_RESULTS["tavily"] = False

        # A refusal whose body stalls halfway: reading it must not escape the
        # failthrough as a 500.
        STALL_BODY["tavily"] = True
        for _ in range(5):
            status, body = post(port, "/search", {"query": "stalled error"})
            check(
                "a stalled error body falls through",
                status == 200 and body["provider"] in {"exa", "tinyfish"},
                body,
            )
        status, body = post(port, "/search", {"query": "stalled error", "provider": "tavily"})
        check(
            "a stalled error body alone keeps the refusal status",
            status == 502 and body["errors"][0]["status"] == 429,
            body,
        )
        STALL_BODY["tavily"] = False

        # A result item whose fields are not strings must not raise in the
        # mapper, and must not come back as nested objects.
        BAD_FIELDS["exa"] = True
        status, body = post(port, "/search", {"query": "bad fields", "provider": "exa"})
        result = (body.get("results") or [{}])[0]
        check(
            "a malformed field is coerced to a string",
            status == 200
            and all(isinstance(result.get(key), str) for key in ("title", "url", "content", "published_at")),
            result,
        )
        BAD_FIELDS["exa"] = False

        # What each provider is actually asked.
        post(port, "/search", {"query": "shape", "provider": "tavily", "limit": 3})
        check("tavily got the limit", SEEN["tavily"][-1].get("max_results") == 3, SEEN["tavily"][-1])
        check("tavily stays on basic depth", SEEN["tavily"][-1].get("search_depth") == "basic")
        post(port, "/search", {"query": "shape", "provider": "exa", "limit": 3})
        check("exa got the limit", SEEN["exa"][-1].get("numResults") == 3, SEEN["exa"][-1])
        check("exa stays lite", SEEN["exa"][-1].get("type") == "lite")
        post(port, "/search", {"query": "shape", "provider": "tavily", "limit": 99})
        check(
            "the limit is clamped to the API maximum",
            SEEN["tavily"][-1].get("max_results") == 20,
            SEEN["tavily"][-1],
        )

        # An empty result list is an answer, not an error.
        EMPTY["exa"] = True
        status, body = post(port, "/search", {"query": "nothing", "provider": "exa"})
        check("an empty result list still answers", status == 200 and body["results"] == [], body)
        EMPTY["exa"] = False

        # A provider that never answers costs one attempt, then the next one
        # answers. SEARCH_TIMEOUT is half a second in this run.
        DELAY["tavily"] = 2
        started = time.monotonic()
        status, body = post(port, "/search", {"query": "slow", "provider": "tavily"})
        elapsed = time.monotonic() - started
        check("a slow provider times out into a 502", status == 502, body)
        check("the timeout is the per-attempt one", elapsed < 1.5, elapsed)
        DELAY["exa"] = 2
        for _ in range(5):
            status, body = post(port, "/search", {"query": "slow"})
            check(
                "two slow providers fall through to the third",
                status == 200 and body["provider"] == "tinyfish",
                body,
            )
        DELAY.update({"tavily": 0, "exa": 0})

        # All three slow: the whole-request budget ends the wait even though
        # every attempt would still be allowed its own timeout.
        DELAY.update({"tavily": 2, "exa": 2, "tinyfish": 2})
        budget_port = free_port()
        budget = launch(servers, keys, budget_port, {"SEARCH_TIMEOUT": "5", "SEARCH_BUDGET": "1.5"})
        try:
            wait_for(budget_port)
            before = sum(len(SEEN[name]) for name in SEEN)
            started = time.monotonic()
            status, body = post(budget_port, "/search", {"query": "budget"})
            elapsed = time.monotonic() - started
            after = sum(len(SEEN[name]) for name in SEEN)
            check("three slow providers end in a 502", status == 502, body)
            check("the budget cuts the wait", 1.3 <= elapsed < 2.4, elapsed)
            check("the budget spends exactly one attempt", after - before == 1, (after, before))
            check(
                "the providers the budget skipped say why",
                any(error["status"] == 504 for error in body["errors"]),
                body,
            )
        finally:
            budget.terminate()
            budget.wait(timeout=10)
        DELAY.update({"tavily": 0, "exa": 0, "tinyfish": 0})

        # A non-string is a 400, not a 500 out of the membership test.
        status, body = post(port, "/search", {"query": "x", "freshness": ["day"]})
        check("a non-string freshness is a 400", status == 400, body)
        status, body = post(port, "/search", {"query": "x", "provider": ["tavily"]})
        check("a non-string provider is a 400", status == 400, body)

        # Bad input, and a kept-alive connection afterwards.
        status, body = post(port, "/search", {"limit": 3})
        check("a missing query is a 400", status == 400, body)
        status, body = post(port, "/search", {"query": "x", "limit": "ten"})
        check("a string limit is a 400", status == 400, body)
        status, body = post(port, "/search", {"query": "x", "freshness": "decade"})
        check("an unknown freshness is a 400", status == 400, body)
        status, body = post(port, "/nope", {"query": "x"})
        check("an unknown route is a 404", status == 404, body)

        # A request that gives up on its body closes the socket; the answer has
        # to say so or the client reuses it.
        conn = http.client.HTTPConnection("127.0.0.1", port, timeout=30)
        conn.request(
            "POST",
            "/search",
            body=b"",
            headers={"Content-Length": "0", "Content-Type": "application/json"},
        )
        aborted = conn.getresponse()
        aborted.read()
        check(
            "an aborted body says the connection closes",
            aborted.getheader("Connection") == "close",
            aborted.getheaders(),
        )
        conn.close()

        conn = http.client.HTTPConnection("127.0.0.1", port, timeout=30)
        conn.request("POST", "/nope", body=b'{"query":"x"}', headers={"Content-Type": "application/json"})
        first = conn.getresponse()
        first.read()
        conn.request("GET", "/health")
        second = conn.getresponse()
        check("a kept-alive connection survives an error", second.status == 200, second.status)
        conn.close()

        print("\nall checks passed")
    finally:
        service.terminate()
        service.wait(timeout=10)
        for server in servers.values():
            try:
                server.shutdown()
                server.server_close()
            except OSError:
                pass
        shutil.rmtree(scratch, ignore_errors=True)


if __name__ == "__main__":
    main()
