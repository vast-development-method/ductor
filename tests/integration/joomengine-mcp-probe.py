#!/usr/bin/env python3
"""Exercise the installed Joomla MCP HTTP boundary using a private client file.

No credentials are accepted in arguments, logged, or written to reports. This
probe is for the dedicated readonly identity enrolled by Ductor, not an admin.
"""
from __future__ import annotations

import argparse
import json
import os
import ssl
import stat
import sys
import urllib.error
import urllib.parse
import urllib.request
import uuid


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise RuntimeError("MCP endpoint redirected; configure its canonical URL")


def private_json(path: str) -> dict:
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        metadata = os.fstat(fd)
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_mode & 0o077 or metadata.st_nlink != 1 or metadata.st_uid != os.getuid():
            raise RuntimeError("Client file must be private and regular")
        if metadata.st_size > 65536:
            raise RuntimeError("Client file is too large")
        with os.fdopen(fd, "r", encoding="utf-8") as stream:
            fd = -1
            result = json.load(stream)
        if not isinstance(result, dict):
            raise RuntimeError("Client file must contain an object")
        return result
    finally:
        if fd >= 0:
            os.close(fd)


class Client:
    def __init__(self, config: dict, ca_file: str | None):
        self.url = config["url"]
        parts = urllib.parse.urlsplit(self.url)
        if parts.scheme != "https" or not parts.hostname or parts.username or parts.password or parts.query or parts.fragment:
            raise RuntimeError("MCP requires a canonical HTTPS endpoint")
        self.token = config["token"]
        if not isinstance(self.token, str) or not self.token or any(ord(c) < 33 for c in self.token):
            raise RuntimeError("Invalid private token")
        context = ssl.create_default_context(cafile=ca_file)
        self.http = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect(), urllib.request.HTTPSHandler(context=context))
        self.session = None
        self.protocol = "2025-06-18"
        self.counter = 0

    def request(self, method: str, params: dict, *, notification: bool = False) -> dict:
        self.counter += 1
        body = {"jsonrpc": "2.0", "method": method, "params": params}
        if not notification:
            body["id"] = self.counter
        headers = {"Content-Type": "application/json", "Accept": "application/json, text/event-stream",
                   "X-Joomla-Token": self.token, "MCP-Protocol-Version": self.protocol}
        if self.session:
            headers["Mcp-Session-Id"] = self.session
        req = urllib.request.Request(self.url, data=json.dumps(body).encode(), headers=headers, method="POST")
        try:
            with self.http.open(req, timeout=60) as response:
                self.session = response.headers.get("Mcp-Session-Id", self.session)
                raw = response.read(8 * 1024 * 1024 + 1)
                if len(raw) > 8 * 1024 * 1024:
                    raise RuntimeError("MCP response exceeded its size bound")
                if notification and not raw:
                    return {}
                text = raw.decode("utf-8")
                if "text/event-stream" in response.headers.get("Content-Type", ""):
                    messages = []
                    for event in text.replace("\r\n", "\n").split("\n\n"):
                        data = "\n".join(line[5:].lstrip(" ") for line in event.splitlines() if line.startswith("data:"))
                        if data:
                            messages.append(json.loads(data))
                    matches = [message for message in messages if message.get("id") == body.get("id")]
                    if not matches:
                        raise RuntimeError("MCP SSE response has no matching message")
                    return matches[-1]
                result = json.loads(text)
                if not isinstance(result, dict) or (not notification and result.get("id") != body["id"]):
                    raise RuntimeError("MCP response does not match its request")
                return result
        except urllib.error.HTTPError as error:
            # Error bodies may reflect credentials or source content; never log them.
            raise RuntimeError(f"MCP HTTP request failed with status {error.code}") from None

    def call(self, name: str, arguments: dict, *, denied: bool = False) -> dict:
        result = self.request("tools/call", {"name": name, "arguments": arguments})
        failure = bool(result.get("error") or result.get("result", {}).get("isError"))
        if denied:
            if not failure:
                raise RuntimeError("Readonly identity unexpectedly accepted a write request")
            errors = []
            for content in result.get("result", {}).get("content", []):
                if content.get("type") == "text":
                    try:
                        errors.append(json.loads(content["text"]).get("error", {}).get("code"))
                    except (ValueError, AttributeError):
                        pass
            if "DEFINITION_UNAVAILABLE" not in errors:
                raise RuntimeError("Write probe failed without proving the native permission denial")
        elif failure:
            raise RuntimeError(f"Allowed MCP operation failed: {name}")
        return result.get("result", {})


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("client_file")
    parser.add_argument("ca_file_positional", nargs="?")
    parser.add_argument("--ca-file")
    options = parser.parse_args()
    config = private_json(options.client_file)
    if config.get("write_enabled") is not False:
        raise RuntimeError("This integration probe requires the enrolled readonly identity")
    client = Client(config, options.ca_file or options.ca_file_positional)
    initialize = client.request("initialize", {"protocolVersion": client.protocol, "capabilities": {},
                                               "clientInfo": {"name": "ductor-integration", "version": "1"}})
    if "error" in initialize:
        raise RuntimeError("MCP initialization failed")
    client.protocol = initialize["result"]["protocolVersion"]
    client.request("notifications/initialized", {}, notification=True)
    names = set()
    cursor = None
    seen = set()
    for _ in range(100):
        listing = client.request("tools/list", {"cursor": cursor} if cursor else {})
        if "error" in listing:
            raise RuntimeError("MCP tool discovery failed")
        names.update(tool["name"] for tool in listing["result"]["tools"])
        cursor = listing["result"].get("nextCursor")
        if not cursor:
            break
        if cursor in seen:
            raise RuntimeError("MCP tool discovery repeated its cursor")
        seen.add(cursor)
    else:
        raise RuntimeError("MCP tool discovery exceeded its page bound")
    required = {"joomla_sites_list", "joomla_capabilities", "joomla_content_articles_list", "joomla_action_write_plan"}
    if required - names:
        raise RuntimeError("Expected readonly Joomla tools are not discoverable")
    client.call("joomla_sites_list", {})
    client.call("joomla_capabilities", {})
    client.call("joomla_content_articles_list", {"offset": 0, "limit": 1})
    # No mutation is applied. The readonly authority must reject planning an
    # effectful action even if a client bypasses the advertised tool list.
    client.call("joomla_action_write_plan", {"action": "content.articles.create", "idempotencyKey": str(uuid.uuid4()),
                                            "dryRun": True, "input": {"data": {"title": "Ductor permission probe"}}}, denied=True)
    print("Joomla MCP: authenticated initialization, paginated discovery, permitted reads and denied write PASS")


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        # Only our bounded messages may reach the report; urllib errors can
        # contain URLs, and server bodies are never copied into exceptions.
        print(f"Joomla MCP probe failed: {error}" if isinstance(error, RuntimeError)
              else "Joomla MCP probe failed: invalid response or transport failure", file=sys.stderr)
        raise SystemExit(1)
