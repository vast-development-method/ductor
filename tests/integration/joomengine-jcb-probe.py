#!/usr/bin/env python3
"""Compile the installer-supplied Demo J6 through a disposable scoped MCP user.

This integration fixture explicitly approves one JCB compile operation, without
installing its output. Never point it at an operational Joomla deployment.
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import json
from pathlib import Path
import re
import runpy
import sys
import tempfile
import time
import uuid
import xml.etree.ElementTree as ET
import zipfile

_shared = runpy.run_path(str(Path(__file__).with_name("joomengine-mcp-probe.py")))
Client = _shared["Client"]
private_json = _shared["private_json"]
# This complete definition ships with the pinned JCB installer and is exercised
# by mcp_component/tests/golden-image/jcb-acceptance.php upstream.
DEMO_COMPONENT = "1c20aec5-bf1a-44e7-9deb-d1c920ca591d"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise RuntimeError(message)


def connect(config: dict, ca_file: str) -> object:
    client = Client(config, ca_file, timeout=120)
    result = client.request("initialize", {
        "protocolVersion": client.protocol, "capabilities": {},
        "clientInfo": {"name": "ductor-jcb-integration", "version": "1"},
    })
    require("error" not in result, "JCB client initialization failed")
    client.protocol = result["result"]["protocolVersion"]
    client.request("notifications/initialized", {}, notification=True)
    return client


def tool(client: object, name: str, arguments: dict) -> dict:
    result = client.call(name, arguments)
    data = result.get("structuredContent")
    if data is None:
        for content in result.get("content", []):
            if content.get("type") == "text":
                data = json.loads(content["text"])
                break
    require(isinstance(data, dict), "Native JCB tool omitted its structured result")
    return data


def verified_archive(client: object, job_id: str, descriptor: dict) -> None:
    artifact_id, size, expected = descriptor["artifactId"], descriptor["size"], descriptor["sha256"]
    require(type(size) is int and 0 < size <= 128 * 1024 * 1024, "Compiled archive exceeds its size bound")
    require(isinstance(expected, str) and re.fullmatch(r"[a-f0-9]{64}", expected) is not None,
            "Compiled archive omitted its SHA-256")
    digest, offset = hashlib.sha256(), 0
    # TemporaryFile creates a private file and unlinks it without publishing the
    # archive to the web root or retaining it in CI reports.
    with tempfile.TemporaryFile() as output:
        while offset < size:
            chunk = tool(client, "joomla_job_artifact_read", {
                "artifactId": artifact_id, "offset": offset, "length": 262144,
            })
            require(chunk.get("artifactId") == artifact_id and chunk.get("jobId") == job_id
                    and chunk.get("size") == size and chunk.get("sha256") == expected
                    and chunk.get("encoding") == "base64" and chunk.get("offset") == offset,
                    "Artifact ownership or metadata changed during download")
            block = base64.b64decode(chunk["data"], validate=True)
            require(0 < len(block) <= 262144 and len(block) == chunk.get("length")
                    and offset + len(block) <= size, "Invalid artifact byte range")
            output.write(block)
            digest.update(block)
            offset += len(block)
            require(chunk.get("eof") is (offset == size), "Artifact EOF does not match its declared size")
        require(offset == size and digest.hexdigest() == expected, "Compiled archive SHA-256 mismatch")
        output.seek(0)
        with zipfile.ZipFile(output) as archive:
            entries = archive.infolist()
            require(0 < len(entries) <= 20000 and sum(entry.file_size for entry in entries) <= 256 * 1024 * 1024,
                    "Compiled ZIP exceeds its inspection bound")
            require(archive.testzip() is None, "Compiled ZIP failed its integrity check")
            manifest_found = False
            for entry in entries:
                if entry.filename.endswith(".xml") and entry.file_size <= 2 * 1024 * 1024:
                    xml = archive.read(entry)
                    if b"<!DOCTYPE" in xml or b"<!ENTITY" in xml:
                        continue
                    try:
                        manifest_found = manifest_found or ET.fromstring(xml).tag == "extension"
                    except ET.ParseError:
                        continue
            require(manifest_found, "Compiled ZIP contains no Joomla extension manifest")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("client_file")
    parser.add_argument("ca_file")
    parser.add_argument("--disposable-fixture", action="store_true", required=True,
                        help="Explicitly approve the fixed Demo J6 compile in a disposable test deployment")
    options = parser.parse_args()
    config = private_json(options.client_file)
    require(config.get("write_enabled") is True, "The JCB fixture needs its separate scoped compiler identity")
    client = connect(config, options.ca_file)
    permission = tool(client, "joomla_permission_request", {
        "toolsets": ["jcb.execute"], "duration": "30-minutes",
        "reason": "Explicit disposable Ductor integration: compile the installed Demo J6 without installation",
    })
    # The CI invocation above authorizes this fixed disposable operation. The
    # server still enforces its ordinary exact-challenge approval protocol.
    tool(client, "joomla_permission_approve", {
        "requestId": permission["requestId"], "acknowledgement": permission["acknowledgement"],
    })
    plan = tool(client, "joomla_action_write_plan", {
        "action": "jcb.compile.component", "transport": "api", "idempotencyKey": str(uuid.uuid4()),
        "input": {"options": {"component": DEMO_COMPONENT, "joomla-version": "6",
                               "add-build-date": "2", "build-date": "2026-01-01"}},
    })
    require(isinstance(plan.get("confirmationToken"), str), "JCB plan omitted its confirmation token")
    applied = tool(client, "joomla_write_apply", {"confirmationToken": plan["confirmationToken"]})
    job_id = applied.get("job", {}).get("jobId")
    require(isinstance(job_id, str), "Confirmed JCB compile did not create a durable job")
    replay = tool(client, "joomla_write_apply", {"confirmationToken": plan["confirmationToken"]})
    require(replay.get("idempotentReplay") is True and replay.get("executionId") == applied.get("executionId"),
            "Replaying the confirmation did not preserve the original execution")
    # Observe from a newly authenticated protocol session: job lifetime must not
    # depend on the requesting session or any Ductor monitor staying connected.
    client = connect(config, options.ca_file)
    deadline, report_at = time.monotonic() + 900, 0
    while True:
        state = tool(client, "joomla_job_status", {"jobId": job_id})
        status = state.get("status")
        if status not in ("queued", "running", "cancelling"):
            break
        now = time.monotonic()
        require(now < deadline, "The native JCB compile exceeded its 15-minute deadline")
        if now >= report_at:
            print("Waiting for the approved native JCB compile to finish.", flush=True)
            report_at = now + 30
        time.sleep(2)
    require(status == "completed" and state.get("result", {}).get("verification", {}).get("status") == "verified"
            and state.get("result", {}).get("mutation", {}).get("exitCode") == 0,
            "The native JCB compile did not finish with independently verified success")
    artifacts = tool(client, "joomla_job_artifacts", {"jobId": job_id}).get("artifacts")
    require(isinstance(artifacts, list) and 0 < len(artifacts) <= 16, "Native compilation retained no bounded artifact list")
    for descriptor in artifacts:
        verified_archive(client, job_id, descriptor)
    print(f"JCB compile PASS: scoped identity, explicit approval, durable job, replay safety and {len(artifacts)} hash-verified Joomla archives")


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        # Only locally authored messages reach CI; native error bodies can
        # contain source content, paths or credentials.
        print(f"JCB fixture failed: {error}" if isinstance(error, RuntimeError)
              else "JCB fixture failed: invalid native response or transport failure", file=sys.stderr)
        raise SystemExit(1)
