using System;
using System.Windows;
using Segmenter.Services;

namespace Segmenter
{
    public partial class App : Application
    {
        [System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool AttachConsole(int dwProcessId);

        protected override void OnStartup(StartupEventArgs e)
        {
            base.OnStartup(e);

            if (AttachConsole(-1))
            {
                var writer = new System.IO.StreamWriter(Console.OpenStandardOutput()) { AutoFlush = true };
                Console.SetOut(writer);
                Console.SetError(writer);
                Log.Write("");
                Log.Write("[DEBUG] Segmenter attached to parent console. Ready for logs!");
            }
            
            // Set up unhandled exception handlers for debugging
            AppDomain.CurrentDomain.UnhandledException += (s, ex) =>
            {
                Log.Write($"[FATAL ERROR] {ex.ExceptionObject}");
                MessageBox.Show($"Fatal error: {ex.ExceptionObject}", "Segmenter Error", MessageBoxButton.OK, MessageBoxImage.Error);
            };
            // Initialize Discord Rich Presence (silently fails if Discord is not running)
            DiscordRpcService.Initialize();
        }

        protected override void OnExit(ExitEventArgs e)
        {
            DiscordRpcService.Dispose();
            base.OnExit(e);
        }
    }

    public static class Log
    {
        public static void Write(string message)
        {
            try
            {
                Console.WriteLine(message);
            }
            catch
            {
                // Silently ignore any console handle issues on transitions (Alt-Tab, lost focus, etc.)
            }
        }
    }
}
