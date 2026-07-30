using System;
using Microsoft.Win32;

namespace Segmenter.Services
{
    public static class GpuDetector
    {
        public static bool IsGpuAvailable => true; // Always available on Windows 11 via DirectX/DirectML

        public static string GpuName
        {
            get
            {
                try
                {
                    // Scan Registry for primary display adapter driver description
                    using var key = Registry.LocalMachine.OpenSubKey(@"SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}\0000");
                    if (key != null)
                    {
                        var val = key.GetValue("DriverDesc");
                        if (val != null)
                        {
                            return val.ToString() ?? "DirectX Compatible GPU";
                        }
                    }
                }
                catch { }

                return "DirectX Display Adapter";
            }
        }

        public static string GpuBackend => "DirectX / SIMD";
    }
}
