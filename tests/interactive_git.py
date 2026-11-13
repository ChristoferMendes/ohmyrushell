"""Windows-only real PSReadLine test using ConPTY; no third-party packages.
Run from a fresh process after cargo build --release: python tests/interactive_git.py
"""
import ctypes as c
from ctypes import wintypes as w
import os, pathlib, re, shutil, subprocess, sys, tempfile, threading, time

if sys.platform != 'win32':
    raise SystemExit('This optional ConPTY test requires Windows 10 1809 or newer.')
os.chdir(pathlib.Path(__file__).resolve().parent.parent)

k = c.WinDLL('kernel32', use_last_error=True)
class COORD(c.Structure):
    _fields_ = [('X', c.c_short), ('Y', c.c_short)]
class SI(c.Structure):
    _fields_ = [('cb', w.DWORD), ('lpReserved', w.LPWSTR), ('lpDesktop', w.LPWSTR), ('lpTitle', w.LPWSTR), ('dwX', w.DWORD), ('dwY', w.DWORD), ('dwXSize', w.DWORD), ('dwYSize', w.DWORD), ('dwXCountChars', w.DWORD), ('dwYCountChars', w.DWORD), ('dwFillAttribute', w.DWORD), ('dwFlags', w.DWORD), ('wShowWindow', w.WORD), ('cbReserved2', w.WORD), ('lpReserved2', c.c_void_p), ('hStdInput', w.HANDLE), ('hStdOutput', w.HANDLE), ('hStdError', w.HANDLE)]
class SIX(c.Structure):
    _fields_ = [('StartupInfo', SI), ('lpAttributeList', c.c_void_p)]
class PI(c.Structure):
    _fields_ = [('hProcess', w.HANDLE), ('hThread', w.HANDLE), ('pid', w.DWORD), ('tid', w.DWORD)]
k.CreatePipe.argtypes = [c.POINTER(w.HANDLE), c.POINTER(w.HANDLE), c.c_void_p, w.DWORD]
k.CreatePseudoConsole.argtypes = [COORD, w.HANDLE, w.HANDLE, w.DWORD, c.POINTER(w.HANDLE)]
k.CloseHandle.argtypes = [w.HANDLE]
k.ClosePseudoConsole.argtypes = [w.HANDLE]
k.InitializeProcThreadAttributeList.argtypes = [c.c_void_p, w.DWORD, w.DWORD, c.POINTER(c.c_size_t)]
k.UpdateProcThreadAttribute.argtypes = [c.c_void_p, w.DWORD, c.c_size_t, c.c_void_p, c.c_size_t, c.c_void_p, c.c_void_p]
k.CreateProcessW.argtypes = [w.LPCWSTR, w.LPWSTR, c.c_void_p, c.c_void_p, w.BOOL, w.DWORD, c.c_void_p, w.LPCWSTR, c.POINTER(SIX), c.POINTER(PI)]
k.ReadFile.argtypes = [w.HANDLE, c.c_void_p, w.DWORD, c.POINTER(w.DWORD), c.c_void_p]
k.WriteFile.argtypes = [w.HANDLE, c.c_void_p, w.DWORD, c.POINTER(w.DWORD), c.c_void_p]
k.DeleteProcThreadAttributeList.argtypes = [c.c_void_p]
k.WaitForSingleObject.argtypes = [w.HANDLE, w.DWORD]
k.TerminateProcess.argtypes = [w.HANDLE, w.UINT]
def check(ok):
    if not ok: raise c.WinError(c.get_last_error())
in_r, in_w, out_r, out_w, hpc = [w.HANDLE() for _ in range(5)]
check(k.CreatePipe(c.byref(in_r), c.byref(in_w), None, 0))
check(k.CreatePipe(c.byref(out_r), c.byref(out_w), None, 0))
assert k.CreatePseudoConsole(COORD(120, 30), in_r, out_w, 0, c.byref(hpc)) == 0
k.CloseHandle(in_r); k.CloseHandle(out_w)
size = c.c_size_t()
k.InitializeProcThreadAttributeList(None, 1, 0, c.byref(size))
attributes = c.create_string_buffer(size.value)
check(k.InitializeProcThreadAttributeList(attributes, 1, 0, c.byref(size)))
check(k.UpdateProcThreadAttribute(attributes, 0, 0x20016, hpc, c.sizeof(hpc), None, None))
startup = SIX(); startup.StartupInfo.cb = c.sizeof(SIX); startup.lpAttributeList = c.cast(attributes, c.c_void_p)
process = PI()
shell = subprocess.check_output(['pwsh', '-NoLogo', '-NoProfile', '-Command', '[Environment]::ProcessPath'], text=True).strip()
# Keep the interactive regression test out of the user's command history.
command = c.create_unicode_buffer(subprocess.list2cmdline([
    shell, '-NoLogo', '-NoProfile', '-NoExit', '-Command',
    'Import-Module PSReadLine; Set-PSReadLineOption -HistorySaveStyle SaveNothing -PredictionSource None',
]))
k.GetStdHandle.argtypes = [w.DWORD]; k.GetStdHandle.restype = w.HANDLE
k.SetStdHandle.argtypes = [w.DWORD, w.HANDLE]
saved = [(n, k.GetStdHandle(n)) for n in (0xfffffff6, 0xfffffff5, 0xfffffff4)]
for n, _ in saved: k.SetStdHandle(n, None)
try:
    check(k.CreateProcessW(None, command, None, None, False, 0x80000, None, None, c.byref(startup), c.byref(process)))
finally:
    for n, handle in saved: k.SetStdHandle(n, handle)
chunks = []
def send(text):
    data = text.encode('utf-8'); written = w.DWORD()
    check(k.WriteFile(in_w, data, len(data), c.byref(written), None))
def read():
    buffer = c.create_string_buffer(65536); count = w.DWORD()
    while k.ReadFile(out_r, buffer, len(buffer), c.byref(count), None) and count.value:
        data = buffer.raw[:count.value]; chunks.append(data)
        if b'\x1b[6n' in data: send('\x1b[1;1R')
threading.Thread(target=read, daemon=True).start()
root = pathlib.Path(tempfile.mkdtemp(prefix='ohmyrushell-interactive-'))
# Count the rendered normalized path, not echoed Windows-style command paths.
# ConPTY can move to column 1 without emitting a newline after wrapped input.
pretty_root = str(root).replace('\\', '/')
home = os.environ.get('USERPROFILE', '').replace('\\', '/')
if home and pretty_root.lower().startswith(home.lower() + '/'):
    pretty_root = '~' + pretty_root[len(home):]
ansi = re.compile(r'\x1b\][^\x07]*(?:\x07)|\x1b\[[0-?]*[ -/]*[@-~]')
def output():
    return b''.join(chunks).decode('utf-8', errors='replace')
def painted_as(fragment, rgb, name):
    # ConPTY can emit a cursor move between SGR and the repainted token.
    cursor_controls = r'(?:\x1b\[[0-?]*[ -/]*[@-ln-~])*'
    return re.search(r'\x1b\[38;2;' + rgb + 'm' + cursor_controls + re.escape(name), fragment) is not None

def headers():
    plain = ansi.sub('', output())
    return re.findall(re.escape(pretty_root) + r'[^\r\n]*', plain)
def wait_for_prompt(count):
    deadline = time.monotonic() + 10
    while len(headers()) < count:
        if time.monotonic() > deadline:
            raise AssertionError('Prompt not received: ' + repr(output()))
        time.sleep(0.05)
    time.sleep(0.8)  # Enough for any erroneous background redraw to show up.
    assert len(headers()) == count, 'Duplicate prompt: ' + repr(output())
try:
    subprocess.run(['git', 'init', '-q', '-b', 'main', str(root)], check=True)
    (root / 'untracked.txt').write_text('new')
    time.sleep(2)
    module = pathlib.Path('powershell/ohmyrushell.psd1').resolve()
    # Native Git must work even when git.exe cannot be found on PATH.
    send("Import-Module '" + str(module).replace("'", "''") + "'; Set-Location '" + str(root) + "'; $savedPath=$env:PATH; $env:PATH=''\r")
    wait_for_prompt(1)
    assert 'git:(main)' in headers()[0] and '✗' in headers()[0], repr(headers())
    assert '...' not in headers()[0] and '!' not in headers()[0], 'Native Git did not finish before the first prompt'
    assert '❯' in output() and '\ue0b0' not in output(), 'Classic prompt marker missing or Powerline arrows present'
    assert '\x1b[48;' not in output(), 'Background blocks are still present'

    # Regression: clean must produce ONE fresh prompt, never dirty then clean.
    send('$env:PATH=$savedPath; git clean -fd\r')
    wait_for_prompt(2)
    assert 'git:(main)' in headers()[1] and '✗' not in headers()[1] and '...' not in headers()[1], repr(headers())

    # A new dirty state must also be reflected in the first and only header.
    (root / 'new.txt').write_text('new')
    send('Write-Output OHMYRUSHELL_EDITED\r')
    wait_for_prompt(3)
    assert '✗' in headers()[2], repr(headers())
    # A leftover old zero-ms budget must not reintroduce the loading bug.
    send("$env:OHMYRUSHELL_GIT_WAIT_MS='0'; git clean -fd\r")
    wait_for_prompt(4)
    assert 'git:(main)' in headers()[3] and '✗' not in headers()[3] and '...' not in headers()[3] and '!' not in headers()[3], repr(headers())
    send('Write-Output OHMYRUSHELL_BUFFER_PRESERVED')
    time.sleep(1)
    assert len(headers()) == 4, 'Prompt redrawn while typing'
    send('\r')
    wait_for_prompt(5)
    # Check actual terminal output, not only the resolver's return values.
    missing = 'ohmyrushell_command_that_does_not_exist'
    start = len(output())
    send(missing)
    time.sleep(0.5)
    assert painted_as(output()[start:], '243;139;168', missing), 'Missing command was not painted red: ' + repr(output()[start:])
    assert len(headers()) == 5, 'Highlighting redrew the prompt'
    send('\x03')  # Cancel, never execute the invented command.
    wait_for_prompt(6)
    start = len(output())
    send('Get-ChildItem | ' + missing)
    time.sleep(0.5)
    painted = output()[start:]
    assert painted_as(painted, '166;227;161', 'Get-ChildItem'), 'Known command was not painted green: ' + repr(painted)
    assert painted_as(painted, '243;139;168', missing), 'Pipeline command was not painted independently: ' + repr(painted)
    send('\x03')
    wait_for_prompt(7)
    send('git')
    time.sleep(0.2)
    start = len(output())
    send('x')
    time.sleep(0.3)
    assert painted_as(output()[start:], '243;139;168', 'gitx'), 'Appending to a valid name left it green: ' + repr(output()[start:])
    start = len(output())
    send('\x7f')  # Terminal Backspace: gitx -> git.
    time.sleep(0.3)
    assert painted_as(output()[start:], '166;227;161', 'git'), 'Correcting a name did not restore green: ' + repr(output()[start:])
    send('\x03')
    wait_for_prompt(8)
    send('Remove-Module ohmyrushell; Write-Output OHMYRUSHELL_REMOVED; exit\r')
    time.sleep(2)
    assert output().count('OHMYRUSHELL_BUFFER_PRESERVED') >= 2, repr(output())
    assert 'OHMYRUSHELL_REMOVED' in output(), repr(output())
    print('ConPTY test OK: one fresh Git prompt, existing commands green, missing commands red, input preserved.')
finally:
    pathlib.Path('target/interactive-output.log').write_text(output(), encoding='utf-8')
    if k.WaitForSingleObject(process.hProcess, 2000) != 0: k.TerminateProcess(process.hProcess, 1)
    k.ClosePseudoConsole(hpc)
    k.DeleteProcThreadAttributeList(attributes)
    k.CloseHandle(in_w); k.CloseHandle(out_r); k.CloseHandle(process.hProcess); k.CloseHandle(process.hThread)
    shutil.rmtree(root, ignore_errors=True)
