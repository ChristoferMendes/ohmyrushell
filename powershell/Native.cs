using System;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;

namespace OhMyRushell {
    // The assembly is independent of the release directory. Script-only updates
    // reuse it; the native library still comes from the selected immutable release.
    public static class Native {
        public static string LibraryPath { get; private set; }
        [ThreadStatic] private static byte[] buffer;

        public static void Initialize(string path) {
            lock (typeof(Native)) {
                if (LibraryPath != null) {
                    if (LibraryPath != path) throw new InvalidOperationException("ohmyrushell already loaded from another directory. Open a new session.");
                    return;
                }
                NativeLibrary.SetDllImportResolver(typeof(Native).Assembly, Resolve);
                LibraryPath = path;
            }
        }

        private static IntPtr Resolve(string name, Assembly assembly, DllImportSearchPath? searchPath) {
            return name == "ohmyrushell_core" ? NativeLibrary.Load(LibraryPath) : IntPtr.Zero;
        }

        [DllImport("ohmyrushell_core", EntryPoint = "ohmyrushell_render", CallingConvention = CallingConvention.Cdecl)]
        private static extern UIntPtr RenderNative(
            [In] byte[] path, UIntPtr pathLength, int success,
            [Out] byte[] output, UIntPtr capacity);

        [DllImport("ohmyrushell_core", EntryPoint = "ohmyrushell_revision", CallingConvention = CallingConvention.Cdecl)]
        public static extern ulong Revision();

        public static string Render(string path, bool success) {
            return Render(path, success, true);
        }

        public static string Render(string path, bool success, bool refresh) {
            byte[] input = Encoding.UTF8.GetBytes(path);
            if (buffer == null) buffer = new byte[4096];
            for (int attempt = 0; attempt < 3; attempt++) {
                ulong size = RenderNative(input, (UIntPtr)input.Length, (success ? 1 : 0) | (refresh && attempt == 0 ? 0 : 2),
                    buffer, (UIntPtr)buffer.Length).ToUInt64();
                if (size == 0 || size > 1048576) throw new InvalidOperationException("Native rendering failed.");
                if (size <= (ulong)buffer.Length) return Encoding.UTF8.GetString(buffer, 0, (int)size);
                buffer = new byte[checked((int)size + 4096)];
            }
            throw new InvalidOperationException("Native prompt exceeds its buffer.");
        }
    }
}
