/*
 * Minimal native ATC sync — tests if a signed binary gets Grappa from framework.
 *
 * Build:
 *   clang -framework CoreFoundation \
 *     -F/System/Library/PrivateFrameworks \
 *     -framework AirTrafficHost -framework MobileDevice \
 *     -o atc_sync atc_sync.c
 *   codesign -s - atc_sync   # ad-hoc sign
 *
 * Usage: ./atc_sync <video_file> [grappa_file]
 */
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <dlfcn.h>
#include <unistd.h>

// Function pointers — resolved at runtime via dlsym
typedef void* AMDeviceRef;
typedef void (*AMDeviceNotificationCallbackFn)(void*, void*);

static void* (*pAMDeviceNotificationSubscribe)(AMDeviceNotificationCallbackFn, unsigned int, unsigned int, void*, void**);
static void* (*pAMDeviceCopyDeviceIdentifier)(AMDeviceRef);
static void* (*pAMDeviceRetain)(AMDeviceRef);

static void* (*pATHostConnectionCreateWithLibrary)(CFStringRef, CFStringRef, unsigned int);
static void* (*pATHostConnectionSendHostInfo)(void*, CFDictionaryRef);
static void* (*pATHostConnectionReadMessage)(void*);
static int   (*pATHostConnectionSendMessage)(void*, void*);
static int   (*pATHostConnectionSendMetadataSyncFinished)(void*, CFDictionaryRef, CFDictionaryRef);
static int   (*pATHostConnectionSendFileBegin)(void*, CFNumberRef, CFStringRef, CFNumberRef, CFNumberRef, CFNumberRef);
static int   (*pATHostConnectionSendAssetCompleted)(void*, CFNumberRef, CFStringRef, CFStringRef);
static int   (*pATHostConnectionGetGrappaSessionId)(void*);
static int   (*pATHostConnectionInvalidate)(void*);
static void  (*pATHostConnectionRelease)(void*);
static void* (*pATCFMessageCreate)(unsigned int, CFStringRef, CFDictionaryRef);
static CFStringRef (*pATCFMessageGetName)(void*);
static void* (*pATCFMessageGetParam)(void*, CFStringRef);

static AMDeviceRef g_device = NULL;
static char g_udid[256] = {0};

static void device_callback(void* info, void* arg) {
    AMDeviceRef* dev_ptr = (AMDeviceRef*)info;
    AMDeviceRef dev = dev_ptr[0];
    if (dev && !g_device) {
        g_device = pAMDeviceRetain(dev);
        CFStringRef udid = pAMDeviceCopyDeviceIdentifier(dev);
        CFStringGetCString(udid, g_udid, sizeof(g_udid), kCFStringEncodingUTF8);
        CFRelease(udid);
    }
}

static void load_symbols(void) {
    void* md = dlopen("/System/Library/PrivateFrameworks/MobileDevice.framework/MobileDevice", RTLD_LAZY);
    void* ath = dlopen("/System/Library/PrivateFrameworks/AirTrafficHost.framework/AirTrafficHost", RTLD_LAZY);
    if (!md) { fprintf(stderr, "Failed to load MobileDevice\n"); exit(1); }
    if (!ath) { fprintf(stderr, "Failed to load AirTrafficHost\n"); exit(1); }

    #define LOAD(lib, name, ptr) do { \
        *(void**)&ptr = dlsym(lib, #name); \
        if (!ptr) fprintf(stderr, "  WARN: %s not found\n", #name); \
        else printf("  OK: %s\n", #name); \
    } while(0)

    printf("Loading symbols...\n");
    LOAD(md, AMDeviceNotificationSubscribe, pAMDeviceNotificationSubscribe);
    LOAD(md, AMDeviceCopyDeviceIdentifier, pAMDeviceCopyDeviceIdentifier);
    LOAD(md, AMDeviceRetain, pAMDeviceRetain);
    LOAD(ath, ATHostConnectionCreateWithLibrary, pATHostConnectionCreateWithLibrary);
    LOAD(ath, ATHostConnectionSendHostInfo, pATHostConnectionSendHostInfo);
    LOAD(ath, ATHostConnectionReadMessage, pATHostConnectionReadMessage);
    LOAD(ath, ATHostConnectionSendMessage, pATHostConnectionSendMessage);
    LOAD(ath, ATHostConnectionSendMetadataSyncFinished, pATHostConnectionSendMetadataSyncFinished);
    LOAD(ath, ATHostConnectionSendFileBegin, pATHostConnectionSendFileBegin);
    LOAD(ath, ATHostConnectionSendAssetCompleted, pATHostConnectionSendAssetCompleted);
    LOAD(ath, ATHostConnectionGetGrappaSessionId, pATHostConnectionGetGrappaSessionId);
    LOAD(ath, ATHostConnectionInvalidate, pATHostConnectionInvalidate);
    LOAD(ath, ATHostConnectionRelease, pATHostConnectionRelease);
    LOAD(ath, ATCFMessageCreate, pATCFMessageCreate);
    LOAD(ath, ATCFMessageGetName, pATCFMessageGetName);
    LOAD(ath, ATCFMessageGetParam, pATCFMessageGetParam);
    #undef LOAD
}

static const char* get_msg_name(void* msg) {
    static char buf[256];
    if (!msg) return "NULL";
    CFStringRef name = pATCFMessageGetName(msg);
    if (!name) return "?";
    CFStringGetCString(name, buf, sizeof(buf), kCFStringEncodingUTF8);
    return buf;
}

static void* read_until(void* conn, const char* target) {
    for (int i = 0; i < 10; i++) {
        void* msg = pATHostConnectionReadMessage(conn);
        if (!msg) { printf("  << NULL\n"); return NULL; }
        const char* name = get_msg_name(msg);
        printf("  << %s\n", name);
        if (strcmp(name, target) == 0) return msg;
    }
    return NULL;
}

int main(int argc, char** argv) {
    const char* video = argc > 1 ? argv[1] : "test_fixtures/output/test_tiny_red.m4v";
    const char* grappa_file = argc > 2 ? argv[2] : "traces/grappa.bin";

    load_symbols();

    // Find device
    printf("\nWaiting for device...\n");
    void* notification = NULL;
    pAMDeviceNotificationSubscribe(device_callback, 0, 0, NULL, &notification);
    for (int i = 0; i < 50 && !g_device; i++)
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.1, false);
    if (!g_device) { fprintf(stderr, "No device\n"); return 1; }
    printf("Device: %s\n", g_udid);

    // Create connection
    void* conn = pATHostConnectionCreateWithLibrary(
        CFSTR("com.mediaporter.sync"),
        CFStringCreateWithCString(NULL, g_udid, kCFStringEncodingUTF8), 0);
    if (!conn) { fprintf(stderr, "Connection failed\n"); return 1; }

    // === GRAPPA CHECK ===
    int gid = pATHostConnectionGetGrappaSessionId ? pATHostConnectionGetGrappaSessionId(conn) : -999;
    printf("\n*** Grappa session ID (initial): %d ***\n", gid);

    // [1] SendHostInfo
    printf("\n[1] SendHostInfo...\n");
    CFMutableDictionaryRef hi = CFDictionaryCreateMutable(NULL, 0,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFDictionarySetValue(hi, CFSTR("LibraryID"), CFSTR("MEDIAPORTER00001"));
    CFDictionarySetValue(hi, CFSTR("SyncHostName"), CFSTR("m3max"));
    CFMutableArrayRef ea = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
    CFDictionarySetValue(hi, CFSTR("SyncedDataclasses"), ea);
    CFDictionarySetValue(hi, CFSTR("Version"), CFSTR("12.8"));
    pATHostConnectionSendHostInfo(conn, hi);
    read_until(conn, "SyncAllowed");

    gid = pATHostConnectionGetGrappaSessionId ? pATHostConnectionGetGrappaSessionId(conn) : -999;
    printf("*** Grappa session ID (after HostInfo): %d ***\n", gid);

    // [2] RequestingSync with replayed Grappa
    printf("\n[2] RequestingSync...\n");
    FILE* gf = fopen(grappa_file, "rb");
    if (!gf) { fprintf(stderr, "Cannot open %s\n", grappa_file); return 1; }
    fseek(gf, 0, SEEK_END); long gs = ftell(gf); fseek(gf, 0, SEEK_SET);
    uint8_t* gb = malloc(gs); fread(gb, 1, gs, gf); fclose(gf);
    printf("  Grappa blob: %ld bytes\n", gs);

    CFDataRef grappa = CFDataCreate(NULL, gb, gs);
    CFMutableDictionaryRef hi2 = CFDictionaryCreateMutable(NULL, 0,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFDictionarySetValue(hi2, CFSTR("Grappa"), grappa);
    CFDictionarySetValue(hi2, CFSTR("LibraryID"), CFSTR("MEDIAPORTER00001"));
    CFDictionarySetValue(hi2, CFSTR("SyncHostName"), CFSTR("m3max"));
    CFDictionarySetValue(hi2, CFSTR("SyncedDataclasses"), ea);
    CFDictionarySetValue(hi2, CFSTR("Version"), CFSTR("12.8"));

    int zero = 0;
    CFNumberRef cf0 = CFNumberCreate(NULL, kCFNumberIntType, &zero);
    CFMutableDictionaryRef anch = CFDictionaryCreateMutable(NULL, 0,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFDictionarySetValue(anch, CFSTR("Media"), cf0);

    CFMutableArrayRef dcs = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
    CFArrayAppendValue(dcs, CFSTR("Media"));
    CFArrayAppendValue(dcs, CFSTR("Keybag"));

    CFMutableDictionaryRef rp = CFDictionaryCreateMutable(NULL, 0,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFDictionarySetValue(rp, CFSTR("DataclassAnchors"), anch);
    CFDictionarySetValue(rp, CFSTR("Dataclasses"), dcs);
    CFDictionarySetValue(rp, CFSTR("HostInfo"), hi2);

    void* reqMsg = pATCFMessageCreate(0, CFSTR("RequestingSync"), rp);
    int rc = pATHostConnectionSendMessage(conn, reqMsg);
    printf("  >> RequestingSync rc=%d\n", rc);

    void* readyMsg = read_until(conn, "ReadyForSync");
    if (!readyMsg) { fprintf(stderr, "No ReadyForSync!\n"); return 1; }

    gid = pATHostConnectionGetGrappaSessionId ? pATHostConnectionGetGrappaSessionId(conn) : -999;
    printf("*** Grappa session ID (after ReadyForSync): %d ***\n", gid);

    // [3] Try HIGH-LEVEL SendFileBegin (the key test!)
    printf("\n[3] HIGH-LEVEL SendFileBegin test...\n");

    FILE* vf = fopen(video, "rb");
    if (!vf) { fprintf(stderr, "Cannot open %s\n", video); return 1; }
    fseek(vf, 0, SEEK_END); long vsz = ftell(vf); fclose(vf);
    printf("  File: %s (%ld bytes)\n", video, vsz);

    long long aid = 349645419467270165LL;
    CFNumberRef cfAid = CFNumberCreate(NULL, kCFNumberLongLongType, &aid);
    CFNumberRef cfSz = CFNumberCreate(NULL, kCFNumberLongType, &vsz);

    rc = pATHostConnectionSendFileBegin(conn, cfAid, CFSTR("Media"), cfSz, cfSz, cfSz);
    printf("  >> SendFileBegin rc=%d\n", rc);

    // [4] Try SendAssetCompleted with existing third-party tool file
    printf("\n[4] SendAssetCompleted (existing third-party tool file)...\n");
    rc = pATHostConnectionSendAssetCompleted(conn, cfAid, CFSTR("Media"),
        CFSTR("/iTunes_Control/Music/F13/GTIV.m4v"));
    printf("  >> SendAssetCompleted rc=%d\n", rc);

    // [5] MetadataSyncFinished
    printf("\n[5] MetadataSyncFinished...\n");
    int one = 1, anch_val = 1;
    CFNumberRef cf1 = CFNumberCreate(NULL, kCFNumberIntType, &one);
    CFNumberRef cfA = CFNumberCreate(NULL, kCFNumberIntType, &anch_val);

    CFMutableDictionaryRef st = CFDictionaryCreateMutable(NULL, 0,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFDictionarySetValue(st, CFSTR("Keybag"), cf1);
    CFDictionarySetValue(st, CFSTR("Media"), cf1);
    CFMutableDictionaryRef sa = CFDictionaryCreateMutable(NULL, 0,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFDictionarySetValue(sa, CFSTR("Media"), cfA);
    rc = pATHostConnectionSendMetadataSyncFinished(conn, st, sa);
    printf("  >> MetadataSyncFinished rc=%d\n", rc);

    // [6] Read responses
    printf("\n[6] Responses...\n");
    for (int i = 0; i < 10; i++) {
        void* msg = pATHostConnectionReadMessage(conn);
        if (!msg) { printf("  << NULL (timeout?)\n"); break; }
        const char* nm = get_msg_name(msg);
        printf("  << %s\n", nm);
        CFShow(msg);
        if (strcmp(nm, "SyncFinished") == 0) break;
        if (strcmp(nm, "AssetManifest") == 0) {
            printf("\n  *** GOT ASSET MANIFEST!!! ***\n\n");
        }
    }

    gid = pATHostConnectionGetGrappaSessionId ? pATHostConnectionGetGrappaSessionId(conn) : -999;
    printf("\n*** Grappa session ID (final): %d ***\n", gid);

    pATHostConnectionInvalidate(conn);
    pATHostConnectionRelease(conn);
    printf("Done.\n");
    return 0;
}
