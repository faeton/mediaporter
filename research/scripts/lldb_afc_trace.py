"""
LLDB trace for third-party tool — captures AFC file operations during sync.

Goal: Find out what the framework writes to the device via AFC
between SendFileBegin and SendAssetCompleted. This might include
metadata that sets media_type.

Traces:
- AFCFileRefOpen / AFCFileRefClose
- AFCFileRefWrite (with data hex dump)
- AFCDirectoryOpen / AFCDirectoryCreate
- AFCRemovePath
- Also captures the high-level ATH calls for context

Usage (third-party tool is x86_64, use rdi/rsi/rdx):
  lldb -p <PID> -o "command script import scripts/lldb_reference_afc_trace.py"
"""
import lldb
import os
import datetime

LOG_DIR = os.path.expanduser("/Users/faeton/Sites/mediaporter/traces")
os.makedirs(LOG_DIR, exist_ok=True)
TS = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
LOG_FILE = os.path.join(LOG_DIR, f"reference-afc-{TS}.log")

_fh = None
_n = 0

def log(msg):
    global _fh, _n
    if not _fh: _fh = open(LOG_FILE, "w")
    _n += 1
    line = f"[{_n:04d}] {msg}"
    _fh.write(line + "\n"); _fh.flush()
    print(line)

def get_str(frame, expr):
    try:
        v = frame.EvaluateExpression(expr)
        if v.IsValid() and v.GetError().Success():
            return v.GetSummary() or v.GetValue() or str(v)
    except: pass
    return None

def hex_dump(process, addr, length, max_bytes=256):
    if not addr or length <= 0: return "(empty)"
    length = min(length, max_bytes)
    err = lldb.SBError()
    data = process.ReadMemory(addr, length, err)
    if err.Fail(): return f"(read error)"
    # Show hex + ascii
    lines = []
    for i in range(0, len(data), 32):
        chunk = data[i:i+32]
        hex_part = ' '.join(f'{b:02x}' for b in chunk)
        ascii_part = ''.join(chr(b) if 32 <= b < 127 else '.' for b in chunk)
        lines.append(f"  {i:04x}: {hex_part:<96s} {ascii_part}")
    return '\n'.join(lines)

# x86_64 calling convention: rdi, rsi, rdx, rcx, r8, r9
def reg(frame, name):
    r = frame.FindRegister(name)
    return r.GetValueAsUnsigned() if r else 0

# ============================================================
# AFC callbacks
# ============================================================
def on_afc_file_open(frame, bp_loc, dict):
    """AFCFileRefOpen(conn, path, mode, &handle)"""
    conn = reg(frame, "rdi")
    path_ptr = reg(frame, "rsi")
    mode = reg(frame, "rdx")
    # Try to read path string
    process = frame.GetThread().GetProcess()
    err = lldb.SBError()
    path_bytes = process.ReadMemory(path_ptr, 512, err) if path_ptr else b""
    path = path_bytes.split(b'\x00')[0].decode('utf-8', errors='replace') if path_bytes else "?"
    log(f"AFCFileRefOpen(path={path!r}, mode={mode})")
    return False

def on_afc_file_write(frame, bp_loc, dict):
    """AFCFileRefWrite(conn, handle, data, length)"""
    conn = reg(frame, "rdi")
    handle = reg(frame, "rsi")
    data_ptr = reg(frame, "rdx")
    length = reg(frame, "rcx")
    log(f"AFCFileRefWrite(handle={handle}, len={length})")
    if data_ptr and length > 0 and length < 4096:
        dump = hex_dump(frame.GetThread().GetProcess(), data_ptr, length, max_bytes=4096)
        log(f"  DATA:\n{dump}")
        # Try plist decode for plist-sized data
        if length > 8 and length < 4096:
            try:
                import plistlib
                err2 = lldb.SBError()
                raw = process.ReadMemory(data_ptr, length, err2)
                if not err2.Fail() and raw[:6] == b'bplist':
                    pl = plistlib.loads(raw)
                    log(f"  PLIST DECODED: {pl}")
            except: pass
    elif length >= 4096:
        dump = hex_dump(frame.GetThread().GetProcess(), data_ptr, 256, max_bytes=256)
        log(f"  DATA (first 256 of {length}):\n{dump}")
    return False

def on_afc_file_close(frame, bp_loc, dict):
    """AFCFileRefClose(conn, handle)"""
    handle = reg(frame, "rsi")
    log(f"AFCFileRefClose(handle={handle})")
    return False

def on_afc_dir_open(frame, bp_loc, dict):
    """AFCDirectoryOpen(conn, path, &handle)"""
    path_ptr = reg(frame, "rsi")
    process = frame.GetThread().GetProcess()
    err = lldb.SBError()
    path_bytes = process.ReadMemory(path_ptr, 512, err) if path_ptr else b""
    path = path_bytes.split(b'\x00')[0].decode('utf-8', errors='replace') if path_bytes else "?"
    log(f"AFCDirectoryOpen(path={path!r})")
    return False

def on_afc_dir_create(frame, bp_loc, dict):
    """AFCDirectoryCreate(conn, path)"""
    path_ptr = reg(frame, "rsi")
    process = frame.GetThread().GetProcess()
    err = lldb.SBError()
    path_bytes = process.ReadMemory(path_ptr, 512, err) if path_ptr else b""
    path = path_bytes.split(b'\x00')[0].decode('utf-8', errors='replace') if path_bytes else "?"
    log(f"AFCDirectoryCreate(path={path!r})")
    return False

def on_afc_remove(frame, bp_loc, dict):
    """AFCRemovePath(conn, path)"""
    path_ptr = reg(frame, "rsi")
    process = frame.GetThread().GetProcess()
    err = lldb.SBError()
    path_bytes = process.ReadMemory(path_ptr, 512, err) if path_ptr else b""
    path = path_bytes.split(b'\x00')[0].decode('utf-8', errors='replace') if path_bytes else "?"
    log(f"AFCRemovePath(path={path!r})")
    return False

def on_afc_get_file_info(frame, bp_loc, dict):
    """AFCFileInfoOpen(conn, path, &info)"""
    path_ptr = reg(frame, "rsi")
    process = frame.GetThread().GetProcess()
    err = lldb.SBError()
    path_bytes = process.ReadMemory(path_ptr, 512, err) if path_ptr else b""
    path = path_bytes.split(b'\x00')[0].decode('utf-8', errors='replace') if path_bytes else "?"
    log(f"AFCFileInfoOpen(path={path!r})")
    return False

# ============================================================
# ATH callbacks for context
# ============================================================
def on_send_file_begin(frame, bp_loc, dict):
    asset_ptr = reg(frame, "rsi")
    asset = get_str(frame, f"(NSString*)[(id)(void*){asset_ptr} description]") if asset_ptr else "?"
    log(f"--- ATHostConnectionSendFileBegin(assetID={asset}) ---")
    return False

def on_send_asset_completed(frame, bp_loc, dict):
    asset_ptr = reg(frame, "rsi")
    path_ptr = reg(frame, "rcx")
    asset = get_str(frame, f"(NSString*)[(id)(void*){asset_ptr} description]") if asset_ptr else "?"
    path = get_str(frame, f"(NSString*)[(id)(void*){path_ptr} description]") if path_ptr else "?"
    log(f"--- ATHostConnectionSendAssetCompleted(assetID={asset}, path={path}) ---")
    return False

def on_send_file_progress(frame, bp_loc, dict):
    # Don't log every progress — just count
    log(f"ATHostConnectionSendFileProgress")
    return False

def on_metadata_finished(frame, bp_loc, dict):
    log(f"--- ATHostConnectionSendMetadataSyncFinished ---")
    return False

# ============================================================

def __lldb_init_module(debugger, internal_dict):
    target = debugger.GetSelectedTarget()

    breakpoints = [
        # AFC operations
        ("AFCFileRefOpen", "on_afc_file_open"),
        ("AFCFileRefWrite", "on_afc_file_write"),
        ("AFCFileRefClose", "on_afc_file_close"),
        ("AFCDirectoryOpen", "on_afc_dir_open"),
        ("AFCDirectoryCreate", "on_afc_dir_create"),
        ("AFCRemovePath", "on_afc_remove"),
        ("AFCFileInfoOpen", "on_afc_get_file_info"),
        # ATH context
        ("ATHostConnectionSendFileBegin", "on_send_file_begin"),
        ("ATHostConnectionSendAssetCompleted", "on_send_asset_completed"),
        ("ATHostConnectionSendFileProgress", "on_send_file_progress"),
        ("ATHostConnectionSendMetadataSyncFinished", "on_metadata_finished"),
    ]

    for sym, callback in breakpoints:
        bp = target.BreakpointCreateByName(sym)
        if bp.GetNumLocations() > 0:
            bp.SetScriptCallbackFunction(f"lldb_reference_afc_trace.{callback}")
            bp.SetAutoContinue(True)
            print(f"  ✓ {sym} ({bp.GetNumLocations()} loc)")
        else:
            print(f"  ✗ {sym}")

    log(f"=== third-party tool AFC trace started at {TS} ===")
    print(f"\nLog: {LOG_FILE}")
    print("Trigger a sync in third-party tool now!")
    debugger.HandleCommand("continue")
