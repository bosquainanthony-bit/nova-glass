using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Threading;
using Microsoft.Web.WebView2.Core;

namespace NovaGlass;

public partial class MainWindow : Window
{
    private readonly string[] _apps =
    {
        @"C:\Program Files\WindowsApps\Microsoft.OutlookForWindows_1.2026.811.200_x64__8wekyb3d8bbwe\olk.exe",
        @"C:\Users\bosqu\Desktop\Firefox.exe",
        @"C:\Program Files\Kodi\kodi.exe",
        @"C:\Users\bosqu\Desktop\Spotify.lnk",
        @"C:\Users\Public\Desktop\Steam.lnk",
        @"C:\Windows\explorer.exe",
        @"C:\Users\Public\Desktop\calibre 64bit - E-book management.lnk"
    };

    private readonly DispatcherTimer _pollTimer = new() { Interval = TimeSpan.FromMilliseconds(500) };
    private readonly string _sessionRoot;
    private readonly string _statePath;
    private readonly string _commandPath;
    private readonly string _stopPath;
    private readonly string _heartbeatPath;
    private readonly string _errorPath;
    private readonly string _levelPath;
    private Process? _bridge;
    private DateTime _lastHeartbeat = DateTime.MinValue;
    private DateTime _lastBridgeAttempt = DateTime.MinValue;
    private long _lastStateStamp;
    private long _lastLevelStamp;
    private bool _isFullscreen = true;

    public MainWindow()
    {
        InitializeComponent();
        _sessionRoot = Path.Combine(Path.GetTempPath(), "NovaGlass", Environment.ProcessId.ToString());
        _statePath = Path.Combine(_sessionRoot, "state");
        _commandPath = Path.Combine(_sessionRoot, "command.txt");
        _stopPath = Path.Combine(_sessionRoot, "stop.txt");
        _heartbeatPath = Path.Combine(_sessionRoot, "heartbeat.txt");
        _errorPath = Path.Combine(_sessionRoot, "error.txt");
        _levelPath = Path.Combine(_sessionRoot, "level");
        SourceInitialized += (_, _) => EnableWindowsBackdrop();
        Loaded += OnLoaded;
        Closing += OnClosing;
        _pollTimer.Tick += PollBridge;
    }

    private async void OnLoaded(object sender, RoutedEventArgs e)
    {
        try
        {
            Directory.CreateDirectory(_sessionRoot);
            Browser.DefaultBackgroundColor = System.Drawing.Color.Transparent;
            await Browser.EnsureCoreWebView2Async();
            Browser.CoreWebView2.Settings.AreDefaultContextMenusEnabled = false;
            Browser.CoreWebView2.Settings.AreDevToolsEnabled = false;
            Browser.CoreWebView2.Settings.IsStatusBarEnabled = false;
            Browser.CoreWebView2.WebMessageReceived += OnWebMessage;
            Browser.CoreWebView2.NavigationCompleted += (_, _) =>
            {
                SendAppAvailability();
                StartBridge();
            };
            string webRoot = Path.Combine(AppContext.BaseDirectory, "www");
            Browser.CoreWebView2.SetVirtualHostNameToFolderMapping(
                "nova.local", webRoot, CoreWebView2HostResourceAccessKind.DenyCors);
            Browser.CoreWebView2.Navigate("https://nova.local/index.html");
            _pollTimer.Start();
        }
        catch (Exception ex)
        {
            MessageBox.Show("WebView2 n’a pas pu démarrer.\n\n" + ex.Message,
                "Nova Glass", MessageBoxButton.OK, MessageBoxImage.Error);
            Close();
        }
    }

    private void OnWebMessage(object? sender, CoreWebView2WebMessageReceivedEventArgs e)
    {
        try
        {
            using JsonDocument document = JsonDocument.Parse(e.WebMessageAsJson);
            JsonElement root = document.RootElement;
            string type = root.TryGetProperty("type", out JsonElement typeNode) ? typeNode.GetString() ?? "" : "";
            switch (type)
            {
                case "launch":
                    if (root.TryGetProperty("index", out JsonElement indexNode)) Launch(indexNode.GetInt32());
                    break;
                case "media":
                    if (root.TryGetProperty("command", out JsonElement commandNode)) SendMedia(commandNode.GetString() ?? "");
                    break;
                case "window":
                    if (root.TryGetProperty("action", out JsonElement actionNode)) HandleWindow(actionNode.GetString() ?? "");
                    break;
                case "check":
                case "ready":
                    SendAppAvailability();
                    break;
            }
        }
        catch { }
    }

    private void Launch(int index)
    {
        if (index < 0 || index >= _apps.Length) return;
        try
        {
            if (index == 1 && ActivateFirefox())
            {
                SendNotice("Firefox", "Fenêtre existante activée.", false);
                return;
            }
            string target = _apps[index];
            if (!File.Exists(target))
            {
                SendNotice("Raccourci indisponible", target, true);
                return;
            }
            Process.Start(new ProcessStartInfo(target) { UseShellExecute = true });
            SendNotice("Application lancée", Path.GetFileNameWithoutExtension(target), false);
        }
        catch (Exception ex)
        {
            SendNotice("Ouverture impossible", ex.Message, true);
        }
    }

    private bool ActivateFirefox()
    {
        string helper = Path.Combine(AppContext.BaseDirectory, "Scripts", "Activer_Firefox.ps1");
        if (!File.Exists(helper)) return false;
        try
        {
            using Process process = Process.Start(new ProcessStartInfo
            {
                FileName = "powershell.exe",
                Arguments = $"-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File \"{helper}\"",
                UseShellExecute = false,
                CreateNoWindow = true
            })!;
            process.WaitForExit(3000);
            return process.HasExited && process.ExitCode == 0;
        }
        catch { return false; }
    }

    private void SendMedia(string command)
    {
        command = command.ToUpperInvariant();
        if (command is not ("PREVIOUS" or "PLAYPAUSE" or "NEXT")) return;
        try { File.WriteAllText(_commandPath, command + "|" + DateTimeOffset.UtcNow.ToUnixTimeMilliseconds()); }
        catch { }
    }

    private void HandleWindow(string action)
    {
        switch (action)
        {
            case "close": Close(); break;
            case "minimize": WindowState = WindowState.Minimized; break;
            case "toggle": ToggleFullscreen(); break;
        }
    }

    private void ToggleFullscreen()
    {
        if (_isFullscreen)
        {
            WindowState = WindowState.Normal;
            Width = Math.Min(1280, SystemParameters.WorkArea.Width - 40);
            Height = Math.Min(820, SystemParameters.WorkArea.Height - 40);
            Left = SystemParameters.WorkArea.Left + (SystemParameters.WorkArea.Width - Width) / 2;
            Top = SystemParameters.WorkArea.Top + (SystemParameters.WorkArea.Height - Height) / 2;
        }
        else WindowState = WindowState.Maximized;
        _isFullscreen = !_isFullscreen;
    }

    private void StartBridge()
    {
        if (_bridge is { HasExited: false }) return;
        if ((DateTime.UtcNow - _lastBridgeAttempt).TotalSeconds < 5) return;
        _lastBridgeAttempt = DateTime.UtcNow;
        string script = Path.Combine(AppContext.BaseDirectory, "Scripts", "Lecteur_Spotify.ps1");
        if (!File.Exists(script))
        {
            SendNotice("Module absent", "Lecteur_Spotify.ps1 est introuvable.", true);
            return;
        }
        try
        {
            DeleteIfPresent(_stopPath);
            WriteHeartbeat();
            string args = $"-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File \"{script}\" " +
                $"-StatePath \"{_statePath}\" -CommandPath \"{_commandPath}\" -StopPath \"{_stopPath}\" " +
                $"-HeartbeatPath \"{_heartbeatPath}\" -ErrorPath \"{_errorPath}\" -LevelPath \"{_levelPath}\"";
            _bridge = Process.Start(new ProcessStartInfo
            {
                FileName = "powershell.exe",
                Arguments = args,
                UseShellExecute = false,
                CreateNoWindow = true,
                WindowStyle = ProcessWindowStyle.Hidden
            });
        }
        catch (Exception ex) { SendNotice("Module Windows indisponible", ex.Message, true); }
    }

    private void PollBridge(object? sender, EventArgs e)
    {
        if ((DateTime.UtcNow - _lastHeartbeat).TotalSeconds >= 2) WriteHeartbeat();
        if (_bridge == null || _bridge.HasExited) StartBridge();
        ForwardNewestJson(_statePath + "-a.json", _statePath + "-b.json");
        ForwardNewestLevel(_levelPath + "-a.txt", _levelPath + "-b.txt");
    }

    private void WriteHeartbeat()
    {
        try
        {
            File.WriteAllText(_heartbeatPath, DateTimeOffset.UtcNow.ToUnixTimeMilliseconds().ToString());
            _lastHeartbeat = DateTime.UtcNow;
        }
        catch { }
    }

    private void ForwardNewestJson(string first, string second)
    {
        string? path = Newest(first, second);
        if (path == null) return;
        long stamp = File.GetLastWriteTimeUtc(path).Ticks;
        if (stamp == _lastStateStamp) return;
        try
        {
            string json = ReadShared(path, Encoding.Unicode);
            using JsonDocument state = JsonDocument.Parse(json);
            Post(new { type = "state", data = state.RootElement.Clone() });
            _lastStateStamp = stamp;
        }
        catch { }
    }

    private void ForwardNewestLevel(string first, string second)
    {
        string? path = Newest(first, second);
        if (path == null) return;
        long stamp = File.GetLastWriteTimeUtc(path).Ticks;
        if (stamp == _lastLevelStamp) return;
        try
        {
            string[] parts = ReadShared(path, Encoding.ASCII).Split('|');
            if (parts.Length == 2 && int.TryParse(parts[1], out int level))
            {
                Post(new { type = "level", value = Math.Clamp(level, 0, 100) });
                _lastLevelStamp = stamp;
            }
        }
        catch { }
    }

    private static string? Newest(string first, string second)
    {
        bool a = File.Exists(first), b = File.Exists(second);
        if (!a && !b) return null;
        if (!b) return first;
        if (!a) return second;
        return File.GetLastWriteTimeUtc(first) >= File.GetLastWriteTimeUtc(second) ? first : second;
    }

    private static string ReadShared(string path, Encoding encoding)
    {
        using FileStream stream = new(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
        using StreamReader reader = new(stream, encoding, true);
        return reader.ReadToEnd();
    }

    private void SendAppAvailability()
    {
        Post(new { type = "apps", available = _apps.Select(File.Exists).ToArray() });
    }

    private void SendNotice(string title, string text, bool error)
    {
        Post(new { type = "notice", title, text, error });
    }

    private void Post(object value)
    {
        try
        {
            if (Browser.CoreWebView2 != null)
                Browser.CoreWebView2.PostWebMessageAsJson(JsonSerializer.Serialize(value));
        }
        catch { }
    }

    private void OnClosing(object? sender, System.ComponentModel.CancelEventArgs e)
    {
        _pollTimer.Stop();
        try { File.WriteAllText(_stopPath, "stop"); } catch { }
        try
        {
            if (_bridge is { HasExited: false } && !_bridge.WaitForExit(1500)) _bridge.Kill(true);
        }
        catch { }
        try { Directory.Delete(_sessionRoot, true); } catch { }
    }

    private static void DeleteIfPresent(string path)
    {
        try { if (File.Exists(path)) File.Delete(path); } catch { }
    }

    private void EnableWindowsBackdrop()
    {
        try
        {
            IntPtr handle = new WindowInteropHelper(this).Handle;
            int dark = 1;
            int backdrop = 3;
            DwmSetWindowAttribute(handle, 20, ref dark, sizeof(int));
            DwmSetWindowAttribute(handle, 38, ref backdrop, sizeof(int));
            MARGINS margins = new() { Left = -1, Right = -1, Top = -1, Bottom = -1 };
            DwmExtendFrameIntoClientArea(handle, ref margins);
        }
        catch { }
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct MARGINS { public int Left, Right, Top, Bottom; }

    [DllImport("dwmapi.dll")]
    private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attribute, ref int value, int size);

    [DllImport("dwmapi.dll")]
    private static extern int DwmExtendFrameIntoClientArea(IntPtr hwnd, ref MARGINS margins);
}
