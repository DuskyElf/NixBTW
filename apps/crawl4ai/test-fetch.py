#!/usr/bin/env python3
"""End to end test for fetch.py against a fake Crawl4AI container.

No network and no store: the fake answers on loopback with the shape the real
container returns, and the shim runs as its own process exactly as systemd
starts it. Run it after editing fetch.py:

    python3 apps/crawl4ai/test-fetch.py

The scratch directory lives under the repo's .tmp/ and is removed on exit; this
machine's /tmp is shared with every other agent and every nix build.
"""

import base64
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
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
PNG = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFAAH/q842iQAAAABJRU5ErkJggg=="
)
GIF = base64.b64decode("R0lGODlhAQABAIABAAAf/wAAACH5BAAAAAAALAAAAAABAAEAAAICTAEAOw==")

CALLS = []
QUERY_ANSWER = None
QUERY_STATUS = 200


class Fake(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        pass

    def reply(self, status, payload):
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        port = self.server.server_address[1]
        if self.path == "/health":
            self.reply(200, {"status": "ok"})
        elif self.path == "/img.png":
            self.send_response(200)
            self.send_header("Content-Type", "image/png")
            self.send_header("Content-Length", str(len(PNG)))
            self.end_headers()
            self.wfile.write(PNG)
        else:
            self.reply(404, {"error": "no"})

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        body = json.loads(self.rfile.read(length) or b"{}")
        CALLS.append((self.path, body, self.headers.get("Authorization")))
        if self.path == "/crawl":
            self.reply(
                200,
                {
                    "success": True,
                    "results": [
                        {
                            "success": True,
                            "status_code": 200,
                            "markdown": {
                                "fit_markdown": "# Rendered page\n\nNiri is a scrollable tiling compositor.",
                                "raw_markdown": "# raw fallback",
                            },
                            "media": {
                                "images": [
                                    # Loopback and page-relative names that
                                    # resolve to loopback: both must be refused,
                                    # or a page could make this host probe its
                                    # own services.
                                    {"src": f"http://127.0.0.1:{self.server.server_address[1]}/img.png"},
                                    {"src": "/img.png"},
                                    {"src": "data:image/png;base64," + base64.b64encode(PNG).decode()},
                                    {"src": "data:image/gif;base64," + base64.b64encode(GIF).decode()},
                                ]
                            },
                            "screenshot": base64.b64encode(PNG).decode(),
                        }
                    ],
                },
            )
        elif self.path == "/md":
            if QUERY_STATUS != 200:
                self.reply(QUERY_STATUS, {"detail": "model refused"})
            else:
                self.reply(200, {"success": True, "markdown": QUERY_ANSWER or "llm answer"})
        else:
            self.reply(404, {"error": "no"})


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
            return response.status, response.read()
    except urllib.error.HTTPError as exc:
        return exc.code, exc.read()


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
    raise AssertionError("fetch.py did not start listening")


def main():
    os.makedirs(os.path.join(REPO, ".tmp"), exist_ok=True)
    scratch = tempfile.mkdtemp(prefix="test-crawl4ai-", dir=os.path.join(REPO, ".tmp"))
    upstream = ThreadingHTTPServer(("127.0.0.1", 0), Fake)
    threading.Thread(target=upstream.serve_forever, daemon=True).start()

    workspace = os.path.join(scratch, "workspace")
    models = os.path.join(scratch, "models")
    llm_env = os.path.join(scratch, "llm.env")
    with open(models, "w") as handle:
        handle.write("# comment\nopencode-go/hy4-flash-free\n")
    with open(llm_env, "w") as handle:
        handle.write("OPENAI_API_KEY=\n")

    port = free_port()
    # A name that is public-looking, because a loopback page URL is refused
    # before the container is asked. The fake ignores the URL.
    page_url = "https://example.test/page"
    env = dict(os.environ)
    env.update(
        {
            "CRAWL4AI_UPSTREAM": f"http://127.0.0.1:{upstream.server_address[1]}",
            "CRAWL4AI_API_TOKEN": "test-token",
            "CRAWL4AI_WORKSPACE": workspace,
            "CRAWL4AI_MODELS": models,
            "CRAWL4AI_LLM_ENV": llm_env,
            "CRAWL4AI_PORT": str(port),
        }
    )
    shim = subprocess.Popen(
        [sys.executable, os.path.join(HERE, "fetch.py")],
        env=env,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    try:
        wait_for(port)

        status, body = get(port, "/health")
        check("health answers", status == 200 and body and json.loads(body)["container"] is True)
        check("health says llm is off without a key", json.loads(body)["llm"] == "off")

        # Text only: no screenshot requested, markdown comes from fit_markdown.
        status, answer = post(port, "/fetch", {"url": page_url, "want": ["text"]})
        check("text fetch is 200", status == 200, answer)
        check("text is the fit markdown", answer["text"].startswith("# Rendered page"), answer["text"])
        check("text_file exists", answer["text_file"] and open(answer["text_file"]).read() == answer["text"])
        check("text_file is absolute", os.path.isabs(answer["text_file"]))
        check("no screenshot for want text", answer["screenshot"] is None)
        check("no images for want text", answer["images"] == [])
        check("status carries the page status", answer["status"] == 200)
        check("container got the bearer token", CALLS[0][2] == "Bearer test-token")
        check("container was not asked for a screenshot", "screenshot" not in CALLS[0][1]["crawler_config"])

        # Text and images: one screenshot, the two data: images written, and the
        # two addresses that point at this host refused. The HTTP image path is
        # covered by the live check against a real page; a test cannot serve a
        # globally routable address from here, and loopback must be refused.
        status, answer = post(port, "/fetch", {"url": page_url, "want": ["text", "image"]})
        check("image fetch is 200", status == 200, answer)
        check("screenshot is a path", answer["screenshot"] and os.path.isabs(answer["screenshot"]))
        check("screenshot bytes are the container's png", open(answer["screenshot"], "rb").read() == PNG)
        check("two images were written", len(answer["images"]) == 2, answer["images"])
        check("first image is a png from a data uri", answer["images"][0].endswith(".png") and open(answer["images"][0], "rb").read() == PNG)
        check("second image is a gif from a data uri", answer["images"][1].endswith(".gif") and open(answer["images"][1], "rb").read() == GIF)
        check("container was asked for a screenshot", CALLS[1][1]["crawler_config"]["screenshot"] is True)
        check("container was asked for a screenshot", CALLS[1][1]["crawler_config"]["screenshot"] is True)
        check("images waited for", CALLS[1][1]["crawler_config"].get("wait_for_images") is True)

        # Image only still answers with the text; the list only adds files.
        status, answer = post(port, "/fetch", {"url": page_url, "want": ["image"]})
        check("image-only fetch still has text", status == 200 and bool(answer["text"]), answer)

        # A query with no key filters by keyword, and never calls the LLM.
        status, answer = post(port, "/fetch", {"url": page_url, "query": "niri compositor"})
        check("keyword filter is used without a key", answer["filter"] == "keyword", answer)
        check("keyword filter keeps the matching paragraph", "scrollable tiling" in answer["text"])
        check("no llm model was used", answer["llm"] is None)
        check("the llm endpoint was not called", all(call[0] != "/md" for call in CALLS))

        # With a key the container's own LLM filter answers.
        with open(llm_env, "w") as handle:
            handle.write("OPENAI_API_KEY=sk-test\n")
        status, answer = post(port, "/fetch", {"url": page_url, "query": "niri"})
        check("llm filter is used with a key", answer["filter"] == "llm", answer)
        check("the model is reported", answer["llm"] == "opencode-go/hy4-flash-free")
        check("the llm markdown is the text", answer["text"] == "llm answer")
        md_calls = [call for call in CALLS if call[0] == "/md"]
        check("provider is rewritten for the container", md_calls[-1][1]["provider"] == "openai/hy4-flash-free", md_calls[-1][1])
        check("the query is passed", md_calls[-1][1]["q"] == "niri")

        # A failing model degrades to the keyword filter instead of failing.
        global QUERY_STATUS
        QUERY_STATUS = 500
        status, answer = post(port, "/fetch", {"url": page_url, "query": "niri"})
        check("a refused model still answers", status == 200, answer)
        check("it falls back to keyword", answer["filter"] == "keyword", answer)
        check("the model error is reported", "HTTP 500" in (answer.get("llm_error") or ""), answer)
        QUERY_STATUS = 200

        # Artifacts can be pulled by a caller on another machine.
        relative = os.path.relpath(answer["text_file"], os.path.join(workspace, "runs"))
        status, body = get(port, "/artifacts/" + relative.replace(os.sep, "/"))
        check("artifact is served", status == 200 and body == answer["text"].encode(), status)

        # A file next to runs/ is reachable only if the guard lets ".." through.
        canary = os.path.join(workspace, "canary.txt")
        with open(canary, "w") as handle:
            handle.write("secret")
        status, _ = get(port, "/artifacts/../canary.txt")
        check("artifact traversal through a dot dot is refused", status == 404, status)
        status, _ = get(port, "/artifacts/..%2fcanary.txt")
        check("artifact traversal through an encoded slash is refused", status == 404, status)
        run = relative.split(os.sep)[0]
        status, _ = get(port, "/artifacts/%s/../../../canary.txt" % run)
        check("artifact traversal out of a run is refused", status == 404, status)

        status, answer = post(port, "/fetch", {"url": "ftp://example.test"})
        check("a non http url is refused", status == 400, answer)
        status, answer = post(port, "/fetch", {"url": f"http://127.0.0.1:{upstream.server_address[1]}/x"})
        check("a loopback page url is refused", status == 400 and "public" in answer.get("error", ""), answer)
        status, answer = post(port, "/fetch", {"url": "https://example.test", "want": ["video"]})
        check("an unknown want is refused", status == 400, answer)
        status, answer = post(port, "/nope", {})
        check("an unknown route is refused", status == 404, answer)

        # A client that pools connections must not have its next request parsed
        # as leftover body bytes from this one.
        conn = http.client.HTTPConnection("127.0.0.1", port, timeout=30)
        conn.request("POST", "/nope", body=b'{"url":"x"}', headers={"Content-Type": "application/json"})
        first = conn.getresponse()
        first.read()
        conn.request("GET", "/health")
        second = conn.getresponse()
        payload = json.loads(second.read())
        check("a kept-alive connection survives an error answer", second.status == 200 and payload["ok"], second.status)
        conn.close()

        # The container going away is a 502 with the reason, not a dropped
        # socket: this is the state a restart leaves the shim in.
        upstream.shutdown()
        upstream.server_close()
        status, answer = post(port, "/fetch", {"url": page_url})
        check("a down container answers 502", status == 502, status)
        check("the reason is in the body", bool(answer.get("error")), answer)

        print("\nall checks passed")
    finally:
        shim.terminate()
        shim.wait(timeout=10)
        try:
            upstream.shutdown()
            upstream.server_close()
        except OSError:
            pass
        shutil.rmtree(scratch, ignore_errors=True)


if __name__ == "__main__":
    main()
