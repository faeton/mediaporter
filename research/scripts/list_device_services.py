#!/usr/bin/env python3
"""List all available lockdown services on the device."""
import asyncio

async def main():
    from pymobiledevice3.lockdown import create_using_usbmux
    ld = await create_using_usbmux()

    # Get all device values
    print("=== Device Info ===")
    for key in ['DeviceName', 'ProductType', 'ProductVersion', 'BuildVersion']:
        try:
            val = ld.get_value(key=key)
            print(f"  {key}: {val}")
        except:
            pass

    # List services from lockdown
    print("\n=== Known Services (from lockdown pairings) ===")
    try:
        services = ld.get_value(domain='com.apple.mobile.iTunes', key=None)
        if services:
            for k, v in sorted(services.items()):
                print(f"  {k}: {v}")
    except Exception as e:
        print(f"  iTunes domain: {e}")

    # Try to enumerate common media-related services
    print("\n=== Testing media-related services ===")
    media_services = [
        'com.apple.atc',
        'com.apple.atc2',
        'com.apple.medialibraryd',
        'com.apple.medialibraryd.control',
        'com.apple.mobile.house_arrest',
        'com.apple.mobile.installation_proxy',
        'com.apple.mobilebackup2',
        'com.apple.mobile.notification_proxy',
        'com.apple.afc',
        'com.apple.afc2',
        'com.apple.springboardservices',
        'com.apple.mobile.MCInstall',
        'com.apple.misagent',
        'com.apple.mobile.file_relay',
        'com.apple.os.update',
        'com.apple.streaming_zip_conduit',
        'com.apple.itdbprep.client',
        'com.apple.iosdiagnostics.relay',
        'com.apple.mobile.diagnostics_relay',
        'com.apple.dt.remotepairingdeviced.lockdown',
        'com.apple.mobile.assertion_agent',
    ]

    for svc in sorted(media_services):
        try:
            s = await ld.aio_start_lockdown_service(svc)
            print(f"  ✓ {svc} — connected")
            # Try reading initial message
            try:
                if hasattr(s, 'recv_plist'):
                    # Quick non-blocking read
                    import asyncio
                    try:
                        data = await asyncio.wait_for(s.recv_plist(), timeout=1.0)
                        print(f"    Initial message: {str(data)[:200]}")
                    except asyncio.TimeoutError:
                        print(f"    (no initial message)")
                    except:
                        pass
            except:
                pass
        except Exception as e:
            err = str(e)[:80]
            print(f"  ✗ {svc} — {err}")

    # Check notification proxy for media-related notifications
    print("\n=== Notification Proxy Test ===")
    try:
        from pymobiledevice3.services.notification_proxy import NotificationProxyService
        async with NotificationProxyService(ld) as np:
            # Post some media-related notifications
            notifications = [
                'com.apple.atc.idlewake',
                'com.apple.itunes.sync.complete',
                'com.apple.mobile.application_installed',
            ]
            for n in notifications:
                try:
                    await np.notify_post(n)
                    print(f"  Posted: {n}")
                except Exception as e:
                    print(f"  Failed: {n} — {e}")
    except Exception as e:
        print(f"  NotificationProxy error: {e}")

asyncio.run(main())
