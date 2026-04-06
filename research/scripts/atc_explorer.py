#!/usr/bin/env python3
"""Interactive ATC protocol explorer.

Connects to com.apple.atc and lets you send/receive messages interactively.
Logs all traffic to /tmp/atc_capture.json for analysis.

Usage:
    source .venv/bin/activate
    python scripts/atc_explorer.py
"""

import asyncio
import json
import plistlib
import struct
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent / "src"))

from mediaporter.device import get_device, _run


LOG_FILE = Path("/tmp/atc_capture.json")
messages = []


def encode(msg: dict) -> bytes:
    data = plistlib.dumps(msg, fmt=plistlib.FMT_BINARY)
    return struct.pack("<I", len(data)) + data


async def read_msg(reader, timeout=15.0):
    lb = await asyncio.wait_for(reader.readexactly(4), timeout=timeout)
    length = struct.unpack("<I", lb)[0]
    data = await asyncio.wait_for(reader.readexactly(length), timeout=timeout)
    msg = plistlib.loads(data)
    return msg


def log(direction: str, msg: dict):
    entry = {
        "time": time.time(),
        "direction": direction,
        "command": msg.get("Command", "?"),
        "message": json.loads(json.dumps(msg, default=str)),
    }
    messages.append(entry)

    cmd = msg.get("Command", "?")
    params_str = json.dumps(msg.get("Params", {}), default=str, indent=2)
    print(f"\n{'<<<' if direction == 'recv' else '>>>'} [{msg.get('Type', '?')}] {cmd} (Id={msg.get('Id', '?')}, Session={msg.get('Session', '?')})")
    if len(params_str) < 500:
        print(f"    Params: {params_str}")
    else:
        print(f"    Params: {params_str[:500]}...")


def save_log():
    with open(LOG_FILE, "w") as f:
        json.dump(messages, f, indent=2, default=str)
    print(f"\nLog saved to {LOG_FILE}")


async def explore():
    from pymobiledevice3.services.lockdown_service import LockdownService

    lockdown = get_device()
    print("Connected to device")

    svc = LockdownService(lockdown=lockdown, service_name="com.apple.atc")
    async with svc:
        conn = svc.service
        print("Connected to com.apple.atc\n")
        mid = 100

        # Auto handshake
        greeting = await read_msg(conn.reader)
        log("recv", greeting)

        # Respond with capabilities
        caps = {
            "Command": "Capabilities",
            "Params": {
                "GrappaSupportInfo": {
                    "version": 1,
                    "deviceType": 1,
                    "protocolVersion": 1,
                },
            },
            "Type": 1,
            "Session": 0,
            "Id": greeting["Id"],
        }
        conn.writer.write(encode(caps))
        await conn.writer.drain()
        log("send", caps)

        # Read all auto messages
        while True:
            try:
                msg = await read_msg(conn.reader, timeout=3.0)
                log("recv", msg)
            except asyncio.TimeoutError:
                break

        # Interactive mode
        print("\n" + "="*60)
        print("INTERACTIVE MODE")
        print("Commands: send <json>, quit, read, hostinfo, sync, beginsync")
        print("="*60)

        while True:
            try:
                cmd = input("\n> ").strip()
            except (EOFError, KeyboardInterrupt):
                break

            if cmd == "quit":
                break
            elif cmd == "read":
                try:
                    msg = await read_msg(conn.reader, timeout=5.0)
                    log("recv", msg)
                except asyncio.TimeoutError:
                    print("(no message)")
            elif cmd == "hostinfo":
                mid += 1
                msg = {
                    "Command": "HostInfo",
                    "Params": {
                        "HostName": "mediaporter",
                        "HostID": "mediaporter-0001",
                        "Version": "10.5.0.115",
                    },
                    "Type": 0, "Session": 0, "Id": mid,
                }
                conn.writer.write(encode(msg))
                await conn.writer.drain()
                log("send", msg)
                try:
                    resp = await read_msg(conn.reader, timeout=5.0)
                    log("recv", resp)
                except asyncio.TimeoutError:
                    print("(no response)")
            elif cmd == "sync":
                mid += 1
                msg = {
                    "Command": "RequestingSync",
                    "Params": {"DataClasses": ["com.apple.media"]},
                    "Type": 0, "Session": 0, "Id": mid,
                }
                conn.writer.write(encode(msg))
                await conn.writer.drain()
                log("send", msg)
                try:
                    resp = await read_msg(conn.reader, timeout=5.0)
                    log("recv", resp)
                except asyncio.TimeoutError:
                    print("(no response)")
            elif cmd == "beginsync":
                mid += 1
                msg = {
                    "Command": "BeginSync",
                    "Params": {"DataClasses": ["com.apple.media"], "SyncType": 0},
                    "Type": 0, "Session": 1, "Id": mid,
                }
                conn.writer.write(encode(msg))
                await conn.writer.drain()
                log("send", msg)
                try:
                    resp = await read_msg(conn.reader, timeout=5.0)
                    log("recv", resp)
                except asyncio.TimeoutError:
                    print("(no response)")
            elif cmd.startswith("send "):
                try:
                    mid += 1
                    msg = json.loads(cmd[5:])
                    if "Id" not in msg:
                        msg["Id"] = mid
                    conn.writer.write(encode(msg))
                    await conn.writer.drain()
                    log("send", msg)
                    try:
                        resp = await read_msg(conn.reader, timeout=5.0)
                        log("recv", resp)
                    except asyncio.TimeoutError:
                        print("(no response)")
                except json.JSONDecodeError as e:
                    print(f"Invalid JSON: {e}")
            else:
                print("Unknown command. Try: send, quit, read, hostinfo, sync, beginsync")

    save_log()


if __name__ == "__main__":
    _run(explore())
