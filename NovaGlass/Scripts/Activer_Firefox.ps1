# Recherche une vraie fenêtre Firefox et la remet au premier plan.
# Code retour 0 : fenêtre trouvée ; 1 : aucune fenêtre ; 2 : erreur.

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

try {
    Add-Type -TypeDefinition @"
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;

public static class PhosphorFirefoxWindow {
    private delegate bool EnumWindowsCallback(IntPtr window, IntPtr parameter);
    private static bool found;

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool EnumWindows(EnumWindowsCallback callback, IntPtr parameter);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool IsWindowVisible(IntPtr window);

    [DllImport("user32.dll")]
    private static extern int GetWindowTextLength(IntPtr window);

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool IsIconic(IntPtr window);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool ShowWindowAsync(IntPtr window, int command);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool BringWindowToTop(IntPtr window);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetForegroundWindow(IntPtr window);

    private static bool InspectWindow(IntPtr window, IntPtr parameter) {
        if (!IsWindowVisible(window) || GetWindowTextLength(window) <= 0) return true;
        uint processId;
        GetWindowThreadProcessId(window, out processId);
        if (processId == 0) return true;
        try {
            Process process = Process.GetProcessById((int)processId);
            bool isFirefox = String.Equals(process.ProcessName, "firefox", StringComparison.OrdinalIgnoreCase);
            process.Dispose();
            if (!isFirefox) return true;
            found = true;
            if (IsIconic(window)) ShowWindowAsync(window, 9);
            ShowWindowAsync(window, 5);
            BringWindowToTop(window);
            SetForegroundWindow(window);
            return false;
        } catch {
            return true;
        }
    }

    public static bool Activate() {
        found = false;
        EnumWindows(InspectWindow, IntPtr.Zero);
        return found;
    }
}
"@ -Language CSharp -ErrorAction Stop

    if ([PhosphorFirefoxWindow]::Activate()) { exit 0 }
    exit 1
} catch {
    exit 2
}
