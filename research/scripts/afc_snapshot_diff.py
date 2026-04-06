#!/usr/bin/env python3
"""
Snapshot /iTunes_Control/ before and after a Finder sync to see what plists Finder writes.

Usage:
  python scripts/afc_snapshot_diff.py pre    # Take pre-sync snapshot
  python scripts/afc_snapshot_diff.py post   # Take post-sync snapshot + diff
"""
import asyncio, hashlib, json, os, plistlib, sys, datetime

SNAPSHOT_DIR = '/tmp/afc_snapshots'
SCAN_ROOTS = [
    '/iTunes_Control',
]

async def take_snapshot(a, label):
    """Walk /iTunes_Control/ and record every file's hash + size + content (small files)."""
    snapshot = {}
    print(f"\n[{label}] Scanning device filesystem...")

    async def scan_dir(path):
        try:
            entries = await a.listdir(path)
        except Exception as e:
            return
        for entry in entries:
            if entry in ('.', '..'): continue
            full = f'{path}/{entry}'
            try:
                stat = await a.stat(full)
                if stat.get('st_ifmt') == 'S_IFDIR':
                    await scan_dir(full)
                else:
                    size = int(stat.get('st_size', 0))
                    rec = {'size': size, 'mtime': str(stat.get('st_mtime', ''))}
                    # Pull content for small files (plists, cig, etc.)
                    if size < 500_000:
                        try:
                            data = await a.get_file_contents(full)
                            rec['hash'] = hashlib.sha256(data).hexdigest()
                            rec['data_b64'] = data.hex() if size < 100 else None
                            # Try plist parse
                            if full.endswith('.plist'):
                                try:
                                    rec['plist'] = plistlib.loads(data)
                                except:
                                    pass
                        except Exception as e:
                            rec['pull_error'] = str(e)
                    else:
                        rec['hash'] = f'SKIPPED_LARGE_{size}'
                    snapshot[full] = rec
            except Exception as e:
                snapshot[full] = {'error': str(e)}

    for root in SCAN_ROOTS:
        await scan_dir(root)

    print(f"[{label}] Found {len(snapshot)} files")
    return snapshot


def diff_snapshots(pre, post):
    """Compare two snapshots and return added/modified/removed files."""
    added = {}
    modified = {}
    removed = {}

    for path, info in post.items():
        if path not in pre:
            added[path] = info
        elif pre[path].get('hash') != info.get('hash'):
            modified[path] = {'before': pre[path], 'after': info}

    for path in pre:
        if path not in post:
            removed[path] = pre[path]

    return added, modified, removed


def print_plist_content(label, plist_data):
    """Pretty-print a plist."""
    try:
        xml = plistlib.dumps(plist_data, fmt=plistlib.FMT_XML).decode()
        print(f"\n{'='*60}")
        print(f"  {label}")
        print(f"{'='*60}")
        print(xml)
    except Exception as e:
        print(f"  (plist dump error: {e})")
        print(f"  Raw: {plist_data}")


async def pull_new_files(a, added):
    """Pull all new files to local disk for analysis."""
    os.makedirs(f'{SNAPSHOT_DIR}/new_files', exist_ok=True)
    for path, info in added.items():
        local = f'{SNAPSHOT_DIR}/new_files/{path.replace("/", "_")}'
        try:
            data = await a.get_file_contents(path)
            with open(local, 'wb') as f:
                f.write(data)
            print(f"  Saved: {path} → {local} ({len(data)} bytes)")
        except Exception as e:
            print(f"  Error pulling {path}: {e}")


def serialize(obj):
    if isinstance(obj, (datetime.datetime, datetime.date)):
        return obj.isoformat()
    if isinstance(obj, bytes):
        return obj.hex()
    return str(obj)


async def do_snapshot(label):
    from pymobiledevice3.lockdown import create_using_usbmux
    from pymobiledevice3.services.afc import AfcService

    os.makedirs(SNAPSHOT_DIR, exist_ok=True)

    ld = await create_using_usbmux()
    async with AfcService(ld) as a:
        snap = await take_snapshot(a, label)
        fname = f'{SNAPSHOT_DIR}/{label.lower()}_snapshot.json'
        with open(fname, 'w') as f:
            json.dump(snap, f, indent=2, default=serialize)
        print(f"\nSnapshot saved to {fname} ({len(snap)} files)")
        return snap


async def do_diff():
    from pymobiledevice3.lockdown import create_using_usbmux
    from pymobiledevice3.services.afc import AfcService

    os.makedirs(SNAPSHOT_DIR, exist_ok=True)

    # Load pre snapshot
    pre_file = f'{SNAPSHOT_DIR}/pre_snapshot.json'
    if not os.path.exists(pre_file):
        print(f"ERROR: No pre-snapshot found at {pre_file}")
        print("Run: python scripts/afc_snapshot_diff.py pre")
        return
    with open(pre_file) as f:
        pre = json.load(f)

    # Take post snapshot
    ld = await create_using_usbmux()
    async with AfcService(ld) as a:
        post = await take_snapshot(a, 'POST')

        with open(f'{SNAPSHOT_DIR}/post_snapshot.json', 'w') as f:
            json.dump(post, f, indent=2, default=serialize)

        # Diff
        added, modified, removed = diff_snapshots(pre, post)

        print(f"\n{'='*60}")
        print(f"  DIFF RESULTS")
        print(f"{'='*60}")
        print(f"  Added:    {len(added)} files")
        print(f"  Modified: {len(modified)} files")
        print(f"  Removed:  {len(removed)} files")

        if added:
            print(f"\n--- NEW FILES ---")
            for path, info in sorted(added.items()):
                print(f"\n  + {path}  ({info.get('size', '?')} bytes)")
                if info.get('plist'):
                    print_plist_content(path, info['plist'])
                elif path.endswith('.cig'):
                    try:
                        data = await a.get_file_contents(path)
                        print(f"    CIG ({len(data)} bytes): {data.hex()}")
                    except:
                        pass

            print(f"\n--- Pulling new files locally ---")
            await pull_new_files(a, added)

        if modified:
            print(f"\n--- MODIFIED FILES ---")
            for path, info in sorted(modified.items()):
                before = info['before']
                after = info['after']
                print(f"\n  ~ {path}")
                print(f"    Size: {before.get('size', '?')} → {after.get('size', '?')}")
                if after.get('plist'):
                    print_plist_content(f"{path} (AFTER)", after['plist'])
                if before.get('plist'):
                    print_plist_content(f"{path} (BEFORE)", before['plist'])

        if removed:
            print(f"\n--- REMOVED FILES ---")
            for path, info in sorted(removed.items()):
                print(f"  - {path}  ({info.get('size', '?')} bytes)")

        # Summary
        print(f"\n{'='*60}")
        print(f"  SYNC PLIST ANALYSIS")
        print(f"{'='*60}")
        plist_files = [p for p in added if p.endswith('.plist')]
        cig_files = [p for p in added if p.endswith('.cig')]
        media_files = [p for p in added if any(p.endswith(ext) for ext in ['.mp4', '.m4v', '.mov', '.m4a'])]

        print(f"  New plists: {plist_files or 'none'}")
        print(f"  New CIG files: {cig_files or 'none'}")
        print(f"  New media files: {media_files or 'none'}")

        if plist_files:
            print(f"\n  Key paths to check:")
            for p in plist_files:
                print(f"    {p}")
                if 'Sync' in p:
                    print(f"    ^^^ THIS IS A SYNC PLIST — compare with our format!")


if __name__ == '__main__':
    mode = sys.argv[1] if len(sys.argv) > 1 else 'pre'
    if mode == 'pre':
        asyncio.run(do_snapshot('pre'))
        print("\nNow sync a video via Finder, then run:")
        print("  python scripts/afc_snapshot_diff.py post")
    elif mode == 'post':
        asyncio.run(do_diff())
    else:
        print(f"Usage: {sys.argv[0]} [pre|post]")
