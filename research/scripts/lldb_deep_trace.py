"""
Deep LLDB trace for third-party tool — captures actual wire data, not just function calls.

Captures:
1. AMDServiceConnectionSend — raw bytes sent on ATC wire (includes plist messages)
2. AMDServiceConnectionReceive — raw bytes received
3. ATCFMessageCreate — message name + full params dump
4. ATHostConnectionSendFileBegin — asset details
5. ATHostConnectionSendAssetCompleted — asset path
6. ATHostConnectionSendMetadataSyncFinished — sync types + anchors
7. AFC file operations (if any)

Usage:
  lldb -n "third-party sync tool" -o "command script import scripts/lldb_reference_deep_trace.py"

  Or attach to PID:
  lldb -p <PID> -o "command script import scripts/lldb_reference_deep_trace.py"
"""
import lldb
import os
import time
import datetime

LOG_DIR = os.path.expanduser("/Users/faeton/Sites/mediaporter/traces")
os.makedirs(LOG_DIR, exist_ok=True)
TIMESTAMP = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
LOG_FILE = os.path.join(LOG_DIR, f"reference-deep-{TIMESTAMP}.log")

_log_handle = None
_hit_count = 0

def log(msg):
    global _log_handle, _hit_count
    if not _log_handle:
        _log_handle = open(LOG_FILE, "w")
    _hit_count += 1
    line = f"[{_hit_count:04d}] {msg}"
    _log_handle.write(line + "\n")
    _log_handle.flush()
    print(line)

def get_summary(frame, expr):
    """Evaluate an expression and return its string summary."""
    try:
        val = frame.EvaluateExpression(expr)
        if val.IsValid() and val.GetError().Success():
            return val.GetSummary() or val.GetValue() or str(val)
    except:
        pass
    return None

def get_unsigned(frame, expr):
    try:
        val = frame.EvaluateExpression(expr)
        if val.IsValid() and val.GetError().Success():
            return val.GetValueAsUnsigned()
    except:
        pass
    return 0

def hex_dump(process, addr, length, max_bytes=512):
    """Read memory and return hex dump."""
    if not addr or length <= 0:
        return "(empty)"
    length = min(length, max_bytes)
    err = lldb.SBError()
    data = process.ReadMemory(addr, length, err)
    if err.Fail():
        return f"(read error: {err})"
    hex_str = data.hex()
    # Format as readable hex
    chunks = [hex_str[i:i+2] for i in range(0, len(hex_str), 2)]
    lines = []
    for i in range(0, len(chunks), 32):
        hex_part = ' '.join(chunks[i:i+32])
        ascii_part = ''.join(chr(b) if 32 <= b < 127 else '.' for b in data[i//2:(i+32)//2] if i//2 < len(data))
        lines.append(f"  {i:04x}: {hex_part}")
    return '\n'.join(lines)

def cfshow_str(frame, ptr_expr):
    """Get CFShow-style description of a CF object."""
    desc = get_summary(frame, f'(NSString*)[(id){ptr_expr} description]')
    if desc and len(desc) > 2:
        return desc
    desc = get_summary(frame, f'(NSString*)[NSString stringWithFormat:@"%@", (id){ptr_expr}]')
    return desc or "(unknown)"

# ============================================================
# Breakpoint callbacks
# ============================================================

def on_send(frame, bp_loc, dict):
    """AMDServiceConnectionSend(conn, data, length) — capture raw bytes."""
    thread = frame.GetThread()
    process = thread.GetProcess()

    conn = frame.FindRegister("rdi").GetValueAsUnsigned()
    data_ptr = frame.FindRegister("rsi").GetValueAsUnsigned()
    length = frame.FindRegister("rdx").GetValueAsUnsigned()

    log(f"AMDServiceConnectionSend(conn={hex(conn)}, len={length})")
    if data_ptr and length > 0:
        dump = hex_dump(process, data_ptr, length, max_bytes=1024)
        log(f"  DATA:\n{dump}")
        # Try to parse as plist (skip 4-byte length header)
        if length > 4:
            err = lldb.SBError()
            raw = process.ReadMemory(data_ptr, min(length, 2048), err)
            if not err.Fail() and raw:
                # Check if starts with bplist (after 4-byte header)
                if len(raw) > 4 and raw[4:10] == b'bplist':
                    try:
                        import plistlib
                        plist_data = plistlib.loads(raw[4:])
                        log(f"  PLIST: {plist_data}")
                    except:
                        pass
                elif raw[:6] == b'bplist':
                    try:
                        import plistlib
                        plist_data = plistlib.loads(raw)
                        log(f"  PLIST: {plist_data}")
                    except:
                        pass
    return False  # Don't stop

def on_receive(frame, bp_loc, dict):
    """AMDServiceConnectionReceive(conn, buf, length) — log the call."""
    length = frame.FindRegister("rdx").GetValueAsUnsigned()
    log(f"AMDServiceConnectionReceive(len={length})")
    return False

def on_atcf_create(frame, bp_loc, dict):
    """ATCFMessageCreate(flags, name, params) — capture message details."""
    flags = frame.FindRegister("rdi").GetValueAsUnsigned()
    name_ptr = frame.FindRegister("rsi").GetValueAsUnsigned()
    params_ptr = frame.FindRegister("rdx").GetValueAsUnsigned()

    name = cfshow_str(frame, f"(void*){name_ptr}") if name_ptr else "NULL"
    params = cfshow_str(frame, f"(void*){params_ptr}") if params_ptr else "NULL"

    log(f"ATCFMessageCreate(flags={flags}, name={name})")
    if params_ptr:
        # Try to get a more detailed dump
        desc = get_summary(frame, f'(NSString*)[(NSDictionary*){params_ptr} description]')
        if desc:
            # Truncate very long descriptions
            if len(desc) > 3000:
                desc = desc[:3000] + "... (truncated)"
            log(f"  PARAMS: {desc}")
    return False

def on_send_file_begin(frame, bp_loc, dict):
    """ATHostConnectionSendFileBegin(conn, assetID, dataclass, fileSize, totalSize, ?)."""
    conn = frame.FindRegister("rdi").GetValueAsUnsigned()
    asset_id_ptr = frame.FindRegister("rsi").GetValueAsUnsigned()
    dataclass_ptr = frame.FindRegister("rdx").GetValueAsUnsigned()
    file_size_ptr = frame.FindRegister("rcx").GetValueAsUnsigned()

    asset_id = cfshow_str(frame, f"(void*){asset_id_ptr}") if asset_id_ptr else "?"
    dataclass = cfshow_str(frame, f"(void*){dataclass_ptr}") if dataclass_ptr else "?"
    file_size = cfshow_str(frame, f"(void*){file_size_ptr}") if file_size_ptr else "?"

    log(f"ATHostConnectionSendFileBegin(assetID={asset_id}, dataclass={dataclass}, fileSize={file_size})")
    return False

def on_send_asset_completed(frame, bp_loc, dict):
    """ATHostConnectionSendAssetCompleted(conn, assetID, dataclass, assetPath)."""
    asset_id_ptr = frame.FindRegister("rsi").GetValueAsUnsigned()
    dataclass_ptr = frame.FindRegister("rdx").GetValueAsUnsigned()
    path_ptr = frame.FindRegister("rcx").GetValueAsUnsigned()

    asset_id = cfshow_str(frame, f"(void*){asset_id_ptr}") if asset_id_ptr else "?"
    dataclass = cfshow_str(frame, f"(void*){dataclass_ptr}") if dataclass_ptr else "?"
    path = cfshow_str(frame, f"(void*){path_ptr}") if path_ptr else "?"

    log(f"ATHostConnectionSendAssetCompleted(assetID={asset_id}, dataclass={dataclass}, path={path})")
    return False

def on_send_metadata_finished(frame, bp_loc, dict):
    """ATHostConnectionSendMetadataSyncFinished(conn, syncTypes, anchors)."""
    sync_types_ptr = frame.FindRegister("rsi").GetValueAsUnsigned()
    anchors_ptr = frame.FindRegister("rdx").GetValueAsUnsigned()

    st = cfshow_str(frame, f"(void*){sync_types_ptr}") if sync_types_ptr else "?"
    an = cfshow_str(frame, f"(void*){anchors_ptr}") if anchors_ptr else "?"

    log(f"ATHostConnectionSendMetadataSyncFinished(syncTypes={st}, anchors={an})")
    return False

def on_send_host_info(frame, bp_loc, dict):
    """ATHostConnectionSendHostInfo(conn, hostInfo)."""
    info_ptr = frame.FindRegister("rsi").GetValueAsUnsigned()
    info = cfshow_str(frame, f"(void*){info_ptr}") if info_ptr else "?"
    log(f"ATHostConnectionSendHostInfo({info})")
    return False

def on_send_message(frame, bp_loc, dict):
    """ATHostConnectionSendMessage(conn, msg) — capture full message."""
    msg_ptr = frame.FindRegister("rsi").GetValueAsUnsigned()
    if msg_ptr:
        desc = cfshow_str(frame, f"(void*){msg_ptr}")
        if desc and len(desc) > 3000:
            desc = desc[:3000] + "... (truncated)"
        log(f"ATHostConnectionSendMessage:\n  {desc}")
    else:
        log(f"ATHostConnectionSendMessage(NULL)")
    return False

def on_read_message(frame, bp_loc, dict):
    """ATHostConnectionReadMessage(conn) — log the call."""
    log(f"ATHostConnectionReadMessage()")
    return False

def on_send_power(frame, bp_loc, dict):
    """ATHostConnectionSendPowerAssertion(conn, bool)."""
    val_ptr = frame.FindRegister("rsi").GetValueAsUnsigned()
    log(f"ATHostConnectionSendPowerAssertion(val={hex(val_ptr) if val_ptr else 'NULL'})")
    return False

def on_get_grappa(frame, bp_loc, dict):
    """ATHostConnectionGetGrappaSessionId(conn)."""
    conn = frame.FindRegister("rdi").GetValueAsUnsigned()
    log(f"ATHostConnectionGetGrappaSessionId(conn={hex(conn)})")
    return False

def on_send_file_progress(frame, bp_loc, dict):
    """ATHostConnectionSendFileProgress — log progress."""
    asset_ptr = frame.FindRegister("rsi").GetValueAsUnsigned()
    asset = cfshow_str(frame, f"(void*){asset_ptr}") if asset_ptr else "?"
    log(f"ATHostConnectionSendFileProgress(assetID={asset})")
    return False

# ============================================================

def __lldb_init_module(debugger, internal_dict):
    target = debugger.GetSelectedTarget()

    breakpoints = [
        ("AMDServiceConnectionSend", "on_send"),
        ("AMDServiceConnectionReceive", "on_receive"),
        ("ATCFMessageCreate", "on_atcf_create"),
        ("ATHostConnectionSendFileBegin", "on_send_file_begin"),
        ("ATHostConnectionSendAssetCompleted", "on_send_asset_completed"),
        ("ATHostConnectionSendMetadataSyncFinished", "on_send_metadata_finished"),
        ("ATHostConnectionSendHostInfo", "on_send_host_info"),
        ("ATHostConnectionSendMessage", "on_send_message"),
        ("ATHostConnectionReadMessage", "on_read_message"),
        ("ATHostConnectionSendPowerAssertion", "on_send_power"),
        ("ATHostConnectionGetGrappaSessionId", "on_get_grappa"),
        ("ATHostConnectionSendFileProgress", "on_send_file_progress"),
    ]

    for sym, callback in breakpoints:
        bp = target.BreakpointCreateByName(sym)
        if bp.GetNumLocations() > 0:
            bp.SetScriptCallbackFunction(f"lldb_reference_deep_trace.{callback}")
            bp.SetAutoContinue(True)
            print(f"  ✓ {sym} ({bp.GetNumLocations()} locations)")
        else:
            print(f"  ✗ {sym} (not found)")

    log(f"=== Deep third-party tool trace started at {TIMESTAMP} ===")
    print(f"\nLogging to: {LOG_FILE}")
    print("Now trigger a sync in third-party tool. Press Ctrl+C when done.")

    # Continue the process
    debugger.HandleCommand("continue")
