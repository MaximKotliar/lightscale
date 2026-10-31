// Minimal Win32 declarations so the PE side builds without a Windows SDK or C runtime.
#pragma once
typedef void *HANDLE, *HMODULE, *LPVOID;
typedef int BOOL;
typedef unsigned long DWORD, ULONG;
typedef unsigned long long ULONG_PTR, SIZE_T;
typedef long NTSTATUS;
typedef unsigned short WCHAR;
typedef long long INT_PTR;
typedef INT_PTR (*FARPROC)(void);
#define WINAPI __stdcall
#define DLL_PROCESS_ATTACH 1
#define STD_OUTPUT_HANDLE ((DWORD)-11)
#define DECLSPEC_IMPORT __declspec(dllimport)

DECLSPEC_IMPORT HMODULE WINAPI LoadLibraryW(const WCHAR *name);
DECLSPEC_IMPORT FARPROC WINAPI GetProcAddress(HMODULE mod, const char *name);
DECLSPEC_IMPORT HANDLE WINAPI GetStdHandle(DWORD which);
DECLSPEC_IMPORT BOOL WINAPI WriteFile(HANDLE h, const void *buf, DWORD len, DWORD *written, void *ovl);
DECLSPEC_IMPORT void WINAPI ExitProcess(unsigned code);
DECLSPEC_IMPORT DWORD WINAPI GetLastError(void);
DECLSPEC_IMPORT NTSTATUS WINAPI NtQueryVirtualMemory(HANDLE process, const void *addr, int info_class,
                                                     void *buffer, SIZE_T len, SIZE_T *ret_len);
DECLSPEC_IMPORT HMODULE WINAPI GetModuleHandleW(const WCHAR *name);
