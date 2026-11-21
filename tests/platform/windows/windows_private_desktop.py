"""Run an owned child on a private Windows window station (separate clipboard)."""
import ctypes as c
from ctypes import wintypes as w
import msvcrt
import os
from pathlib import Path
import subprocess
import uuid


class STARTUPINFO(c.Structure):
    _fields_ = [('cb', w.DWORD), ('lpReserved', w.LPWSTR), ('lpDesktop', w.LPWSTR),
                ('lpTitle', w.LPWSTR), ('dwX', w.DWORD), ('dwY', w.DWORD),
                ('dwXSize', w.DWORD), ('dwYSize', w.DWORD), ('dwXCountChars', w.DWORD),
                ('dwYCountChars', w.DWORD), ('dwFillAttribute', w.DWORD), ('dwFlags', w.DWORD),
                ('wShowWindow', w.WORD), ('cbReserved2', w.WORD), ('lpReserved2', c.POINTER(c.c_byte)),
                ('hStdInput', w.HANDLE), ('hStdOutput', w.HANDLE), ('hStdError', w.HANDLE)]


class PROCESS_INFORMATION(c.Structure):
    _fields_ = [('hProcess', w.HANDLE), ('hThread', w.HANDLE), ('dwProcessId', w.DWORD), ('dwThreadId', w.DWORD)]


def run(command, *, env, cwd, log: Path, timeout=90):
    """No fallback to the interactive station; isolation failure aborts the run."""
    if os.name != 'nt':
        raise RuntimeError('Private Windows desktop required')
    user = c.WinDLL('user32', use_last_error=True)
    kernel = c.WinDLL('kernel32', use_last_error=True)
    user.GetProcessWindowStation.restype = w.HANDLE
    user.CreateWindowStationW.argtypes = [w.LPCWSTR, w.DWORD, w.DWORD, w.LPVOID]
    user.CreateWindowStationW.restype = w.HANDLE
    user.SetProcessWindowStation.argtypes = [w.HANDLE]
    user.CreateDesktopW.argtypes = [w.LPCWSTR, w.LPCWSTR, w.LPVOID, w.DWORD, w.DWORD, w.LPVOID]
    user.CreateDesktopW.restype = w.HANDLE
    user.CloseDesktop.argtypes = [w.HANDLE]
    user.CloseWindowStation.argtypes = [w.HANDLE]
    kernel.CreateProcessW.argtypes = [w.LPCWSTR, w.LPWSTR, w.LPVOID, w.LPVOID, w.BOOL,
                                     w.DWORD, w.LPVOID, w.LPCWSTR, c.POINTER(STARTUPINFO), c.POINTER(PROCESS_INFORMATION)]
    kernel.CloseHandle.argtypes = [w.HANDLE]
    kernel.WaitForSingleObject.argtypes = [w.HANDLE, w.DWORD]
    kernel.GetExitCodeProcess.argtypes = [w.HANDLE, c.POINTER(w.DWORD)]
    kernel.TerminateProcess.argtypes = [w.HANDLE, w.UINT]

    def checked(result, operation='Windows API'):
        if not result:
            raise OSError(f'{operation}: {c.WinError(c.get_last_error())}')
        return result

    name = 'GraffittyPrivate-' + uuid.uuid4().hex
    original = checked(user.GetProcessWindowStation(), 'GetProcessWindowStation')
    station = checked(user.CreateWindowStationW(name, 0, 0xf037f, None), 'CreateWindowStationW')
    desktop = None
    process = PROCESS_INFORMATION()
    try:
        checked(user.SetProcessWindowStation(station), 'SetProcessWindowStation(private)')
        try:
            desktop = checked(user.CreateDesktopW('Fixture', None, None, 0, 0xf01ff, None), 'CreateDesktopW')
        finally:
            checked(user.SetProcessWindowStation(original), 'SetProcessWindowStation(restore)')
        with open(log, 'wb') as output, open(os.devnull, 'rb') as stdin:
            for stream in (output, stdin):
                os.set_inheritable(stream.fileno(), True)
            startup = STARTUPINFO()
            startup.cb = c.sizeof(startup)
            startup.lpDesktop = name + '\\Fixture'
            startup.dwFlags = 0x100 | 1
            startup.wShowWindow = 0
            startup.hStdInput = msvcrt.get_osfhandle(stdin.fileno())
            startup.hStdOutput = startup.hStdError = msvcrt.get_osfhandle(output.fileno())
            environment = c.create_unicode_buffer('\0'.join(f'{key}={value}' for key, value in sorted(env.items())) + '\0\0')
            argv = c.create_unicode_buffer(subprocess.list2cmdline([str(part) for part in command]))
            checked(kernel.CreateProcessW(None, argv, None, None, True, 0x400,
                                           environment, str(cwd), c.byref(startup), c.byref(process)), 'CreateProcessW(private desktop)')
            wait = kernel.WaitForSingleObject(process.hProcess, int(timeout * 1000))
            if wait == 258:
                kernel.TerminateProcess(process.hProcess, 1)
                kernel.WaitForSingleObject(process.hProcess, 5000)
                raise subprocess.TimeoutExpired(command, timeout)
            if wait != 0:
                raise c.WinError(c.get_last_error())
            code = w.DWORD()
            checked(kernel.GetExitCodeProcess(process.hProcess, c.byref(code)))
            return {'exit_code': code.value, 'pid': process.dwProcessId,
                    'window_station': name, 'desktop': 'Fixture', 'private_clipboard': True,
                    'elevated': bool(c.WinDLL('shell32').IsUserAnAdmin())}
    finally:
        for handle in (process.hThread, process.hProcess):
            if handle:
                kernel.CloseHandle(handle)
        if desktop:
            user.CloseDesktop(desktop)
        user.CloseWindowStation(station)
