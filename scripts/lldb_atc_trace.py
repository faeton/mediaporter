#!/usr/bin/env python3
"""
LLDB helpers for tracing ATC-related calls inside Finder or AMPDevicesAgent.

Usage from lldb:

    command script import /abs/path/scripts/lldb_atc_trace.py
    atc_trace_log /tmp/mediaporter-atc.log
    atc_trace_setup
    continue

The breakpoint callbacks auto-continue after logging.
"""

from __future__ import annotations

import datetime as _dt
import os
from typing import Iterable

import lldb


_LOG_PATH = "/tmp/mediaporter-atc-trace.log"

_SYMBOLS = [
    "AMDeviceSecureStartService",
    "AMDServiceConnectionSend",
    "AMDServiceConnectionReceive",
    "AMDServiceConnectionSendMessage",
    "AMDServiceConnectionReceiveMessage",
    "ATHostConnectionSendHostInfo",
    "ATHostConnectionSendSyncRequest",
    "ATHostConnectionSendFileBegin",
    "ATHostConnectionSendAssetCompleted",
    "ATHostConnectionSendAssetCompletedWithMetadata",
    "ATHostConnectionSendMetadataSyncFinished",
    "ATCFMessageCreate",
    "ATHostConnectionReadMessage",
    "ATHostConnectionSendMessage",
    "ATHostConnectionSendPowerAssertion",
    "ATHostConnectionSendPing",
]

_OBJ_SUMMARY_ARGS = {
    "AMDeviceSecureStartService": [1],
    "AMDServiceConnectionSendMessage": [1],
    "AMDServiceConnectionReceiveMessage": [1],
    "ATHostConnectionSendHostInfo": [1],
    "ATHostConnectionSendSyncRequest": [1, 2, 3],
    "ATHostConnectionSendFileBegin": [1],
    "ATHostConnectionSendAssetCompleted": [1, 2, 3],
    "ATHostConnectionSendAssetCompletedWithMetadata": [1, 2, 3, 4],
    "ATHostConnectionSendMetadataSyncFinished": [1, 2],
    "ATCFMessageCreate": [1, 2],
    "ATHostConnectionSendMessage": [1],
    "ATHostConnectionSendPowerAssertion": [1],
}


def __lldb_init_module(debugger: lldb.SBDebugger, internal_dict) -> None:
    debugger.HandleCommand(
        f"command script add -f {__name__}.atc_trace_log atc_trace_log"
    )
    debugger.HandleCommand(
        f"command script add -f {__name__}.atc_trace_setup atc_trace_setup"
    )
    debugger.HandleCommand(
        f"command script add -f {__name__}.atc_trace_status atc_trace_status"
    )
    print(
        "Loaded mediaporter ATC trace helpers. "
        "Commands: atc_trace_log, atc_trace_setup, atc_trace_status"
    )


def atc_trace_log(debugger, command, result, internal_dict) -> None:
    global _LOG_PATH

    path = command.strip()
    if not path:
        result.SetError("usage: atc_trace_log /tmp/mediaporter-atc.log")
        return

    _LOG_PATH = os.path.abspath(os.path.expanduser(path))
    _write_log(
        f"# log path set to {_LOG_PATH}\n",
        append=False,
    )
    result.PutCString(f"ATC trace log path: {_LOG_PATH}")


def atc_trace_setup(debugger, command, result, internal_dict) -> None:
    target = debugger.GetSelectedTarget()
    if not target or not target.IsValid():
        result.SetError("no target selected; attach or create a target first")
        return

    lines = []
    for symbol in _SYMBOLS:
        bp = target.BreakpointCreateByName(symbol)
        bp.SetScriptCallbackFunction(f"{__name__}.breakpoint_callback")
        lines.append(
            f"{symbol}: breakpoint {bp.GetID()} ({bp.GetNumLocations()} locations)"
        )

    _write_log(
        "# mediaporter atc trace session\n"
        f"# pid={target.GetProcess().GetProcessID()}\n"
        f"# target={target.GetExecutable().GetFilename()}\n"
        f"# triple={target.GetTriple()}\n"
        f"# started={_timestamp()}\n",
        append=False,
    )
    for line in lines:
        result.PutCString(line)


def atc_trace_status(debugger, command, result, internal_dict) -> None:
    target = debugger.GetSelectedTarget()
    if not target or not target.IsValid():
        result.SetError("no target selected")
        return

    result.PutCString(f"log: {_LOG_PATH}")
    result.PutCString(f"triple: {target.GetTriple()}")
    for bp in target.breakpoint_iter():
        result.PutCString(
            f"bp {bp.GetID()}: {bp.GetNumLocations()} locations, enabled={bp.IsEnabled()}"
        )


def breakpoint_callback(frame, bp_loc, internal_dict) -> bool:
    symbol = frame.GetFunctionName() or frame.GetSymbol().GetName() or "<unknown>"
    regs = _arg_register_names(frame)
    log_lines = [
        "",
        f"[{_timestamp()}] {symbol}",
        f"pc={frame.GetPCAddress()} thread={frame.GetThread().GetThreadID()}",
    ]

    for idx, reg_name in enumerate(regs):
        raw = _register_value(frame, reg_name)
        if raw is None:
            continue
        log_lines.append(f"arg{idx} {reg_name}={raw}")

    for idx in _OBJ_SUMMARY_ARGS.get(symbol, []):
        if idx >= len(regs):
            continue
        summary = _object_summary(frame, regs[idx])
        if summary:
            log_lines.append(f"arg{idx}_summary={summary}")

    backtrace = _short_backtrace(frame, limit=6)
    if backtrace:
        log_lines.append("backtrace:")
        log_lines.extend(backtrace)

    _write_log("\n".join(log_lines) + "\n")
    return False


def _timestamp() -> str:
    return _dt.datetime.now().isoformat(timespec="seconds")


def _write_log(text: str, append: bool = True) -> None:
    mode = "a" if append else "w"
    os.makedirs(os.path.dirname(_LOG_PATH), exist_ok=True)
    with open(_LOG_PATH, mode, encoding="utf-8") as fh:
        fh.write(text)


def _arg_register_names(frame) -> list[str]:
    triple = frame.GetThread().GetProcess().GetTarget().GetTriple()
    if "x86_64" in triple:
        return ["rdi", "rsi", "rdx", "rcx", "r8", "r9"]
    return ["x0", "x1", "x2", "x3", "x4", "x5", "x6", "x7"]


def _register_value(frame, reg_name: str) -> str | None:
    reg = frame.FindRegister(reg_name)
    if not reg or not reg.IsValid():
        return None
    return reg.GetValue()


def _object_summary(frame, reg_name: str) -> str | None:
    options = lldb.SBExpressionOptions()
    options.SetIgnoreBreakpoints(True)
    options.SetTimeoutInMicroSeconds(500_000)
    value = frame.EvaluateExpression(f"(id)${reg_name}", options)
    if not value or not value.IsValid():
        return None

    desc = value.GetObjectDescription()
    if desc:
        return _clean(desc)

    summary = value.GetSummary()
    if summary:
        return _clean(summary)

    raw = value.GetValue()
    if raw:
        return _clean(raw)
    return None


def _short_backtrace(frame, limit: int = 6) -> list[str]:
    thread = frame.GetThread()
    lines = []
    for idx, bt_frame in enumerate(_iter_frames(thread, limit)):
        name = bt_frame.GetFunctionName() or bt_frame.GetSymbol().GetName() or "??"
        lines.append(f"  #{idx} {name}")
    return lines


def _iter_frames(thread, limit: int) -> Iterable[lldb.SBFrame]:
    count = min(thread.GetNumFrames(), limit)
    for idx in range(count):
        yield thread.GetFrameAtIndex(idx)


def _clean(text: str) -> str:
    return " ".join(text.strip().split())
