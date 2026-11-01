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

// Tells the native side where the running .exe is (as a Unix path), so it can find the game
// folder's .lsfg/profile.json. Under CrossOver the native process only sees a temporary loader.
typedef char *(WINAPI *unix_name_fn)(const WCHAR *dos);
static void sendExePath(void) {
    HMODULE ntdll = LoadLibraryW(L"ntdll.dll"), kernel32 = GetModuleHandleW(L"kernel32.dll");
    unix_call_fn *dispatcher = (unix_call_fn *)GetProcAddress(ntdll, "__wine_unix_call_dispatcher");
    unix_name_fn unixName = (unix_name_fn)GetProcAddress(kernel32, "wine_get_unix_file_name");
    if (!dispatcher || !*dispatcher || !unixName) return;
    WCHAR exe[1024];
    DWORD n = GetModuleFileNameW(0, exe, 1024);
    if (n == 0 || n >= 1024) return;
    char *path = unixName(exe);
    if (!path) return;
    (*dispatcher)(unix_handle, 1, &path);
    HeapFree(GetProcessHeap(), 0, path);
}

BOOL WINAPI DllMain(HMODULE module, DWORD reason, LPVOID reserved) {
    (void)reserved;
    if (reason == DLL_PROCESS_ATTACH) {
        unix_status = NtQueryVirtualMemory((HANDLE)-1, module, MemoryWineUnixFuncs,
                                           &unix_handle, sizeof unix_handle, 0);
        if (unix_status == 0) sendExePath();
    }
    return 1;
}
