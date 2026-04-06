// Private framework declarations for MobileDevice, AirTrafficHost, and libcig.
// These functions are loaded via dlopen/dlsym at runtime to avoid linking
// against private frameworks (better for notarization).

#pragma once

#include <CoreFoundation/CoreFoundation.h>

// ---------------------------------------------------------------------------
// MobileDevice.framework
// ---------------------------------------------------------------------------

typedef void (*AMDeviceNotificationCallback)(CFDictionaryRef info, void *context);

int AMDeviceNotificationSubscribe(
    AMDeviceNotificationCallback callback,
    unsigned int unused0,
    unsigned int unused1,
    void *context,
    void **subscription
);

CFStringRef AMDeviceCopyDeviceIdentifier(void *device);
void *AMDeviceRetain(void *device);
int AMDeviceConnect(void *device);
int AMDeviceStartSession(void *device);
int AMDeviceDisconnect(void *device);
int AMDeviceStartService(void *device, CFStringRef serviceName, void **serviceHandle, void *unknown);

// AFC
int AFCConnectionOpen(void *serviceHandle, unsigned int ioTimeout, void **afcConn);
int AFCConnectionClose(void *afcConn);
int AFCDirectoryCreate(void *afcConn, const char *path);
int AFCFileRefOpen(void *afcConn, const char *path, int mode, long *handle);
int AFCFileRefWrite(void *afcConn, long handle, const void *data, long length);
int AFCFileRefClose(void *afcConn, long handle);
int AFCRemovePath(void *afcConn, const char *path);
int AFCDirectoryOpen(void *afcConn, const char *path, void **dirHandle);
int AFCDirectoryRead(void *afcConn, void *dirHandle, char **entry);
int AFCDirectoryClose(void *afcConn, void *dirHandle);

// ---------------------------------------------------------------------------
// AirTrafficHost.framework
// ---------------------------------------------------------------------------

void *ATHostConnectionCreateWithLibrary(CFStringRef libraryID, CFStringRef udid, unsigned int flags);
void *ATHostConnectionSendHostInfo(void *conn, CFDictionaryRef hostInfo);
void *ATHostConnectionReadMessage(void *conn);
int ATHostConnectionSendMessage(void *conn, void *message);
void *ATHostConnectionSendMetadataSyncFinished(void *conn, CFDictionaryRef syncTypes, CFDictionaryRef anchors);
void *ATHostConnectionSendPowerAssertion(void *conn, CFBooleanRef value);
int ATHostConnectionInvalidate(void *conn);
void ATHostConnectionRelease(void *conn);

CFStringRef ATCFMessageGetName(void *message);
void *ATCFMessageGetParam(void *message, CFStringRef key);
void *ATCFMessageCreate(unsigned int unknown, CFStringRef name, CFDictionaryRef params);

// ---------------------------------------------------------------------------
// libcig.dylib — CIG signature engine
// ---------------------------------------------------------------------------

int cig_calc(
    const unsigned char *grappa,
    const unsigned char *data,
    int dataLen,
    unsigned char *cigOut,
    int *cigLen
);
