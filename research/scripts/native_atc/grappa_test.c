/*
 * Quick Grappa test — does our entitlement make the framework generate Grappa?
 * Build: clang -framework CoreFoundation -o grappa_test grappa_test.c -ldl
 * Sign:  codesign -s - --entitlements entitlements.plist grappa_test
 */
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <dlfcn.h>

typedef void* AMDeviceRef;
typedef void (*AMDeviceNotificationCallbackFn)(void*, void*);

static void* (*pAMDeviceNotificationSubscribe)(AMDeviceNotificationCallbackFn, unsigned, unsigned, void*, void**);
static void* (*pAMDeviceCopyDeviceIdentifier)(AMDeviceRef);
static void* (*pAMDeviceRetain)(AMDeviceRef);
static void* (*pATHostConnectionCreateWithLibrary)(CFStringRef, CFStringRef, unsigned);
static void* (*pATHostConnectionSendHostInfo)(void*, CFDictionaryRef);
static int   (*pATHostConnectionGetGrappaSessionId)(void*);
static void  (*pATHostConnectionRelease)(void*);

static AMDeviceRef g_dev = NULL;
static char g_udid[256];

static void dev_cb(void* info, void* arg) {
    AMDeviceRef* p = (AMDeviceRef*)info;
    if (p[0] && !g_dev) {
        g_dev = pAMDeviceRetain(p[0]);
        CFStringRef u = pAMDeviceCopyDeviceIdentifier(p[0]);
        CFStringGetCString(u, g_udid, 256, kCFStringEncodingUTF8);
        CFRelease(u);
    }
}

int main() {
    void* md = dlopen("/System/Library/PrivateFrameworks/MobileDevice.framework/MobileDevice", RTLD_LAZY);
    void* ath = dlopen("/System/Library/PrivateFrameworks/AirTrafficHost.framework/AirTrafficHost", RTLD_LAZY);
    if (!md || !ath) { fprintf(stderr, "dlopen fail\n"); return 1; }

    *(void**)&pAMDeviceNotificationSubscribe = dlsym(md, "AMDeviceNotificationSubscribe");
    *(void**)&pAMDeviceCopyDeviceIdentifier = dlsym(md, "AMDeviceCopyDeviceIdentifier");
    *(void**)&pAMDeviceRetain = dlsym(md, "AMDeviceRetain");
    *(void**)&pATHostConnectionCreateWithLibrary = dlsym(ath, "ATHostConnectionCreateWithLibrary");
    *(void**)&pATHostConnectionSendHostInfo = dlsym(ath, "ATHostConnectionSendHostInfo");
    *(void**)&pATHostConnectionGetGrappaSessionId = dlsym(ath, "ATHostConnectionGetGrappaSessionId");
    *(void**)&pATHostConnectionRelease = dlsym(ath, "ATHostConnectionRelease");

    printf("Waiting for device...\n"); fflush(stdout);
    void* notif = NULL;
    pAMDeviceNotificationSubscribe(dev_cb, 0, 0, NULL, &notif);
    for (int i = 0; i < 50 && !g_dev; i++)
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.1, false);
    if (!g_dev) { printf("No device\n"); return 1; }
    printf("Device: %s\n", g_udid); fflush(stdout);

    void* conn = pATHostConnectionCreateWithLibrary(
        CFSTR("com.mediaporter.sync"),
        CFStringCreateWithCString(NULL, g_udid, kCFStringEncodingUTF8), 0);

    int gid = pATHostConnectionGetGrappaSessionId(conn);
    printf("*** Grappa session ID (before HostInfo): %d ***\n", gid); fflush(stdout);

    CFMutableDictionaryRef hi = CFDictionaryCreateMutable(NULL, 0,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFDictionarySetValue(hi, CFSTR("LibraryID"), CFSTR("MEDIAPORTER00001"));
    CFDictionarySetValue(hi, CFSTR("SyncHostName"), CFSTR("m3max"));
    CFMutableArrayRef ea = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
    CFDictionarySetValue(hi, CFSTR("SyncedDataclasses"), ea);
    CFDictionarySetValue(hi, CFSTR("Version"), CFSTR("12.8"));
    pATHostConnectionSendHostInfo(conn, hi);
    printf("HostInfo sent\n"); fflush(stdout);

    // Give framework time to set up Grappa internally
    for (int i = 0; i < 30; i++)
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.1, false);

    gid = pATHostConnectionGetGrappaSessionId(conn);
    printf("*** Grappa session ID (after HostInfo + 3s): %d ***\n", gid); fflush(stdout);

    if (gid != 0) {
        printf("*** GRAPPA IS WORKING! Framework generated Grappa! ***\n");
    } else {
        printf("Grappa still 0 — entitlement not sufficient\n");
    }

    fflush(stdout);
    pATHostConnectionRelease(conn);
    return 0;
}
