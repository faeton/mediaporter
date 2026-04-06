"""
LLDB script to test Grappa inside AMPDevicesAgent.

Usage:
  lldb -n AMPDevicesAgent -o "command script import /path/to/lldb_grappa_test.py"
"""
import lldb

def grappa_test(debugger, command, result, internal_dict):
    target = debugger.GetSelectedTarget()
    process = target.GetProcess()
    thread = process.GetSelectedThread()
    frame = thread.GetSelectedFrame()

    print("=== Testing Grappa inside AMPDevicesAgent ===")

    # Get device UDID (we need one for ATHostConnectionCreateWithLibrary)
    # Use a hardcoded UDID from our device
    udid = "00008027-000641441444002E"

    # Create ATHostConnection
    expr = f'''
    (void*)ATHostConnectionCreateWithLibrary(
        (CFStringRef)@"com.mediaporter.test",
        (CFStringRef)@"{udid}",
        (unsigned int)0
    )
    '''
    val = frame.EvaluateExpression(expr)
    conn_ptr = val.GetValueAsUnsigned()
    print(f"ATHostConnectionCreateWithLibrary: {hex(conn_ptr) if conn_ptr else 'NULL'}")

    if conn_ptr == 0:
        print("Connection creation failed")
        return

    # Check Grappa session ID
    expr2 = f'(int)ATHostConnectionGetGrappaSessionId((void*){conn_ptr})'
    val2 = frame.EvaluateExpression(expr2)
    gid = val2.GetValueAsSigned()
    print(f"*** Grappa session ID (initial): {gid} ***")

    # Send HostInfo
    expr3 = f'''
    (void*)ATHostConnectionSendHostInfo((void*){conn_ptr},
        (NSDictionary*)@{{
            @"LibraryID": @"MEDIAPORTER00001",
            @"SyncHostName": @"m3max",
            @"SyncedDataclasses": @[],
            @"Version": @"12.8"
        }}
    )
    '''
    val3 = frame.EvaluateExpression(expr3)
    print(f"SendHostInfo result: {val3}")

    # Wait for framework setup
    import time
    time.sleep(3)

    # Check Grappa again
    expr4 = f'(int)ATHostConnectionGetGrappaSessionId((void*){conn_ptr})'
    val4 = frame.EvaluateExpression(expr4)
    gid2 = val4.GetValueAsSigned()
    print(f"*** Grappa session ID (after HostInfo): {gid2} ***")

    if gid2 != 0:
        print("\n*** GRAPPA WORKS INSIDE AMPDevicesAgent! ***")
        print(f"Session ID = {gid2}")
    else:
        print("\nGrappa still 0 even inside AMPDevicesAgent")

    # Cleanup
    frame.EvaluateExpression(f'(void)ATHostConnectionRelease((void*){conn_ptr})')

def __lldb_init_module(debugger, internal_dict):
    debugger.HandleCommand('command script add -f lldb_grappa_test.grappa_test grappa_test')
    print("Loaded grappa_test command. Type 'grappa_test' to run.")
    # Auto-run
    debugger.HandleCommand('grappa_test')
