"""Windows real-terminal startup benchmark, with all features enabled.

python tests/benchmark-startup.py --iterations 10 --output target/startup.json
--module can point at an installed or baseline manifest. Profiles/history untouched.
First prompt AND first accepted input are measured (not just Import-Module).
Numbers include process startup; do not imply a universal latency guarantee.
"""
import argparse
import json
import math
import pathlib
import re
import statistics
import subprocess
import sys
import tempfile

if sys.platform != 'win32':
    raise SystemExit('ConPTY requires Windows 10 1809+; use benchmark-git.ps1 elsewhere.')
from conpty import Terminal

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--iterations', type=int, default=10)
parser.add_argument('--module', type=pathlib.Path,
                    default=pathlib.Path(__file__).resolve().parent.parent / 'powershell/ohmyrushell.psd1')
parser.add_argument('--baseline-module', type=pathlib.Path,
                    help='Also measure an older manifest in the same alternating run')
parser.add_argument('--output', type=pathlib.Path)
args = parser.parse_args()
if args.iterations < 1:
    parser.error('--iterations must be positive')
shell = subprocess.check_output(['pwsh', '-NoLogo', '-NoProfile', '-Command',
                                 '[Environment]::ProcessPath'], text=True).strip()
ansi = re.compile(r'\x1b\][^\x07]*(?:\x07)|\x1b\[[0-?]*[ -/]*[@-~]')
modules = {'native': None}
if args.baseline_module:
    modules['baseline'] = str(args.baseline_module.resolve()).replace("'", "''")
modules['ohmyrushell'] = str(args.module.resolve()).replace("'", "''")
results = {mode: [] for mode in modules}
first_runs = {}
# Empty non-repository directory: do not confuse startup costs with Git traversal
# of this worktree or with the user's profiles/external tools.
with tempfile.TemporaryDirectory(prefix='ohmyrushell-startup-') as cwd:
    for iteration in range(args.iterations + 1):
        # Alternate the order to reduce systematic warm-disk/order bias.
        modes = list(results) if iteration % 2 == 0 else list(reversed(results))
        for mode in modes:
            script = "$ErrorActionPreference='Stop'; Import-Module PSReadLine; Set-PSReadLineOption -HistorySaveStyle SaveNothing -PredictionSource None; "
            if modules[mode]:
                script += f"Import-Module '{modules[mode]}'; "
            terminal = Terminal(shell, script, cwd)
            try:
                first = terminal.wait(lambda text: bool(re.search(
                    r'(?:❯|PS [^\r\n]*>)', ansi.sub('', text))))
                terminal.send("'BENCH_'+'REPLY'\r")
                accepted = terminal.wait(lambda text: 'BENCH_REPLY' in ansi.sub('', text))
                indexed = accepted
                if modules[mode]:
                    terminal.send("[Console]::WriteLine('CHECK_'+([OhMyRushell.CommandHighlighting]::WaitForIndex(5000)));\r")
                    indexed = terminal.wait(lambda text: 'CHECK_True' in ansi.sub('', text))
                row = {'prompt_ms': round(first, 2), 'input_ms': round(accepted, 2),
                       'index_check_ms': round(indexed, 2)}
                if iteration:
                    results[mode].append(row)
                else:
                    first_runs[mode] = row
                print(f'{mode:12} {"warmup" if not iteration else iteration}: {row}', flush=True)
            finally:
                terminal.close()
summary = {}
for mode, rows in results.items():
    summary[mode] = {}
    for key in ('prompt_ms', 'input_ms', 'index_check_ms'):
        values = sorted(row[key] for row in rows)
        summary[mode][key] = {'median': round(statistics.median(values), 2),
                              'p95': values[math.ceil(len(values) * .95) - 1]}
report = {'modules': modules, 'iterations': args.iterations, 'first_runs': first_runs,
          'summary': summary, 'samples': results}
print(json.dumps(summary, indent=2))
if args.output:
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2), encoding='utf-8')
