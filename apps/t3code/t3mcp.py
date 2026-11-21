"""Call a T3 Code server's MCP tools from a shell.

Every tool the server advertises is reachable through `call`; this script only
hardcodes the pairing handshake. Pairing is T3's own MCP OAuth flow without a
browser: register a client, pass a one-time pairing code to the approval
endpoint, exchange the returned code for a session token, then speak MCP over
the server's /mcp endpoint. Tokens last 30 days; pair again when one expires.

`pair --access` picks what the paired agent may do on that server: read-only,
approval-required (the default), auto-accept-edits, auto, or full-access.

Config lives in $XDG_CONFIG_HOME/t3mcp/config.json (the installed wrapper
always sets it to ~/.config) with one entry per paired server, so a tool call
can target this machine or another one by name. `servers` lists them with a *
on the default, `tools --server NAME` prints each tool's name, description and
input schema, `call TOOL ARGS` runs one, and `default NAME` chooses what a call
without --server uses. That argument falls back to $T3MCP_SERVER, then the
default, then the only paired server.

Arguments are a JSON object, or - for stdin. Most thread tools need a threadId,
and this client runs outside a thread, so list threads first and pass one.

Exit status is 0 on success, 1 when the CLI or the tool failed (a tool error
body still goes to stdout), and 2 for a usage mistake.
"""

import argparse
import asyncio
import base64
import datetime
import hashlib
import ipaddress
import json
import os
import secrets
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

from mcp import ClientSession
from mcp.client.streamable_http import streamablehttp_client

ACCESS_LEVELS = [
    "read-only",
    "approval-required",
    "auto-accept-edits",
    "auto",
    "full-access",
]
SERVER_KEYS = ("url", "token", "access", "expiresAt")
# Nothing listens on this address; the approval response carries the code.
REDIRECT_URI = "http://127.0.0.1/t3code-peer-link"
CALL_TIMEOUT = datetime.timedelta(minutes=10)
# A peer that is asleep must fail fast; tool calls get CALL_TIMEOUT instead.
CONNECT_TIMEOUT = 30


class Failure(Exception):
    """A problem worth printing as-is, with exit status 1."""


def config_path() -> Path:
    base = os.environ.get("XDG_CONFIG_HOME") or str(Path.home() / ".config")
    return Path(base) / "t3mcp" / "config.json"


def load_config() -> dict:
    path = config_path()
    if not path.exists():
        return {"servers": {}}
    try:
        config = json.loads(path.read_text())
    except ValueError as error:
        raise Failure(f"{path} is not valid JSON: {error}")
    if not isinstance(config, dict) or not isinstance(config.get("servers", {}), dict):
        raise Failure(f"{path} is not a t3mcp config")
    for name, entry in config.get("servers", {}).items():
        if not isinstance(entry, dict) or any(key not in entry for key in SERVER_KEYS):
            raise Failure(
                f"{path}: server {name} needs {', '.join(SERVER_KEYS)}; "
                "pair it again"
            )
    default = config.get("default")
    if default is not None and not isinstance(default, str):
        raise Failure(f"{path}: default must be a server name")
    if default is not None and default not in config.get("servers", {}):
        raise Failure(f"{path}: default {default} is not a paired server")
    return config


def save_config(config: dict) -> None:
    path = config_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(dir=path.parent, suffix=".json.tmp")
    try:
        with os.fdopen(descriptor, "w") as file:
            file.write(json.dumps(config, indent=2) + "\n")
        os.chmod(temporary, 0o600)
        os.replace(temporary, path)
    except BaseException:
        Path(temporary).unlink(missing_ok=True)
        raise


def is_tailnet_address(host: str) -> bool:
    try:
        address = ipaddress.ip_address(host)
    except ValueError:
        return False
    return any(
        address in network
        for network in (
            ipaddress.ip_network("100.64.0.0/10"),
            ipaddress.ip_network("fd7a:115c:a1e0::/48"),
        )
    )


def origin_of(url: str) -> str:
    parsed = urllib.parse.urlparse(url)
    if parsed.scheme not in ("http", "https") or not parsed.netloc:
        raise Failure(f"{url} is not an http or https address")
    host = parsed.hostname or ""
    local = host in ("localhost", "127.0.0.1", "::1")
    # The token travels in a header, so plain http is only for loopback and
    # Tailscale, where the network already encrypts.
    tailnet = host.endswith(".ts.net") or is_tailnet_address(host)
    if parsed.scheme == "http" and not (local or tailnet):
        raise Failure(
            f"{parsed.netloc} is plain http, which would send the token unencrypted; "
            "use its https or Tailscale address"
        )
    return f"{parsed.scheme}://{parsed.netloc}"


def post(origin: str, path: str, payload: dict, form: bool = False) -> dict:
    if form:
        body = urllib.parse.urlencode(payload).encode()
        content_type = "application/x-www-form-urlencoded"
    else:
        body = json.dumps(payload).encode()
        content_type = "application/json"
    request = urllib.request.Request(
        origin + path,
        data=body,
        headers={"content-type": content_type},
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            try:
                return json.load(response)
            except ValueError:
                raise Failure(f"{origin}{path} answered with something that is not JSON")
    except urllib.error.HTTPError as error:
        detail = error.read().decode(errors="replace")
        try:
            parsed = json.loads(detail)
            detail = (
                parsed.get("error_description")
                or parsed.get("message")
                or parsed.get("error")
                or detail
            )
        except ValueError:
            pass
        raise Failure(f"{origin}{path} refused ({error.code}): {detail}")
    except urllib.error.URLError as error:
        raise Failure(f"{origin} did not answer: {error.reason}")


def base64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def pair(origin: str, access: str, code: str, name: str) -> dict:
    """Return the session fields for a fresh pairing code."""
    registered = post(
        origin,
        "/oauth/mcp/register",
        # The name is what the server lists under Sharing & access, as
        # t3mcp:<name>.
        {"client_name": f"t3mcp:{name}", "redirect_uris": [REDIRECT_URI]},
    )
    verifier = secrets.token_urlsafe(32)
    state = secrets.token_urlsafe(16)
    resource = origin + "/mcp"
    approved = post(
        origin,
        "/oauth/mcp/decision",
        {
            "authorization": {
                "response_type": "code",
                "client_id": registered["client_id"],
                "redirect_uri": REDIRECT_URI,
                "code_challenge": base64url(hashlib.sha256(verifier.encode()).digest()),
                "code_challenge_method": "S256",
                "state": state,
                "resource": resource,
            },
            "decision": {"_tag": "pairing-code", "access": access, "code": code},
        },
    )
    query = urllib.parse.parse_qs(
        urllib.parse.urlparse(approved.get("redirectTo", "")).query
    )
    if query.get("state", [None])[0] != state:
        raise Failure(
            "the server did not approve that code: "
            + (query.get("error_description", ["no reason given"])[0])
        )
    if "code" not in query:
        raise Failure("the server approved the request without returning a code")
    token = post(
        origin,
        "/oauth/mcp/token",
        {
            "grant_type": "authorization_code",
            "code": query["code"][0],
            "redirect_uri": REDIRECT_URI,
            "client_id": registered["client_id"],
            "code_verifier": verifier,
            "resource": resource,
        },
        form=True,
    )
    expires_at = datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(
        seconds=token.get("expires_in", 0)
    )
    return {
        "url": origin,
        "token": token["access_token"],
        "access": access,
        "expiresAt": expires_at.isoformat(timespec="seconds"),
    }


def server_entry(config: dict, requested: str | None) -> tuple[str, dict]:
    servers = config.get("servers", {})
    if not servers:
        raise Failure("no servers are paired yet; run `t3mcp pair NAME --url URL` first")
    name = requested or os.environ.get("T3MCP_SERVER") or config.get("default")
    if not name:
        if len(servers) == 1:
            name = next(iter(servers))
        else:
            raise Failure(
                "several servers are paired ("
                + ", ".join(sorted(servers))
                + "); pick one with --server or set one with `t3mcp default NAME`"
            )
    if name not in servers:
        raise Failure(
            f"{name} is not paired; known servers: " + ", ".join(sorted(servers))
        )
    return name, servers[name]


def expired_message(entry: dict) -> str:
    return (
        f"the session for {entry['name']} was refused; it expired or was revoked. "
        f"Run `t3mcp pair {entry['name']} --url {entry['url']}` with a fresh code."
    )


def describe_error(error: BaseException) -> str:
    """Flatten the exception groups anyio raises around transport failures."""
    if isinstance(error, BaseExceptionGroup):
        return "; ".join(describe_error(child) for child in error.exceptions)
    status = getattr(getattr(error, "response", None), "status_code", None)
    text = str(error) or type(error).__name__
    return f"{status} {text}" if status is not None else text


def run_mcp(entry: dict, action):
    async def main():
        try:
            async with streamablehttp_client(
                entry["url"] + "/mcp",
                headers={"Authorization": "Bearer " + entry["token"]},
                timeout=CONNECT_TIMEOUT,
                sse_read_timeout=CALL_TIMEOUT.total_seconds(),
            ) as (read, write, _):
                async with ClientSession(read, write) as session:
                    await asyncio.wait_for(session.initialize(), CONNECT_TIMEOUT)
                    return await action(session)
        except Exception as error:  # noqa: BLE001 - the SDK wraps transport errors
            text = describe_error(error)
            if "401" in text or "unauthorized" in text.lower():
                raise Failure(expired_message(entry))
            raise Failure(f"{entry['name']} MCP call failed: {text}")

    return asyncio.run(main())


async def all_tools(session) -> list:
    tools = []
    cursor = None
    while True:
        result = await session.list_tools(cursor=cursor)
        tools.extend(result.tools)
        cursor = result.nextCursor
        if not cursor:
            return tools


def render(result) -> str:
    parts = []
    for item in result.content:
        if item.type == "text":
            parts.append(item.text)
        elif item.type == "image":
            size = len(item.data) * 3 // 4
            parts.append(f"[{item.mimeType} image, about {size} bytes, omitted]")
        else:
            parts.append(f"[{item.type} content omitted]")
    if result.structuredContent is not None and not parts:
        parts.append(json.dumps(result.structuredContent, indent=2, ensure_ascii=False))
    return "\n".join(parts)


def read_arguments(raw: str | None) -> dict:
    if raw is None:
        return {}
    if raw == "-":
        raw = sys.stdin.read()
    try:
        arguments = json.loads(raw)
    except ValueError as error:
        raise Failure(f"arguments are not valid JSON: {error}")
    if not isinstance(arguments, dict):
        raise Failure("arguments must be a JSON object")
    return arguments


def command_pair(args) -> int:
    origin = origin_of(args.url)
    code = args.code
    if code == "-":
        code = sys.stdin.read().strip()
    elif code is None:
        try:
            code = input("pairing code: ").strip()
        except EOFError:
            raise Failure("no pairing code; pass --code or run it on a terminal")
    if not code:
        raise Failure("a pairing code is required")
    entry = pair(origin, args.access, code, args.name)
    # Prove the session works before it is the thing later calls rely on.
    entry["name"] = args.name
    tools = run_mcp(entry, all_tools)
    config = load_config()
    config.setdefault("servers", {})[args.name] = {
        key: entry[key] for key in SERVER_KEYS
    }
    config.setdefault("default", args.name)
    save_config(config)
    print(
        f"paired {args.name} at {origin} ({entry['access']}), "
        f"{len(tools)} tools, session ends {entry['expiresAt']}"
    )
    return 0


def command_servers(args) -> int:
    config = load_config()
    servers = config.get("servers", {})
    if not servers:
        print("no servers paired")
        return 0
    default = config.get("default")
    for name, entry in sorted(servers.items()):
        marker = "*" if name == default else " "
        print(
            f"{marker} {name}\t{entry['url']}\t{entry['access']}\tends {entry['expiresAt']}"
        )
    return 0


def command_default(args) -> int:
    config = load_config()
    servers = config.get("servers", {})
    if args.name not in servers:
        raise Failure(
            f"{args.name} is not paired; known servers: " + ", ".join(sorted(servers))
        )
    config["default"] = args.name
    save_config(config)
    print(f"{args.name} is the default server")
    return 0


def command_unpair(args) -> int:
    config = load_config()
    servers = config.setdefault("servers", {})
    entry = servers.pop(args.name, None)
    if entry is None:
        raise Failure(f"{args.name} is not paired")
    # Deliberately no new default: a later call without --server must not act
    # on a machine the user did not choose. One server left still resolves on
    # its own; several ask for --server.
    if config.get("default") == args.name:
        config.pop("default")
    save_config(config)
    print(f"unpaired {args.name} locally")
    print(
        f"this does not revoke the server session, whose recorded expiry is "
        f"{entry['expiresAt']}. Revoke it there instead: "
        "`t3 auth session list --json`, then `t3 auth session revoke ID`"
    )
    return 0


def command_tools(args) -> int:
    name, entry = server_entry(load_config(), args.server)
    entry["name"] = name
    tools = run_mcp(entry, all_tools)
    print(
        json.dumps(
            [
                {
                    "name": tool.name,
                    "description": tool.description,
                    "inputSchema": tool.inputSchema,
                }
                for tool in tools
            ],
            indent=2,
            ensure_ascii=False,
        )
    )
    return 0


def command_call(args) -> int:
    name, entry = server_entry(load_config(), args.server)
    entry["name"] = name
    arguments = read_arguments(args.arguments)
    result = run_mcp(
        entry,
        lambda session: session.call_tool(
            args.tool, arguments, read_timeout_seconds=CALL_TIMEOUT
        ),
    )
    print(render(result))
    return 1 if result.isError else 0


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        prog="t3mcp",
        description="Call a paired T3 Code server's MCP tools.",
        epilog="Exit status is 0 on success, 1 when the CLI or the tool failed, "
        "and 2 for a usage mistake.",
    )
    commands = parser.add_subparsers(dest="command", required=True)

    pair_parser = commands.add_parser("pair", help="pair a server with a one-time code")
    pair_parser.add_argument("name", help="name to store the server under")
    pair_parser.add_argument("--url", required=True, help="server address")
    pair_parser.add_argument(
        "--code", help="pairing code, or - for stdin; prompted when omitted"
    )
    pair_parser.add_argument(
        "--access", choices=ACCESS_LEVELS, default="approval-required"
    )
    pair_parser.set_defaults(handler=command_pair)

    servers_parser = commands.add_parser("servers", help="list paired servers")
    servers_parser.set_defaults(handler=command_servers)

    default_parser = commands.add_parser(
        "default", help="choose the server used when --server is omitted"
    )
    default_parser.add_argument("name")
    default_parser.set_defaults(handler=command_default)

    unpair_parser = commands.add_parser("unpair", help="forget a paired server")
    unpair_parser.add_argument("name")
    unpair_parser.set_defaults(handler=command_unpair)

    tools_parser = commands.add_parser("tools", help="list a server's tools as JSON")
    tools_parser.add_argument(
        "--server", help="paired server name; defaults to $T3MCP_SERVER or the default"
    )
    tools_parser.set_defaults(handler=command_tools)

    call_parser = commands.add_parser("call", help="call one tool")
    call_parser.add_argument("tool")
    call_parser.add_argument(
        "arguments", nargs="?", help="JSON object, or - for stdin"
    )
    call_parser.add_argument(
        "--server", help="paired server name; defaults to $T3MCP_SERVER or the default"
    )
    call_parser.set_defaults(handler=command_call)

    args = parser.parse_args(argv)
    try:
        return args.handler(args)
    except Failure as error:
        print(f"t3mcp: {error}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        return 130


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
