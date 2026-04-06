/*
 * Minimal native C program to test AirTrafficHost.
 * Compile: clang -o atc_native atc_native.c -framework CoreFoundation \
 *          -F/System/Library/PrivateFrameworks -framework AirTrafficHost \
 *          -framework MobileDevice
 */
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <unistd.h>
#include <signal.h>

/* AirTrafficHost function declarations */
extern void* ATHostConnectionCreateWithLibrary(CFStringRef library, CFStringRef deviceUDID, uint32_t flags);
extern void ATHostConnectionDestroy(void* conn);
extern void ATHostConnectionRelease(void* conn);
extern uint32_t ATHostConnectionGetGrappaSessionId(void* conn);
extern uint32_t ATHostConnectionGetCurrentSessionNumber(void* conn);
extern int ATHostConnectionSendHostInfo(void* conn, CFDictionaryRef hostInfo);
extern int ATHostConnectionSendPowerAssertion(void* conn, CFBooleanRef value);
extern int ATHostConnectionSendSyncRequest(void* conn, CFArrayRef dataClasses, CFDictionaryRef anchors, CFDictionaryRef options);
extern void* ATHostConnectionReadMessage(void* conn);
extern int ATHostConnectionSendMessage(void* conn, void* message);
extern int ATHostConnectionSendPing(void* conn);
extern int ATHostConnectionInvalidate(void* conn);

/* ATCFMessage */
extern void* ATCFMessageCreate(uint32_t session, CFStringRef command, CFDictionaryRef params);
extern CFStringRef ATCFMessageGetName(void* msg);
extern void* ATCFMessageGetParam(void* msg, CFStringRef key);
extern uint32_t ATCFMessageGetSessionNumber(void* msg);

/* MobileDevice functions */
extern CFArrayRef AMDCreateDeviceList(void);
extern int AMDeviceConnect(void* device);
extern int AMDeviceIsPaired(void* device);
extern int AMDeviceValidatePairing(void* device);
extern int AMDeviceStartSession(void* device);
extern int AMDeviceStopSession(void* device);
extern int AMDeviceDisconnect(void* device);
extern CFStringRef AMDeviceCopyDeviceIdentifier(void* device);
extern void* AMDeviceCopyValue(void* device, CFStringRef domain, CFStringRef key);
extern int AMDeviceGetInterfaceType(void* device);

static volatile int timed_out = 0;
static void alarm_handler(int sig) { timed_out = 1; }

int main(int argc, char** argv) {
    printf("[*] AirTrafficHost native test\n");
    printf("[*] PID: %d\n", getpid());
    fflush(stdout);

    /* Find device */
    CFArrayRef devices = AMDCreateDeviceList();
    CFIndex count = CFArrayGetCount(devices);
    printf("[+] Devices: %ld\n", count);
    if (count == 0) {
        printf("[-] No device\n");
        return 1;
    }

    void* device = (void*)CFArrayGetValueAtIndex(devices, 0);
    CFStringRef udid_cf = AMDeviceCopyDeviceIdentifier(device);
    char udid[256];
    CFStringGetCString(udid_cf, udid, sizeof(udid), kCFStringEncodingUTF8);
    printf("[+] UDID: %s\n", udid);

    /* Connect + validate */
    int e1 = AMDeviceConnect(device);
    int e2 = AMDeviceIsPaired(device);
    int e3 = AMDeviceValidatePairing(device);
    int e4 = AMDeviceStartSession(device);
    printf("[+] Connect=%d Paired=%d Validate=%d Session=%d\n", e1, e2, e3, e4);

    int iface = AMDeviceGetInterfaceType(device);
    printf("[+] InterfaceType: %d\n", iface);

    CFStringRef name_cf = AMDeviceCopyValue(device, NULL, CFSTR("DeviceName"));
    char name[256];
    if (name_cf) CFStringGetCString(name_cf, name, sizeof(name), kCFStringEncodingUTF8);
    printf("[+] Device: %s\n", name_cf ? name : "Unknown");
    fflush(stdout);

    /* Stop session before ATHostConnection (third-party tool approach) */
    AMDeviceStopSession(device);
    AMDeviceDisconnect(device);
    printf("[+] Session stopped, disconnected\n");
    fflush(stdout);

    /* Create ATHostConnection */
    printf("\n[*] Creating ATHostConnection...\n");
    fflush(stdout);

    void* conn = ATHostConnectionCreateWithLibrary(
        CFSTR("com.softorino.bigsync"),
        udid_cf,
        0
    );
    printf("[+] conn=%p\n", conn);

    uint32_t grappa = ATHostConnectionGetGrappaSessionId(conn);
    uint32_t session = ATHostConnectionGetCurrentSessionNumber(conn);
    printf("[+] grappa=%u session=%u\n", grappa, session);
    fflush(stdout);

    /* Read initial messages */
    printf("\n[*] Reading messages...\n");
    fflush(stdout);

    signal(SIGALRM, alarm_handler);

    for (int i = 0; i < 10; i++) {
        timed_out = 0;
        alarm(5);

        void* msg = ATHostConnectionReadMessage(conn);
        alarm(0);

        if (timed_out || !msg) {
            printf("  [%d] %s\n", i, timed_out ? "TIMEOUT" : "NULL");
            break;
        }

        CFStringRef msg_name = ATCFMessageGetName(msg);
        uint32_t msg_session = ATCFMessageGetSessionNumber(msg);
        char name_buf[256];
        CFStringGetCString(msg_name, name_buf, sizeof(name_buf), kCFStringEncodingUTF8);

        grappa = ATHostConnectionGetGrappaSessionId(conn);
        printf("  [%d] << %s (session=%u, grappa=%u)\n", i, name_buf, msg_session, grappa);
        fflush(stdout);

        if (strcmp(name_buf, "SyncAllowed") == 0) {
            /* Send HostInfo */
            CFMutableDictionaryRef hi = CFDictionaryCreateMutable(NULL, 0,
                &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
            CFDictionarySetValue(hi, CFSTR("HostName"), CFSTR("mediaporter"));
            CFDictionarySetValue(hi, CFSTR("HostID"), CFSTR("com.softorino.bigsync"));
            CFDictionarySetValue(hi, CFSTR("Version"), CFSTR("12.13.2.3"));

            int err = ATHostConnectionSendHostInfo(conn, hi);
            printf("  >> SendHostInfo: %d (0x%08x)\n", err, err);

            err = ATHostConnectionSendPing(conn);
            printf("  >> SendPing: %d (0x%08x)\n", err, err);
            fflush(stdout);

            CFRelease(hi);
        }
    }

    grappa = ATHostConnectionGetGrappaSessionId(conn);
    printf("\n[+] Final grappa=%u\n", grappa);
    fflush(stdout);

    ATHostConnectionInvalidate(conn);
    ATHostConnectionRelease(conn);
    printf("[+] Done\n");
    return 0;
}
