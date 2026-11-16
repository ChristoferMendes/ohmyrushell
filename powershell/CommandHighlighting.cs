using System;
using System.Collections;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Management.Automation;
using System.Management.Automation.Language;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.PowerShell;

namespace OhMyRushell {
    public enum CommandValidity { Pending, Valid, Invalid }
    public sealed class CommandMark {
        public string Name;
        public string Text;
        public int Start;
        public CommandValidity Validity;
    }

    // Only public PSReadLine APIs are used. The input buffer and prompt are
    // never redrawn/replaced: we repaint command-name spans after built-in edits.
    public static class CommandHighlighting {
        public const string Neutral = "\x1b[38;2;205;214;244m";
        public const string Green = "\x1b[38;2;166;227;161m";
        public const string Red = "\x1b[38;2;243;139;168m";
        private const string BindingName = "OhMyRushellHighlight";
        private static readonly bool Windows = OperatingSystem.IsWindows();
        private static readonly StringComparer ExternalComparer = Windows ? StringComparer.OrdinalIgnoreCase : StringComparer.Ordinal;
        private static HashSet<string> session = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        private static HashSet<string> available = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        private static HashSet<string> external = new HashSet<string>(ExternalComparer);
        private static volatile bool availableReady;
        private static readonly object availableLock = new object();
        private static int availableGeneration;
        private static Task availableTask = Task.CompletedTask;
        private static volatile bool indexReady;
        private static string signature;
        private static string cwd = ".";
        private static string[] extensions = new[] { ".exe", ".com", ".cmd", ".bat", ".ps1" };
        private static int indexGeneration;
        private static readonly object indexLock = new object();
        private static Task indexTask = Task.CompletedTask;
        private static DateTime indexTime;
        private static ConcurrentDictionary<string, CommandValidity> paths = new ConcurrentDictionary<string, CommandValidity>(ExternalComparer);

        private sealed class Binding {
            public string Key, Function, Description;
            public Action<ConsoleKeyInfo?, object> Original;
        }
        private static readonly List<Binding> bindings = new List<Binding>();
        private static Hashtable originalColors;

        public static void EnableColors() {
            if (originalColors != null) return;
            var options = PSConsoleReadLine.GetOptions();
            var saved = new Hashtable {
                { "Command", options.CommandColor }, { "Parameter", options.ParameterColor },
                { "String", options.StringColor }, { "Variable", options.VariableColor },
                { "Number", options.NumberColor }, { "Operator", options.OperatorColor },
                { "Comment", options.CommentColor }, { "Keyword", options.KeywordColor },
                { "Error", options.ErrorColor }, { "ContinuationPrompt", options.ContinuationPromptColor }
            };
            // Public PSReadLine API, identical neutral baseline and palette.
            PSConsoleReadLine.SetOptions(new SetPSReadLineOption { Colors = new Hashtable {
                { "Command", "#cdd6f4" }, { "Parameter", "#89b4fa" }, { "String", "#f9e2af" },
                { "Variable", "#cba6f7" }, { "Number", "#fab387" }, { "Operator", "#89dceb" },
                { "Comment", "#6c7086" }, { "Keyword", "#cba6f7" }, { "Error", "#f38ba8" },
                { "ContinuationPrompt", "#6c7086" }
            }});
            originalColors = saved;
        }

        public static void RestoreColors() {
            if (originalColors == null) return;
            PSConsoleReadLine.SetOptions(new SetPSReadLineOption { Colors = originalColors });
            originalColors = null;
        }

        private static HashSet<string> Names(IEnumerable<CommandInfo> commands, bool moduleOnly) {
            var names = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (var command in commands) {
                if (moduleOnly && (command.Module == null || String.IsNullOrEmpty(command.Module.Path))) continue;
                // An unloaded module's metadata can have no ExportedFunctions
                // dictionary yet. Get-Command already limits that metadata to
                // exports; filter private functions only for a loaded module.
                if (command is FunctionInfo && command.Module != null && command.Module.SessionState != null && !command.Module.ExportedFunctions.ContainsKey(command.Name)) continue;
                if (command is AliasInfo alias) {
                    try { if (alias.ResolvedCommand == null) continue; } catch { continue; }
                }
                names.Add(command.Name);
                if (!String.IsNullOrEmpty(command.ModuleName)) names.Add(command.ModuleName + "\\" + command.Name);
            }
            return names;
        }

        public static void SetAvailableCommands(CommandInfo[] commands) {
            var names = Names(commands, true);
            lock (availableLock) {
                ++availableGeneration; // Manual refresh wins over older background work.
                Volatile.Write(ref available, names);
                availableReady = true;
            }
        }

        public static void StartAvailableDiscovery() {
            lock (availableLock) {
                if (availableReady || !availableTask.IsCompleted) return;
                int generation = ++availableGeneration;
                availableTask = Task.Run(() => {
                    try {
                        // Own runspace, public APIs, metadata discovery only. Never
                        // evaluate input or access the interactive runspace here.
                        using (var shell = PowerShell.Create(System.Management.Automation.Runspaces.InitialSessionState.CreateDefault2())) {
                            shell.AddCommand("Get-Command")
                                .AddParameter("CommandType", CommandTypes.Cmdlet | CommandTypes.Function | CommandTypes.Filter)
                                .AddParameter("All")
                                .AddParameter("ErrorAction", ActionPreference.SilentlyContinue);
                            var names = Names(shell.Invoke<CommandInfo>().ToArray(), true);
                            lock (availableLock) {
                                if (generation != availableGeneration) return;
                                Volatile.Write(ref available, names);
                                availableReady = true;
                            }
                        }
                    } catch {
                        // Discovery failure is unknown, not proof of absence.
                        // Explicit Update-OhMyRushellCommandCache can recover.
                    }
                });
            }
        }

        public static void UpdateSession(EngineIntrinsics context) {
            // Same live session lookup as Get-Command -ListImported, without a
            // PowerShell pipeline, array conversion or per-item PSObject wrapping.
            UpdateSession(context.InvokeCommand.GetCommands("*",
                CommandTypes.Alias | CommandTypes.Function | CommandTypes.Filter | CommandTypes.Cmdlet, true),
                context.SessionState.Path.CurrentFileSystemLocation.ProviderPath,
                Environment.GetEnvironmentVariable("PATH"), Environment.GetEnvironmentVariable("PATHEXT"));
        }

        public static void UpdateSession(IEnumerable<CommandInfo> commands, string directory, string path, string pathExt) {
            Volatile.Write(ref session, Names(commands, false));
            cwd = directory;
            var dirs = (path ?? "").Split(Path.PathSeparator).Where(p => !String.IsNullOrWhiteSpace(p)).Select(p => {
                try { return Path.GetFullPath(p.Trim('"'), directory); } catch { return ""; }
            }).Where(p => p.Length > 0).Distinct(ExternalComparer).ToArray();
            var exts = ((pathExt ?? ".COM;.EXE;.BAT;.CMD") + ";.ps1").Split(';').Where(e => e.Length > 0).Distinct(StringComparer.OrdinalIgnoreCase).ToArray();
            string next = String.Join("\0", dirs) + "\0" + String.Join(";", exts);
            lock (indexLock) {
                if (next == signature && DateTime.UtcNow - indexTime < TimeSpan.FromSeconds(30)) return;
                signature = next;
                extensions = exts;
                Volatile.Write(ref paths, new ConcurrentDictionary<string, CommandValidity>(ExternalComparer));
                indexReady = false;
                indexTime = DateTime.UtcNow;
                int generation = ++indexGeneration;
                indexTask = Task.Run(() => {
                    var names = new HashSet<string>(ExternalComparer);
                    foreach (string dir in dirs) {
                        try {
                            foreach (string file in Directory.EnumerateFiles(dir)) {
                                string ext = Path.GetExtension(file);
                                if (Windows) {
                                    if (!exts.Contains(ext, StringComparer.OrdinalIgnoreCase)) continue;
                                } else if (!IsExecutable(file)) continue;
                                names.Add(Path.GetFileName(file));
                                if (Windows) names.Add(Path.GetFileNameWithoutExtension(file));
                            }
                        } catch (IOException) { } catch (UnauthorizedAccessException) { } catch (System.Security.SecurityException) { }
                    }
                    lock (indexLock) {
                        if (generation != indexGeneration) return;
                        Volatile.Write(ref external, names);
                        indexReady = true;
                    }
                });
            }
        }

        [DllImport("libc", EntryPoint = "access", SetLastError = true)]
        private static extern int UnixAccess(string path, int mode);
        private static readonly MethodInfo UnixMode = typeof(File).GetMethod("GetUnixFileMode", new[] { typeof(string) });
        private static bool IsExecutable(string path) {
            if (Windows) return extensions.Contains(Path.GetExtension(path), StringComparer.OrdinalIgnoreCase);
            try {
                if (UnixMode != null) return (Convert.ToInt32(UnixMode.Invoke(null, new object[] { path })) & 0x49) != 0;
                return UnixAccess(path, 1) == 0; // .NET 6 fallback: X_OK, never execute the file.
            } catch { return false; }
        }

        public static void InvalidatePathIndex() { lock (indexLock) { signature = null; } }

        public static bool WaitForIndex(int milliseconds) {
            try {
                return Task.WaitAll(new[] { indexTask, availableTask }, milliseconds) && indexReady && availableReady;
            } catch { return false; }
        }

        public static CommandValidity Classify(string name) {
            if (String.IsNullOrEmpty(name)) return CommandValidity.Pending;
            if (Volatile.Read(ref session).Contains(name) || Volatile.Read(ref available).Contains(name)) return CommandValidity.Valid;
            if (name.IndexOfAny(new[] { '/', '\\', ':' }) >= 0) {
                string directory = cwd;
                string key = directory + "\0" + name;
                var cache = Volatile.Read(ref paths);
                var exts = extensions;
                if (cache.TryGetValue(key, out var cached)) return cached;
                if (cache.Count > 512) cache.Clear();
                if (cache.TryAdd(key, CommandValidity.Pending)) Task.Run(() => {
                    bool found = false;
                    try {
                        string candidate = Path.GetFullPath(name, directory);
                        found = File.Exists(candidate) && (Path.GetExtension(candidate).Equals(".ps1", StringComparison.OrdinalIgnoreCase) || IsExecutable(candidate));
                        if (!found && Windows && !Path.HasExtension(candidate)) {
                            found = exts.Any(ext => File.Exists(candidate + ext));
                        }
                    } catch (Exception error) when (error is IOException || error is ArgumentException || error is UnauthorizedAccessException || error is NotSupportedException) { }
                    cache[key] = found ? CommandValidity.Valid : CommandValidity.Invalid;
                });
                return CommandValidity.Pending;
            }
            // A rebuilding PATH index is unknown, not proof that a command exists.
            if (indexReady && Volatile.Read(ref external).Contains(name)) return CommandValidity.Valid;
            if (!indexReady || !availableReady) return CommandValidity.Pending;
            return CommandValidity.Invalid;
        }

        private static CommandMark[] AnalyzeAst(Ast ast) {
            var marks = new List<CommandMark>();
            foreach (CommandAst command in ast.FindAll(a => a is CommandAst, true)) {
                string name = command.GetCommandName();
                if (name == null || command.CommandElements.Count == 0) continue; // Dynamic invocation remains neutral.
                var extent = command.CommandElements[0].Extent;
                if (extent.Text.Any(Char.IsControl)) continue;
                marks.Add(new CommandMark { Name = name, Text = extent.Text, Start = extent.StartOffset, Validity = Classify(name) });
            }
            return marks.ToArray();
        }

        public static CommandMark[] Analyze(string text) {
            Token[] tokens; ParseError[] errors;
            return AnalyzeAst(Parser.ParseInput(text, out tokens, out errors));
        }

        public static void Paint() {
            int cursor = 0;
            bool restore = false;
            try {
                int selectionStart, selectionLength;
                PSConsoleReadLine.GetSelectionState(out selectionStart, out selectionLength);
                if (selectionLength > 0) return;
                Ast ast; Token[] tokens; ParseError[] errors;
                PSConsoleReadLine.GetBufferState(out ast, out tokens, out errors, out cursor);
                if (errors.Length != 0) return; // Keep PSReadLine's syntax-error rendering intact.
                var marks = AnalyzeAst(ast);
                restore = true;
                foreach (var mark in marks) {
                    PSConsoleReadLine.SetCursorPosition(mark.Start);
                    // PSReadLine tracks the cursor position independently of
                    // Console.Write. Restore the physical cursor before asking
                    // it to move again, or each repaint drifts across the line.
                    Console.Write("\x1b[s" + (mark.Validity == CommandValidity.Valid ? Green : mark.Validity == CommandValidity.Invalid ? Red : Neutral) + mark.Text + "\x1b[0m\x1b[u");
                }
            } catch { /* A highlighter must never break editing or run user code. */ }
            finally {
                if (restore) { try { PSConsoleReadLine.SetCursorPosition(cursor); } catch { } }
            }
        }

        public static int InstallBindings() {
            if (bindings.Count > 0) return bindings.Count;
            if (PSConsoleReadLine.GetOptions().EditMode.ToString() == "Vi") return 0;
            var allowed = new HashSet<string>(new[] {
                "SelfInsert", "BackwardDeleteChar", "DeleteChar", "BackwardKillWord", "KillWord", "BackwardDeleteInput",
                "BackwardDeleteLine", "ForwardDeleteInput", "ForwardDeleteLine", "KillLine", "BackwardKillLine",
                "PreviousHistory", "NextHistory", "HistorySearchBackward", "HistorySearchForward", "BeginningOfHistory", "EndOfHistory",
                "Complete", "MenuComplete", "TabCompleteNext", "TabCompletePrevious", "Paste", "Yank", "Undo", "Redo", "RevertLine",
                "ForwardChar", "BackwardChar", "ForwardWord", "BackwardWord", "BeginningOfLine", "EndOfLine", "AcceptSuggestion", "AcceptNextSuggestionWord"
            });
            var keys = new HashSet<string>(StringComparer.Ordinal);
            for (int ch = 32; ch <= 126; ch++) keys.Add(((char)ch).ToString());
            foreach (var handler in PSConsoleReadLine.GetKeyHandlers(true, false)) if (allowed.Contains(handler.Function)) keys.Add(handler.Key);
            var actions = new Dictionary<string, Action<ConsoleKeyInfo?, object>>(StringComparer.Ordinal);
            foreach (string key in keys) {
                try {
                    var previous = PSConsoleReadLine.GetKeyHandlers(new[] { key }).FirstOrDefault();
                    string function = previous == null ? "SelfInsert" : previous.Function;
                    if (!allowed.Contains(function)) continue; // Never replace a user's custom handler.
                    if (!actions.TryGetValue(function, out var action)) {
                        MethodInfo method = typeof(PSConsoleReadLine).GetMethod(function, new[] { typeof(ConsoleKeyInfo?), typeof(object) });
                        if (method == null) continue;
                        action = (Action<ConsoleKeyInfo?, object>)Delegate.CreateDelegate(typeof(Action<ConsoleKeyInfo?, object>), method);
                        actions[function] = action;
                    }
                    var binding = new Binding { Key = key, Function = previous == null ? null : function, Description = previous == null ? null : previous.Description, Original = action };
                    PSConsoleReadLine.SetKeyHandler(new[] { key }, (pressed, arg) => { action(pressed, arg); Paint(); }, BindingName, "Highlight existing commands without running them.");
                    bindings.Add(binding);
                } catch (ArgumentException) { }
            }
            return bindings.Count;
        }

        public static void RemoveBindings() {
            foreach (var binding in bindings) {
                var current = PSConsoleReadLine.GetKeyHandlers(new[] { binding.Key }).FirstOrDefault();
                if (current == null || current.Function != BindingName) continue;
                if (binding.Function == null) PSConsoleReadLine.RemoveKeyHandler(new[] { binding.Key });
                else PSConsoleReadLine.SetKeyHandler(new[] { binding.Key }, binding.Original, binding.Function, binding.Description);
            }
            bindings.Clear();
        }
    }
}
