"""Read the loaded ConPTY module of the private owner's terminal holder, and its file version.

The holder process owns every pseudoconsole; the server itself never loads ConPTY.
"""
import ctypes
from ctypes import wintypes as w
import hashlib
import json
from pathlib import Path
import subprocess
import sys

descriptor = Path(sys.argv[1])
owner = json.loads(descriptor.read_text(encoding="utf-8"))
kernel = ctypes.WinDLL("kernel32", use_last_error=True)
kernel.OpenProcess.argtypes = [w.DWORD, w.BOOL, w.DWORD]
kernel.OpenProcess.restype = w.HANDLE
kernel.CloseHandle.argtypes = [w.HANDLE]
kernel.K32EnumProcessModulesEx.argtypes = [w.HANDLE, ctypes.POINTER(w.HMODULE), w.DWORD, ctypes.POINTER(w.DWORD), w.DWORD]
kernel.K32GetModuleFileNameExW.argtypes = [w.HANDLE, w.HMODULE, w.LPWSTR, w.DWORD]
# A holder is started with `--socket <descriptor stem>.holder.<id>.sock`.
sockets = (str(descriptor.with_suffix("")) + ".holder.").replace("/", "\\").lower()
query = ("Get-CimInstance Win32_Process -Filter \"Name = 'gft.exe'\" | "
         "ForEach-Object { \"$($_.ProcessId)`t$($_.CommandLine)\" }")
listing = subprocess.run(["powershell", "-NoProfile", "-Command", query], capture_output=True, text=True,
                         encoding="utf-8", errors="replace", check=True).stdout
holders = [int(pid) for pid, _, command in (line.partition("\t") for line in listing.splitlines())
           if " internal holder " in command and sockets in command.replace("/", "\\").lower()]
if len(holders) != 1:
    raise SystemExit(f"Expected one terminal holder for {descriptor}, found {holders}")
process = kernel.OpenProcess(0x410, False, holders[0])
if not process:
    raise ctypes.WinError(ctypes.get_last_error())
try:
    modules = (w.HMODULE * 1024)()
    needed = w.DWORD()
    if not kernel.K32EnumProcessModulesEx(process, modules, ctypes.sizeof(modules), ctypes.byref(needed), 3):
        raise ctypes.WinError(ctypes.get_last_error())
    paths = []
    for module in modules[:needed.value // ctypes.sizeof(w.HMODULE)]:
        path = ctypes.create_unicode_buffer(32768)
        if not kernel.K32GetModuleFileNameExW(process, module, path, len(path)):
            raise ctypes.WinError(ctypes.get_last_error())
        paths.append(Path(path.value))
finally:
    kernel.CloseHandle(process)
conpty = next((p for p in paths if p.name.lower() == "conpty.dll"), None)
if conpty is None:
    raise SystemExit("The private server's terminal holder has not loaded bundled conpty.dll")
version = ctypes.WinDLL("version", use_last_error=True)
version.GetFileVersionInfoSizeW.argtypes = [w.LPCWSTR, ctypes.POINTER(w.DWORD)]
version.GetFileVersionInfoW.argtypes = [w.LPCWSTR, w.DWORD, w.DWORD, ctypes.c_void_p]
version.VerQueryValueW.argtypes = [ctypes.c_void_p, w.LPCWSTR, ctypes.POINTER(ctypes.c_void_p), ctypes.POINTER(w.UINT)]
ignored = w.DWORD()
size = version.GetFileVersionInfoSizeW(str(conpty), ctypes.byref(ignored))
data = ctypes.create_string_buffer(size)
if not size or not version.GetFileVersionInfoW(str(conpty), 0, size, data):
    raise ctypes.WinError(ctypes.get_last_error())
fixed = ctypes.c_void_p()
length = w.UINT()
if not version.VerQueryValueW(data, "\\", ctypes.byref(fixed), ctypes.byref(length)):
    raise ctypes.WinError(ctypes.get_last_error())
words = ctypes.cast(fixed, ctypes.POINTER(w.DWORD))
file_version = [words[2] >> 16, words[2] & 0xffff, words[3] >> 16, words[3] & 0xffff]
result = {"server_pid": owner["pid"], "holder_pid": holders[0], "descriptor": str(descriptor), "loaded_conpty": str(conpty),
          "file_version": file_version, "conpty_sha256": hashlib.sha256(conpty.read_bytes()).hexdigest(),
          "openconsole_sha256": hashlib.sha256(conpty.with_name("OpenConsole.exe").read_bytes()).hexdigest()}
Path(sys.argv[2]).write_text(json.dumps(result, indent=2), encoding="utf-8")
print(json.dumps(result))
