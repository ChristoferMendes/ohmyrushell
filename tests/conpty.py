"""Small Windows ConPTY fixture. No user profiles or history are modified."""
import ctypes as c
from ctypes import wintypes as w
import os
import subprocess
import threading
import time


class COORD(c.Structure):
    _fields_ = [('X', c.c_short), ('Y', c.c_short)]


class SI(c.Structure):
    _fields_ = [('cb', w.DWORD), ('lpReserved', w.LPWSTR), ('lpDesktop', w.LPWSTR),
                ('lpTitle', w.LPWSTR), ('dwX', w.DWORD), ('dwY', w.DWORD),
                ('dwXSize', w.DWORD), ('dwYSize', w.DWORD),
                ('dwXCountChars', w.DWORD), ('dwYCountChars', w.DWORD),
                ('dwFillAttribute', w.DWORD), ('dwFlags', w.DWORD),
                ('wShowWindow', w.WORD), ('cbReserved2', w.WORD),
                ('lpReserved2', c.c_void_p), ('hStdInput', w.HANDLE),
                ('hStdOutput', w.HANDLE), ('hStdError', w.HANDLE)]


class SIX(c.Structure):
    _fields_ = [('StartupInfo', SI), ('lpAttributeList', c.c_void_p)]


class PI(c.Structure):
    _fields_ = [('hProcess', w.HANDLE), ('hThread', w.HANDLE),
                ('pid', w.DWORD), ('tid', w.DWORD)]


class Terminal:
    def __init__(self, shell, script, cwd):
        self.k = k = c.WinDLL('kernel32', use_last_error=True)
        signatures = {
            'CreatePipe': [c.POINTER(w.HANDLE), c.POINTER(w.HANDLE), c.c_void_p, w.DWORD],
            'CreatePseudoConsole': [COORD, w.HANDLE, w.HANDLE, w.DWORD, c.POINTER(w.HANDLE)],
            'CloseHandle': [w.HANDLE], 'ClosePseudoConsole': [w.HANDLE],
            'InitializeProcThreadAttributeList': [c.c_void_p, w.DWORD, w.DWORD, c.POINTER(c.c_size_t)],
            'UpdateProcThreadAttribute': [c.c_void_p, w.DWORD, c.c_size_t, c.c_void_p, c.c_size_t, c.c_void_p, c.c_void_p],
            'CreateProcessW': [w.LPCWSTR, w.LPWSTR, c.c_void_p, c.c_void_p, w.BOOL, w.DWORD, c.c_void_p, w.LPCWSTR, c.POINTER(SIX), c.POINTER(PI)],
            'ReadFile': [w.HANDLE, c.c_void_p, w.DWORD, c.POINTER(w.DWORD), c.c_void_p],
            'WriteFile': [w.HANDLE, c.c_void_p, w.DWORD, c.POINTER(w.DWORD), c.c_void_p],
            'DeleteProcThreadAttributeList': [c.c_void_p],
            'WaitForSingleObject': [w.HANDLE, w.DWORD], 'TerminateProcess': [w.HANDLE, w.UINT],
            'GetStdHandle': [w.DWORD], 'SetStdHandle': [w.DWORD, w.HANDLE],
        }
        for name, args in signatures.items():
            getattr(k, name).argtypes = args
        k.GetStdHandle.restype = w.HANDLE
        in_r, self.in_w, self.out_r, out_w, self.hpc = [w.HANDLE() for _ in range(5)]
        self.check(k.CreatePipe(c.byref(in_r), c.byref(self.in_w), None, 0))
        self.check(k.CreatePipe(c.byref(self.out_r), c.byref(out_w), None, 0))
        if k.CreatePseudoConsole(COORD(160, 40), in_r, out_w, 0, c.byref(self.hpc)) != 0:
            raise RuntimeError('CreatePseudoConsole failed')
        k.CloseHandle(in_r)
        k.CloseHandle(out_w)
        size = c.c_size_t()
        k.InitializeProcThreadAttributeList(None, 1, 0, c.byref(size))
        self.attributes = c.create_string_buffer(size.value)
        self.check(k.InitializeProcThreadAttributeList(self.attributes, 1, 0, c.byref(size)))
        self.check(k.UpdateProcThreadAttribute(self.attributes, 0, 0x20016, self.hpc, c.sizeof(self.hpc), None, None))
        startup = SIX()
        startup.StartupInfo.cb = c.sizeof(SIX)
        startup.lpAttributeList = c.cast(self.attributes, c.c_void_p)
        self.process = PI()
        command = c.create_unicode_buffer(subprocess.list2cmdline([
            shell, '-NoLogo', '-NoProfile', '-NoExit', '-Command', script,
        ]))
        saved = [(n, k.GetStdHandle(n)) for n in (0xfffffff6, 0xfffffff5, 0xfffffff4)]
        for n, _ in saved:
            k.SetStdHandle(n, None)
        self.chunks = []
        self.started = time.perf_counter()
        try:
            self.check(k.CreateProcessW(None, command, None, None, False, 0x80000,
                                       None, os.fspath(cwd), c.byref(startup), c.byref(self.process)))
        finally:
            for n, handle in saved:
                k.SetStdHandle(n, handle)
        self.reader = threading.Thread(target=self._read, daemon=True)
        self.reader.start()

    @staticmethod
    def check(ok):
        if not ok:
            raise c.WinError(c.get_last_error())

    def send(self, text):
        data = text.encode('utf-8')
        written = w.DWORD()
        self.check(self.k.WriteFile(self.in_w, data, len(data), c.byref(written), None))

    def _read(self):
        buffer = c.create_string_buffer(65536)
        count = w.DWORD()
        pending = b''
        while self.k.ReadFile(self.out_r, buffer, len(buffer), c.byref(count), None) and count.value:
            data = buffer.raw[:count.value]
            self.chunks.append(data)
            pending = (pending + data)[-65536:]
            while b'\x1b[6n' in pending:
                pending = pending.split(b'\x1b[6n', 1)[1]
                self.send('\x1b[1;1R')

    def output(self):
        return b''.join(self.chunks).decode('utf-8', errors='replace')

    def wait(self, predicate, timeout=15):
        deadline = time.perf_counter() + timeout
        while not predicate(self.output()):
            if time.perf_counter() > deadline:
                raise AssertionError('Terminal timeout: ' + repr(self.output()))
            time.sleep(0.001)
        return (time.perf_counter() - self.started) * 1000

    def close(self):
        if self.k.WaitForSingleObject(self.process.hProcess, 0) != 0:
            self.k.TerminateProcess(self.process.hProcess, 0)
            self.k.WaitForSingleObject(self.process.hProcess, 2000)
        self.k.ClosePseudoConsole(self.hpc)
        self.k.DeleteProcThreadAttributeList(self.attributes)
        for handle in (self.in_w, self.out_r, self.process.hProcess, self.process.hThread):
            self.k.CloseHandle(handle)
        self.reader.join(timeout=2)
