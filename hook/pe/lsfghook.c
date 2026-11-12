// PE side of the hook: a Wine "builtin" DLL that makes Wine load lsfghook.so (the native side) into
// the current process, and hooks the game's DXGI swap chain Present for the frame cap.
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

static unix_call_fn *unixDispatcher(void) {
    static unix_call_fn *dispatcher;
    if (!dispatcher) dispatcher = (unix_call_fn *)GetProcAddress(LoadLibraryW(L"ntdll.dll"), "__wine_unix_call_dispatcher");
    return dispatcher && *dispatcher ? dispatcher : 0;
}

static void logLine(const char *message) {
    unix_call_fn *dispatcher = unixDispatcher();
    if (dispatcher) (*dispatcher)(unix_handle, 3, &message);
}

#pragma mark - Frame cap: the swap chain's Present

// The frame cap waits on the game's own thread right after its Present returns (the native side's frameCapWait),
// so the game reads input for the next frame after the wait. Present is reached through COM vtables: the hook
// replaces entries in the vtables of DXGI's factory (swap chain creation) and of each swap chain it creates (Present,
// Present1). Vtables live in dxgi.dll, so nothing in the game's own code changes (FromSoft's anti-tamper checks it).

typedef long (WINAPI *QueryInterfaceFn)(void *self, const GUID *iid, void **out);
typedef unsigned long (WINAPI *ReleaseFn)(void *self);
typedef long (WINAPI *CreateFactoryFn)(const GUID *iid, void **out);
typedef long (WINAPI *CreateFactory2Fn)(unsigned flags, const GUID *iid, void **out);
typedef long (WINAPI *PresentFn)(void *self, unsigned sync, unsigned flags);
typedef long (WINAPI *Present1Fn)(void *self, unsigned sync, unsigned flags, const void *params);
typedef long (WINAPI *CreateSwapChainFn)(void *self, void *device, void *desc, void **out);
typedef long (WINAPI *CreateForHwndFn)(void *self, void *device, void *hwnd, const void *desc, const void *fullscreen,
                                       void *output, void **out);
typedef long (WINAPI *CreateForCoreWindowFn)(void *self, void *device, void *window, const void *desc, void *output, void **out);
typedef long (WINAPI *CreateForCompositionFn)(void *self, void *device, const void *desc, void *output, void **out);

// vtable slots (IUnknown, IDXGIObject, then each interface's methods in declaration order)
enum { kQueryInterface = 0, kRelease = 2, kCreateSwapChain = 10, kCreateForHwnd = 15, kCreateForCoreWindow = 16,
       kCreateForComposition = 24, kPresent = 8, kPresent1 = 22 };

// The original method for each patched vtable, per slot.
enum { kMaxTables = 16 };
typedef struct { void **vtable[kMaxTables]; void *original[kMaxTables]; volatile long count; } Originals;
static Originals origCreateSwapChain, origForHwnd, origForCoreWindow, origForComposition, origPresent, origPresent1;

static void *originalFor(Originals *o, void *self) {
    void **vtable = *(void ***)self;
    for (long i = 0; i < o->count; i++) if (o->vtable[i] == vtable) return o->original[i];
    return 0;
}

static void patch(void **vtable, int slot, void *hook, Originals *o) {
    if (vtable[slot] == hook || o->count >= kMaxTables) return;
    for (long i = 0; i < o->count; i++) if (o->vtable[i] == vtable) return;
    o->vtable[o->count] = vtable;
    o->original[o->count] = vtable[slot];
    __atomic_store_n(&o->count, o->count + 1, __ATOMIC_RELEASE);   // recorded before the hook can be called
    DWORD old;
    if (!VirtualProtect(&vtable[slot], sizeof(void *), PAGE_READWRITE, &old)) return;
    __atomic_store_n(&vtable[slot], hook, __ATOMIC_RELEASE);
    VirtualProtect(&vtable[slot], sizeof(void *), old, &old);
}

static void **vtableOf(void *object) { return *(void ***)object; }

// Calls fn for the object's interface pointer behind each IID it supports (one object can have several vtables).
static void forEachInterface(void *object, const GUID *iids, int count, void (*fn)(void *interface, int index)) {
    QueryInterfaceFn qi = (QueryInterfaceFn)vtableOf(object)[kQueryInterface];
    for (int i = 0; i < count; i++) {
        void *interface = 0;
        if (qi(object, &iids[i], &interface) != 0 || !interface) continue;
        fn(interface, i);
        ((ReleaseFn)vtableOf(interface)[kRelease])(interface);
    }
}

static const GUID swapChainIIDs[] = {
    {0x310d36a0, 0xd2e7, 0x4c0a, {0xaa, 0x04, 0x6a, 0x9d, 0x23, 0xb8, 0x88, 0x6a}},   // IDXGISwapChain
    {0x790a45f7, 0x0d42, 0x4876, {0x98, 0x3a, 0x0a, 0x55, 0xcf, 0xe6, 0xf4, 0xaa}},   // IDXGISwapChain1
    {0xa8be2ac4, 0x199f, 0x4946, {0xb3, 0x31, 0x79, 0x59, 0x9f, 0xb9, 0x8d, 0xe7}},   // IDXGISwapChain2
    {0x94d99bdb, 0xf1f8, 0x4ab0, {0xb2, 0x36, 0x7d, 0xa0, 0x17, 0x0e, 0xda, 0xb1}},   // IDXGISwapChain3
    {0x3d585d5a, 0xbd4a, 0x489e, {0xb1, 0xf4, 0x3d, 0xbc, 0xb6, 0x45, 0x2f, 0xfb}},   // IDXGISwapChain4
};
static const GUID factoryIIDs[] = {
    {0x7b7166ec, 0x21c7, 0x44ae, {0xb2, 0x1a, 0xc9, 0xae, 0x32, 0x1a, 0xe3, 0x69}},   // IDXGIFactory
    {0x770aae78, 0xf26f, 0x4dba, {0xa8, 0x29, 0x25, 0x3c, 0x83, 0xd1, 0xb3, 0x87}},   // IDXGIFactory1
    {0x50c83a1c, 0xe072, 0x4c48, {0x87, 0xb0, 0x36, 0x30, 0xfa, 0x36, 0xa6, 0xd0}},   // IDXGIFactory2
    {0x25483823, 0xcd46, 0x4c7d, {0x86, 0xca, 0x47, 0xaa, 0x95, 0xb8, 0x37, 0xbd}},   // IDXGIFactory3
    {0x1bc6ea02, 0xef36, 0x464f, {0xbf, 0x0c, 0x21, 0xca, 0x39, 0xe5, 0x16, 0x8a}},   // IDXGIFactory4
    {0x7632e1f5, 0xee65, 0x4dca, {0x87, 0xfd, 0x84, 0xcd, 0x75, 0xf8, 0x83, 0x8d}},   // IDXGIFactory5
    {0xc1b6694f, 0xff09, 0x44a9, {0xb0, 0x3c, 0x77, 0x90, 0x0a, 0x0a, 0x1d, 0x17}},   // IDXGIFactory6
    {0xa4966eed, 0x76db, 0x44da, {0x84, 0xc1, 0xee, 0x9a, 0x7a, 0xfb, 0x20, 0xa8}},   // IDXGIFactory7
};

// Present can call Present1 inside DXGI (or the other way round): only the outermost call waits.
static volatile DWORD presentingThread;

static void afterPresent(unsigned flags) {
    static int logged;
    if (flags & 1) return;   // DXGI_PRESENT_TEST: nothing is shown
    if (!logged) { logged = 1; logLine("first Present through the frame-cap hook"); }
    unix_call_fn *dispatcher = unixDispatcher();
    if (dispatcher) (*dispatcher)(unix_handle, 2, 0);
}

static long WINAPI hookPresent(void *self, unsigned sync, unsigned flags) {
    PresentFn original = (PresentFn)originalFor(&origPresent, self);
    if (!original) return 0x887A0001;   // DXGI_ERROR_INVALID_CALL; can't happen: only patched vtables reach here
    DWORD me = GetCurrentThreadId();
    int outer = presentingThread != me;
    if (outer) presentingThread = me;
    long result = original(self, sync, flags);
    if (outer) { presentingThread = 0; afterPresent(flags); }
    return result;
}

static long WINAPI hookPresent1(void *self, unsigned sync, unsigned flags, const void *params) {
    Present1Fn original = (Present1Fn)originalFor(&origPresent1, self);
    if (!original) return 0x887A0001;
    DWORD me = GetCurrentThreadId();
    int outer = presentingThread != me;
    if (outer) presentingThread = me;
    long result = original(self, sync, flags, params);
    if (outer) { presentingThread = 0; afterPresent(flags); }
    return result;
}

static void patchSwapChainInterface(void *interface, int index) {
    patch(vtableOf(interface), kPresent, (void *)hookPresent, &origPresent);
    if (index >= 1) patch(vtableOf(interface), kPresent1, (void *)hookPresent1, &origPresent1);
}

static void hookSwapChain(void *swapChain) {
    static int logged;
    if (!swapChain) return;
    forEachInterface(swapChain, swapChainIIDs, sizeof swapChainIIDs / sizeof *swapChainIIDs, patchSwapChainInterface);
    if (!logged) { logged = 1; logLine("swap chain created: Present hooked for the frame cap"); }
}

static long WINAPI hookCreateSwapChain(void *self, void *device, void *desc, void **out) {
    long result = ((CreateSwapChainFn)originalFor(&origCreateSwapChain, self))(self, device, desc, out);
    if (result >= 0 && out) hookSwapChain(*out);
    return result;
}
static long WINAPI hookCreateForHwnd(void *self, void *device, void *hwnd, const void *desc, const void *fullscreen,
                                     void *output, void **out) {
    long result = ((CreateForHwndFn)originalFor(&origForHwnd, self))(self, device, hwnd, desc, fullscreen, output, out);
    if (result >= 0 && out) hookSwapChain(*out);
    return result;
}
static long WINAPI hookCreateForCoreWindow(void *self, void *device, void *window, const void *desc, void *output, void **out) {
    long result = ((CreateForCoreWindowFn)originalFor(&origForCoreWindow, self))(self, device, window, desc, output, out);
    if (result >= 0 && out) hookSwapChain(*out);
    return result;
}
static long WINAPI hookCreateForComposition(void *self, void *device, const void *desc, void *output, void **out) {
    long result = ((CreateForCompositionFn)originalFor(&origForComposition, self))(self, device, desc, output, out);
    if (result >= 0 && out) hookSwapChain(*out);
    return result;
}

static void patchFactoryInterface(void *interface, int index) {
    void **vtable = vtableOf(interface);
    patch(vtable, kCreateSwapChain, (void *)hookCreateSwapChain, &origCreateSwapChain);
    if (index < 2) return;   // the rest arrived with IDXGIFactory2
    patch(vtable, kCreateForHwnd, (void *)hookCreateForHwnd, &origForHwnd);
    patch(vtable, kCreateForCoreWindow, (void *)hookCreateForCoreWindow, &origForCoreWindow);
    patch(vtable, kCreateForComposition, (void *)hookCreateForComposition, &origForComposition);
}

static void hookFactory(void *factory) {
    if (!factory) return;
    forEachInterface(factory, factoryIIDs, sizeof factoryIIDs / sizeof *factoryIIDs, patchFactoryInterface);
    ((ReleaseFn)vtableOf(factory)[kRelease])(factory);
}

// Runs once the loader lock is free (DXGI can't be called from DllMain). Games import dxgi.dll, or load it later
// through d3d11/d3d12 or LoadLibrary: wait for it, then make one factory of each kind and patch their vtables,
// which every factory of that kind shares, long before a game creates its swap chain.
static DWORD WINAPI hookDXGI(void *param) {
    (void)param;
    HMODULE dxgi = 0;
    for (int i = 0; i < 20 * 600 && !(dxgi = GetModuleHandleW(L"dxgi.dll")); i++) Sleep(50);
    if (!dxgi) return 0;
    CreateFactoryFn create = (CreateFactoryFn)GetProcAddress(dxgi, "CreateDXGIFactory");
    CreateFactoryFn create1 = (CreateFactoryFn)GetProcAddress(dxgi, "CreateDXGIFactory1");
    CreateFactory2Fn create2 = (CreateFactory2Fn)GetProcAddress(dxgi, "CreateDXGIFactory2");
    void *factory = 0;
    if (create && create(&factoryIIDs[0], &factory) >= 0) hookFactory(factory);
    factory = 0;
    if (create1 && create1(&factoryIIDs[1], &factory) >= 0) hookFactory(factory);
    factory = 0;
    if (create2 && create2(0, &factoryIIDs[2], &factory) >= 0) hookFactory(factory);
    logLine(origCreateSwapChain.count || origForHwnd.count ? "DXGI factory hooked for the frame cap"
                                                           : "DXGI factory not hooked: no frame cap in this game");
    return 0;
}

BOOL WINAPI DllMain(HMODULE module, DWORD reason, LPVOID reserved) {
    (void)reserved;
    if (reason == DLL_PROCESS_ATTACH) {
        unix_status = NtQueryVirtualMemory((HANDLE)-1, module, MemoryWineUnixFuncs,
                                           &unix_handle, sizeof unix_handle, 0);
        if (unix_status == 0) {
            sendExePath();
            HANDLE thread = CreateThread(0, 0, hookDXGI, 0, 0, 0);
            if (thread) CloseHandle(thread);
        }
    }
    return 1;
}
