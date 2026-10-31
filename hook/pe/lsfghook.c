// PE side of the hook: a Wine "builtin" DLL whose only job is to make Wine load
// lsfghook.so (the native side) into the current process.
#include "win.h"

#define MemoryWineUnixFuncs 1000  // Wine-private NtQueryVirtualMemory class

static NTSTATUS unix_status = -1;
static unsigned long long unix_handle;

typedef NTSTATUS (WINAPI *unix_call_fn)(unsigned long long handle, unsigned code, void *args);

__declspec(dllexport) NTSTATUS lsfg_status(void) { return unix_status; }

__declspec(dllexport) unsigned lsfg_ping(void) {
    // ntdll exports a pointer to the Unix-call dispatcher.
    HMODULE ntdll = LoadLibraryW(L"ntdll.dll");
    unix_call_fn *dispatcher = (unix_call_fn *)GetProcAddress(ntdll, "__wine_unix_call_dispatcher");
    unsigned value = 0;
    if (!unix_handle || !dispatcher || !*dispatcher) return 0;
    (*dispatcher)(unix_handle, 0, &value);
    return value;
}

BOOL WINAPI DllMain(HMODULE module, DWORD reason, LPVOID reserved) {
    (void)reserved;
    if (reason == DLL_PROCESS_ATTACH)
        unix_status = NtQueryVirtualMemory((HANDLE)-1, module, MemoryWineUnixFuncs,
                                           &unix_handle, sizeof unix_handle, 0);
    return 1;
}
