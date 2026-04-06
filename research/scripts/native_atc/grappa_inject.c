/*
 * Dylib to inject into a signed Apple process to test Grappa generation.
 * The __attribute__((constructor)) runs when the dylib is loaded.
 *
 * Build:
 *   clang -shared -o grappa_inject.dylib grappa_inject.c -framework CoreFoundation -ldl
 *
 * Usage (inject into an Apple process):
 *   DYLD_INSERT_LIBRARIES=./grappa_inject.dylib /usr/bin/some_apple_binary
 */
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <dlfcn.h>
#include <unistd.h>

typedef void* AMDeviceRef;
typedef void (*AMDeviceNotificationCallbackFn)(void*, void*);

static AMDeviceRef g_dev = NULL;
static char g_udid[256];

static void* (*pAMDeviceNotificationSubscribe)(AMDeviceNotificationCallbackFn, unsigned, unsigned, void*, void**);
static void* (*pAMDeviceCopyDeviceIdentifier)(AMDeviceRef);
static void* (*pAMDeviceRetain)(AMDeviceRef);
static void* (*pATHostConnectionCreateWithLibrary)(CFStringRef, CFStringRef, unsigned);
static void* (*pATHostConnectionSendHostInfo)(void*, CFDictionaryRef);
static int   (*pATHostConnectionGetGrappaSessionId)(void*);
static void* (*pATHostConnectionReadMessage)(void*);
static int   (*pATHostConnectionSendMessage)(void*, void*);
static int   (*pATHostConnectionSendFileBegin)(void*, CFNumberRef, CFStringRef, CFNumberRef, CFNumberRef, CFNumberRef);
static int   (*pATHostConnectionSendAssetCompleted)(void*, CFNumberRef, CFStringRef, CFStringRef);
static int   (*pATHostConnectionSendMetadataSyncFinished)(void*, CFDictionaryRef, CFDictionaryRef);
static int   (*pATHostConnectionInvalidate)(void*);
static void  (*pATHostConnectionRelease)(void*);
static void* (*pATCFMessageCreate)(unsigned, CFStringRef, CFDictionaryRef);
static CFStringRef (*pATCFMessageGetName)(void*);
static void* (*pATCFMessageGetParam)(void*, CFStringRef);

static void dev_cb(void* info, void* arg) {
    AMDeviceRef* p = (AMDeviceRef*)info;
    if (p[0] && !g_dev) {
        g_dev = pAMDeviceRetain(p[0]);
        CFStringRef u = pAMDeviceCopyDeviceIdentifier(p[0]);
        CFStringGetCString(u, g_udid, 256, kCFStringEncodingUTF8);
        CFRelease(u);
    }
}

__attribute__((constructor))
static void grappa_test_init(void) {
    FILE* log = fopen("/tmp/grappa_inject.log", "w");
    if (!log) log = stderr;

    fprintf(log, "=== grappa_inject loaded (pid=%d) ===\n", getpid()); fflush(log);

    void* md = dlopen("/System/Library/PrivateFrameworks/MobileDevice.framework/MobileDevice", RTLD_LAZY);
    void* ath = dlopen("/System/Library/PrivateFrameworks/AirTrafficHost.framework/AirTrafficHost", RTLD_LAZY);
    if (!md || !ath) {
        fprintf(log, "dlopen fail: md=%p ath=%p\n", md, ath); fflush(log);
        fclose(log);
        return;
    }

    *(void**)&pAMDeviceNotificationSubscribe = dlsym(md, "AMDeviceNotificationSubscribe");
    *(void**)&pAMDeviceCopyDeviceIdentifier = dlsym(md, "AMDeviceCopyDeviceIdentifier");
    *(void**)&pAMDeviceRetain = dlsym(md, "AMDeviceRetain");
    *(void**)&pATHostConnectionCreateWithLibrary = dlsym(ath, "ATHostConnectionCreateWithLibrary");
    *(void**)&pATHostConnectionSendHostInfo = dlsym(ath, "ATHostConnectionSendHostInfo");
    *(void**)&pATHostConnectionGetGrappaSessionId = dlsym(ath, "ATHostConnectionGetGrappaSessionId");
    *(void**)&pATHostConnectionReadMessage = dlsym(ath, "ATHostConnectionReadMessage");
    *(void**)&pATHostConnectionSendMessage = dlsym(ath, "ATHostConnectionSendMessage");
    *(void**)&pATHostConnectionSendFileBegin = dlsym(ath, "ATHostConnectionSendFileBegin");
    *(void**)&pATHostConnectionSendAssetCompleted = dlsym(ath, "ATHostConnectionSendAssetCompleted");
    *(void**)&pATHostConnectionSendMetadataSyncFinished = dlsym(ath, "ATHostConnectionSendMetadataSyncFinished");
    *(void**)&pATHostConnectionInvalidate = dlsym(ath, "ATHostConnectionInvalidate");
    *(void**)&pATHostConnectionRelease = dlsym(ath, "ATHostConnectionRelease");
    *(void**)&pATCFMessageCreate = dlsym(ath, "ATCFMessageCreate");
    *(void**)&pATCFMessageGetName = dlsym(ath, "ATCFMessageGetName");
    *(void**)&pATCFMessageGetParam = dlsym(ath, "ATCFMessageGetParam");

    fprintf(log, "Symbols loaded. Finding device...\n"); fflush(log);

    void* notif = NULL;
    pAMDeviceNotificationSubscribe(dev_cb, 0, 0, NULL, &notif);
    for (int i = 0; i < 50 && !g_dev; i++)
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.1, false);
    if (!g_dev) {
        fprintf(log, "No device found\n"); fflush(log);
        fclose(log);
        _exit(0);
        return;
    }
    fprintf(log, "Device: %s\n", g_udid); fflush(log);

    void* conn = pATHostConnectionCreateWithLibrary(
        CFSTR("com.mediaporter.sync"),
        CFStringCreateWithCString(NULL, g_udid, kCFStringEncodingUTF8), 0);

    int gid = pATHostConnectionGetGrappaSessionId(conn);
    fprintf(log, "*** Grappa session ID (initial): %d ***\n", gid); fflush(log);

    // Send HostInfo
    CFMutableDictionaryRef hi = CFDictionaryCreateMutable(NULL, 0,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFDictionarySetValue(hi, CFSTR("LibraryID"), CFSTR("MEDIAPORTER00001"));
    CFDictionarySetValue(hi, CFSTR("SyncHostName"), CFSTR("m3max"));
    CFMutableArrayRef ea = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
    CFDictionarySetValue(hi, CFSTR("SyncedDataclasses"), ea);
    CFDictionarySetValue(hi, CFSTR("Version"), CFSTR("12.8"));
    pATHostConnectionSendHostInfo(conn, hi);
    fprintf(log, "HostInfo sent\n"); fflush(log);

    // Let framework set up
    for (int i = 0; i < 30; i++)
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.1, false);

    gid = pATHostConnectionGetGrappaSessionId(conn);
    fprintf(log, "*** Grappa session ID (after HostInfo): %d ***\n", gid); fflush(log);

    if (gid != 0) {
        fprintf(log, "\n*** GRAPPA WORKS! Session ID = %d ***\n", gid);
        fprintf(log, "The injected process's entitlements enabled Grappa!\n");
    } else {
        fprintf(log, "Grappa still 0 — this process doesn't have the right entitlements\n");
    }

    fflush(log);
    fclose(log);

    pATHostConnectionRelease(conn);
    _exit(0);  // Exit the host process after our test
}
