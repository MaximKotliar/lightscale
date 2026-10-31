// Test program: loads version.dll from its own folder (the proxy), calls through it,
// and checks that lsfghook.dll came along.
#include "win.h"

static void out(const char *s) {
    DWORD n = 0, len = 0;
    while (s[len]) len++;
    WriteFile(GetStdHandle(STD_OUTPUT_HANDLE), s, len, &n, 0);
}
static void num(const char *label, unsigned long long v) {
    char buf[64]; int i = 0;
    while (label[i]) { buf[i] = label[i]; i++; }
    char digits[24]; int d = 0;
    do { digits[d++] = '0' + v % 10; v /= 10; } while (v);
    while (d) buf[i++] = digits[--d];
    buf[i++] = '\n'; buf[i] = 0;
    out(buf);
}

void start(void) {
    HMODULE v = LoadLibraryW(L"version.dll");
    DWORD (WINAPI *size)(const WCHAR *, DWORD *) = (DWORD (WINAPI *)(const WCHAR *, DWORD *))GetProcAddress(v, "GetFileVersionInfoSizeW");
    DWORD handle = 0;
    num("version info size of kernel32: ", size ? size(L"C:\\windows\\system32\\kernel32.dll", &handle) : 0);
    num("lsfghook loaded: ", GetModuleHandleW(L"lsfghook.dll") != 0);
    num("proxy is first version.dll: ", GetProcAddress(v, "VerQueryValueW") != 0 && GetModuleHandleW(L"version.dll") == v);
    ExitProcess(0);
}
