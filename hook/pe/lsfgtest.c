// Test program: loads lsfghook.dll and reports whether its Unix side came up.
#include "win.h"

static void out(const char *s) {
    DWORD n = 0, len = 0;
    while (s[len]) len++;
    WriteFile(GetStdHandle(STD_OUTPUT_HANDLE), s, len, &n, 0);
}

static void hex(const char *label, unsigned long long v) {
    char buf[64];
    int i = 0;
    while (label[i]) { buf[i] = label[i]; i++; }
    buf[i++] = '0'; buf[i++] = 'x';
    for (int s = 60; s >= 0; s -= 4) buf[i++] = "0123456789abcdef"[(v >> s) & 15];
    buf[i++] = '\n'; buf[i] = 0;
    out(buf);
}

void start(void) {
    // Plain name first (WINEDLLPATH / app dir), then the Wine-style layout next to us.
    HMODULE m = LoadLibraryW(L"lsfghook.dll");
    if (!m) m = LoadLibraryW(L"C:\\lsfg\\x86_64-windows\\lsfghook.dll");
    if (!m) { hex("LoadLibrary failed, error ", GetLastError()); ExitProcess(1); }
    NTSTATUS (*status)(void) = (NTSTATUS (*)(void))GetProcAddress(m, "lsfg_status");
    unsigned (*ping)(void) = (unsigned (*)(void))GetProcAddress(m, "lsfg_ping");
    hex("unixlib status ", (unsigned long)status());
    hex("ping ", ping());
    ExitProcess(0);
}
