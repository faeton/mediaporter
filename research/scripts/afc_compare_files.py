#!/usr/bin/env python3
"""Pull and compare files from device — third-party tool's vs ours."""
import asyncio, hashlib, os, subprocess, sys

async def main():
    from pymobiledevice3.lockdown import create_using_usbmux
    from pymobiledevice3.services.afc import AfcService

    ld = await create_using_usbmux()
    async with AfcService(ld) as a:
        print("Scanning /iTunes_Control/Music/ for all media files...")
        files_found = []
        for slot in range(50):
            slot_dir = f'/iTunes_Control/Music/F{slot:02d}'
            try:
                entries = await a.listdir(slot_dir)
                for e in entries:
                    if e in ('.', '..'): continue
                    full = f'{slot_dir}/{e}'
                    try:
                        stat = await a.stat(full)
                        size = stat.get('st_size', 0)
                        files_found.append((full, int(size)))
                    except:
                        files_found.append((full, -1))
            except:
                pass

        if not files_found:
            print("No files found in /iTunes_Control/Music/")
            return

        print(f"\nFound {len(files_found)} files:")
        for path, size in sorted(files_found):
            print(f"  {path}  ({size} bytes)")

        # Pull all files for comparison
        os.makedirs('/tmp/afc_compare', exist_ok=True)
        for path, size in files_found:
            local = f'/tmp/afc_compare/{path.replace("/", "_")}'
            try:
                data = await a.get_file_contents(path)
                with open(local, 'wb') as f:
                    f.write(data)
                md5 = hashlib.md5(data).hexdigest()
                print(f"\n  Pulled: {path} → {local}")
                print(f"    Size: {len(data)} bytes, MD5: {md5}")

                # ffprobe if available
                try:
                    r = subprocess.run(
                        ['ffprobe', '-v', 'quiet', '-print_format', 'json',
                         '-show_format', '-show_streams', local],
                        capture_output=True, text=True)
                    if r.returncode == 0:
                        import json
                        info = json.loads(r.stdout)
                        fmt = info.get('format', {})
                        print(f"    Format: {fmt.get('format_long_name', '?')}")
                        print(f"    Duration: {fmt.get('duration', '?')}s")
                        for s in info.get('streams', []):
                            ct = s.get('codec_type', '?')
                            cn = s.get('codec_name', '?')
                            tag = s.get('codec_tag_string', '?')
                            if ct == 'video':
                                print(f"    Video: {cn} ({tag}) {s.get('width')}x{s.get('height')}")
                            elif ct == 'audio':
                                print(f"    Audio: {cn} ({tag}) {s.get('sample_rate')}Hz")
                except FileNotFoundError:
                    pass
            except Exception as e:
                print(f"  Error pulling {path}: {e}")

        # Compare with our source
        src = 'test_fixtures/output/test_tiny.m4v'
        if os.path.exists(src):
            with open(src, 'rb') as f:
                src_data = f.read()
            src_md5 = hashlib.md5(src_data).hexdigest()
            print(f"\n--- Source file: {src} ---")
            print(f"  Size: {len(src_data)} bytes, MD5: {src_md5}")
            for path, size in files_found:
                local = f'/tmp/afc_compare/{path.replace("/", "_")}'
                if os.path.exists(local):
                    with open(local, 'rb') as f:
                        dev_data = f.read()
                    if dev_data == src_data:
                        print(f"  IDENTICAL to {path}")
                    else:
                        print(f"  DIFFERENT from {path} (device={len(dev_data)}B vs source={len(src_data)}B)")

asyncio.run(main())
