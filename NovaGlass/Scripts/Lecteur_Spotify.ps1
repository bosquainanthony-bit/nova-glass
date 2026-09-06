param(
    [Parameter(Mandatory = $true)][string]$StatePath,
    [Parameter(Mandatory = $true)][string]$CommandPath,
    [Parameter(Mandatory = $true)][string]$StopPath,
    [Parameter(Mandatory = $true)][string]$HeartbeatPath,
    [Parameter(Mandatory = $true)][string]$ErrorPath,
    [Parameter(Mandatory = $true)][string]$LevelPath
)

# Passerelle locale entre le bureau HTA et la session multimédia de Windows.
# Elle ne contacte aucun serveur, ne demande pas les droits administrateur et
# ne modifie aucun paramètre du système.

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"
$sessionManager = $null
$session = $null
$cachedTitle = "LECTURE MULTIMÉDIA ACTIVE"
$cachedArtist = "Métadonnées en attente de Windows."
$cachedAlbum = ""
$propertiesRetryAt = [DateTime]::MinValue
$propertiesIssue = ""
$lastSignature = ""
$lastStateWrite = [DateTime]::MinValue
$cpuPercent = -1
$memoryPercent = -1
$diskPercent = -1
$networkPercent = -1
$metricsReady = $false
$previousIdleTicks = 0
$previousTotalTicks = 0
$spotifyProcessSeen = $false
$sessionFallback = $false
$sessionDetail = ""
$stateSlot = 0
$bridgeStartedAt = [DateTime]::UtcNow

# Mesures natives Windows : pas de compteur localisé, pas de WMI et presque
# aucun coût entre deux rafraîchissements d'une seconde.
try {
    Add-Type -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.IO;
using System.Net.NetworkInformation;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

[ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
internal class MMDeviceEnumeratorComObject { }

[ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IMMDeviceEnumerator {
    [PreserveSig] int EnumAudioEndpoints(int dataFlow, uint stateMask, out IntPtr devices);
    [PreserveSig] int GetDefaultAudioEndpoint(int dataFlow, int role, out IMMDevice device);
    [PreserveSig] int GetDevice([MarshalAs(UnmanagedType.LPWStr)] string id, out IMMDevice device);
    [PreserveSig] int RegisterEndpointNotificationCallback(IntPtr callback);
    [PreserveSig] int UnregisterEndpointNotificationCallback(IntPtr callback);
}

[ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IMMDevice {
    [PreserveSig] int Activate(ref Guid interfaceId, uint classContext, IntPtr activationParameters,
        [MarshalAs(UnmanagedType.IUnknown)] out object instance);
    [PreserveSig] int OpenPropertyStore(uint access, out IntPtr properties);
    [PreserveSig] int GetId([MarshalAs(UnmanagedType.LPWStr)] out string id);
    [PreserveSig] int GetState(out uint state);
}

[ComImport, Guid("C02216F6-8C67-4B5B-9D00-D008E73E0064"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IAudioMeterInformation {
    [PreserveSig] int GetPeakValue(out float peak);
    [PreserveSig] int GetMeteringChannelCount(out int count);
    [PreserveSig] int GetChannelsPeakValues(int count, [Out] float[] peaks);
    [PreserveSig] int QueryHardwareSupport(out int supportMask);
}

public static class PhosphorLiveMetrics {
    [StructLayout(LayoutKind.Sequential)]
    private struct FILETIME {
        public uint Low;
        public uint High;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Auto)]
    private struct MEMORYSTATUSEX {
        public uint Length;
        public uint MemoryLoad;
        public ulong TotalPhysical;
        public ulong AvailablePhysical;
        public ulong TotalPageFile;
        public ulong AvailablePageFile;
        public ulong TotalVirtual;
        public ulong AvailableVirtual;
        public ulong AvailableExtendedVirtual;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct PDH_FMT_COUNTERVALUE {
        public uint Status;
        public double DoubleValue;
    }

    private const uint PDH_FMT_DOUBLE = 0x00000200;
    private static IntPtr diskQuery = IntPtr.Zero;
    private static IntPtr diskCounter = IntPtr.Zero;
    private static readonly Dictionary<string, long> PreviousNetworkBytes = new Dictionary<string, long>();
    private static DateTime previousNetworkAt = DateTime.MinValue;
    private static Thread audioThread;
    private static volatile bool audioRunning;
    private static volatile bool audioEnabled;
    private static string audioLevelPath = "";
    private static int audioSlot;

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetSystemTimes(out FILETIME idle, out FILETIME kernel, out FILETIME user);

    [DllImport("kernel32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    private static extern bool GlobalMemoryStatusEx(ref MEMORYSTATUSEX status);

    [DllImport("pdh.dll", CharSet = CharSet.Unicode)]
    private static extern uint PdhOpenQuery(string dataSource, IntPtr userData, out IntPtr query);

    [DllImport("pdh.dll", EntryPoint = "PdhAddEnglishCounterW", CharSet = CharSet.Unicode)]
    private static extern uint PdhAddEnglishCounter(IntPtr query, string path, IntPtr userData, out IntPtr counter);

    [DllImport("pdh.dll")]
    private static extern uint PdhCollectQueryData(IntPtr query);

    [DllImport("pdh.dll")]
    private static extern uint PdhGetFormattedCounterValue(IntPtr counter, uint format, out uint type, out PDH_FMT_COUNTERVALUE value);

    [DllImport("pdh.dll")]
    private static extern uint PdhCloseQuery(IntPtr query);

    private static ulong Ticks(FILETIME value) {
        return ((ulong)value.High << 32) | value.Low;
    }

    public static ulong[] ReadCpuTimes() {
        FILETIME idle, kernel, user;
        if (!GetSystemTimes(out idle, out kernel, out user)) return new ulong[0];
        return new ulong[] { Ticks(idle), Ticks(kernel) + Ticks(user) };
    }

    public static int ReadMemoryLoad() {
        MEMORYSTATUSEX status = new MEMORYSTATUSEX();
        status.Length = (uint)Marshal.SizeOf(typeof(MEMORYSTATUSEX));
        return GlobalMemoryStatusEx(ref status) ? (int)status.MemoryLoad : -1;
    }

    public static void InitializeDiskCounter() {
        if (diskQuery != IntPtr.Zero) return;
        IntPtr query;
        IntPtr counter;
        if (PdhOpenQuery(null, IntPtr.Zero, out query) != 0) return;
        if (PdhAddEnglishCounter(query, @"\PhysicalDisk(_Total)\% Disk Time", IntPtr.Zero, out counter) != 0) {
            PdhCloseQuery(query);
            return;
        }
        diskQuery = query;
        diskCounter = counter;
        PdhCollectQueryData(diskQuery);
    }

    public static double ReadDiskLoad() {
        if (diskQuery == IntPtr.Zero || diskCounter == IntPtr.Zero) return -1;
        if (PdhCollectQueryData(diskQuery) != 0) return -1;
        uint type;
        PDH_FMT_COUNTERVALUE value;
        if (PdhGetFormattedCounterValue(diskCounter, PDH_FMT_DOUBLE, out type, out value) != 0) return -1;
        if (value.Status > 1 || Double.IsNaN(value.DoubleValue) || Double.IsInfinity(value.DoubleValue)) return -1;
        return Math.Max(0, Math.Min(100, value.DoubleValue));
    }

    public static double ReadNetworkLoad() {
        DateTime now = DateTime.UtcNow;
        double elapsed = previousNetworkAt == DateTime.MinValue ? 0 : (now - previousNetworkAt).TotalSeconds;
        double highestLoad = -1;
        Dictionary<string, long> current = new Dictionary<string, long>();
        foreach (NetworkInterface adapter in NetworkInterface.GetAllNetworkInterfaces()) {
            try {
                if (adapter.OperationalStatus != OperationalStatus.Up ||
                    adapter.NetworkInterfaceType == NetworkInterfaceType.Loopback ||
                    adapter.NetworkInterfaceType == NetworkInterfaceType.Tunnel || adapter.Speed <= 0) continue;
                IPInterfaceStatistics statistics = adapter.GetIPStatistics();
                long bytes = statistics.BytesReceived + statistics.BytesSent;
                current[adapter.Id] = bytes;
                long previous;
                if (elapsed > 0 && PreviousNetworkBytes.TryGetValue(adapter.Id, out previous) && bytes >= previous) {
                    double load = ((bytes - previous) * 8.0 / elapsed) / adapter.Speed * 100.0;
                    if (load > highestLoad) highestLoad = load;
                }
            } catch { }
        }
        PreviousNetworkBytes.Clear();
        foreach (KeyValuePair<string, long> item in current) PreviousNetworkBytes[item.Key] = item.Value;
        previousNetworkAt = now;
        return highestLoad < 0 ? -1 : Math.Max(0, Math.Min(100, highestLoad));
    }

    private static IAudioMeterInformation CreateAudioMeter() {
        IMMDeviceEnumerator enumerator = null;
        IMMDevice device = null;
        object instance = null;
        try {
            enumerator = (IMMDeviceEnumerator)new MMDeviceEnumeratorComObject();
            if (enumerator.GetDefaultAudioEndpoint(0, 1, out device) != 0 || device == null) return null;
            Guid meterId = typeof(IAudioMeterInformation).GUID;
            if (device.Activate(ref meterId, 23, IntPtr.Zero, out instance) != 0 || instance == null) return null;
            return instance as IAudioMeterInformation;
        } finally {
            if (device != null && Marshal.IsComObject(device)) Marshal.ReleaseComObject(device);
            if (enumerator != null && Marshal.IsComObject(enumerator)) Marshal.ReleaseComObject(enumerator);
        }
    }

    private static void WriteAudioLevel(int level) {
        try {
            string destination = audioLevelPath + (audioSlot == 0 ? "-a.txt" : "-b.txt");
            long capturedAt = (DateTime.UtcNow.Ticks / TimeSpan.TicksPerMillisecond) - 62135596800000L;
            using (FileStream stream = new FileStream(destination, FileMode.Create, FileAccess.Write, FileShare.ReadWrite))
            using (StreamWriter writer = new StreamWriter(stream, Encoding.ASCII)) {
                writer.Write(capturedAt.ToString());
                writer.Write("|");
                writer.Write(level.ToString());
                writer.Flush();
            }
            audioSlot = 1 - audioSlot;
        } catch { }
    }

    private static void AudioLoop() {
        IAudioMeterInformation meter = null;
        int retryDelay = 0;
        try {
            while (audioRunning) {
                if (!audioEnabled) {
                    Thread.Sleep(400);
                    continue;
                }
                if (meter == null && retryDelay <= 0) {
                    try { meter = CreateAudioMeter(); } catch { meter = null; }
                    retryDelay = meter == null ? 10 : 0;
                } else if (meter == null) {
                    retryDelay--;
                }
                int level = -1;
                if (meter != null) {
                    try {
                        float peak;
                        if (meter.GetPeakValue(out peak) == 0) {
                            level = (int)Math.Round(Math.Max(0, Math.Min(1, peak)) * 100);
                        }
                    } catch {
                        try { if (Marshal.IsComObject(meter)) Marshal.ReleaseComObject(meter); } catch { }
                        meter = null;
                        retryDelay = 10;
                    }
                }
                WriteAudioLevel(level);
                Thread.Sleep(200);
            }
        } finally {
            try { if (meter != null && Marshal.IsComObject(meter)) Marshal.ReleaseComObject(meter); } catch { }
        }
    }

    public static void StartAudioMeter(string levelPath) {
        if (audioThread != null || String.IsNullOrWhiteSpace(levelPath)) return;
        audioLevelPath = levelPath;
        audioRunning = true;
        audioEnabled = false;
        audioThread = new Thread(AudioLoop);
        audioThread.Name = "Phosphor audio meter";
        audioThread.IsBackground = true;
        audioThread.SetApartmentState(ApartmentState.MTA);
        audioThread.Start();
    }

    public static void SetAudioMeterEnabled(bool enabled) {
        audioEnabled = enabled;
    }

    private static void StopAudioMeter() {
        audioEnabled = false;
        audioRunning = false;
        try {
            if (audioThread != null && audioThread.IsAlive) audioThread.Join(800);
        } catch { }
        audioThread = null;
    }

    public static void Shutdown() {
        StopAudioMeter();
        if (diskQuery != IntPtr.Zero) PdhCloseQuery(diskQuery);
        diskQuery = IntPtr.Zero;
        diskCounter = IntPtr.Zero;
    }
}
"@ -Language CSharp -ErrorAction Stop
    [PhosphorLiveMetrics]::InitializeDiskCounter()
    [PhosphorLiveMetrics]::StartAudioMeter($LevelPath)
    $metricsReady = $true
} catch {
    $metricsReady = $false
}

function Write-State {
    param($Data)
    $suffix = "-a.json"
    if ($script:stateSlot -eq 1) { $suffix = "-b.json" }
    $destination = $StatePath + $suffix
    try {
        $parent = [IO.Path]::GetDirectoryName($destination)
        if (-not [IO.Directory]::Exists($parent)) {
            [IO.Directory]::CreateDirectory($parent) | Out-Null
        }
        $json = ConvertTo-Json -InputObject $Data -Compress -Depth 4
    } catch {
        return $false
    }

    # Double tampon : pendant que le HTA lit A, la passerelle écrit B, puis
    # inversement. Même une lecture partielle laisse toujours un état valide.
    for ($attempt = 0; $attempt -lt 16; $attempt++) {
        $stream = $null
        $writer = $null
        try {
            $stream = [IO.FileStream]::new($destination, [IO.FileMode]::Create,
                [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite)
            $writer = [IO.StreamWriter]::new($stream, [Text.Encoding]::Unicode)
            $writer.Write($json)
            $writer.Flush()
            $stream.Flush()
            $writer.Dispose()
            $writer = $null
            $stream = $null
            $script:stateSlot = 1 - $script:stateSlot
            return $true
        } catch [IO.IOException] {
            Start-Sleep -Milliseconds 35
        } catch [UnauthorizedAccessException] {
            Start-Sleep -Milliseconds 35
        } catch {
            break
        } finally {
            try { if ($null -ne $writer) { $writer.Dispose() } } catch {}
            try { if ($null -ne $stream) { $stream.Dispose() } } catch {}
        }
    }
    return $false
}

function Update-SystemMetrics {
    if (-not $script:metricsReady) { return }
    try {
        $times = [PhosphorLiveMetrics]::ReadCpuTimes()
        if ($times.Length -eq 2) {
            if ($script:previousTotalTicks -gt 0 -and $times[1] -gt $script:previousTotalTicks) {
                $idleDelta = [double]($times[0] - $script:previousIdleTicks)
                $totalDelta = [double]($times[1] - $script:previousTotalTicks)
                $load = 100 * (1 - ($idleDelta / $totalDelta))
                $script:cpuPercent = [Math]::Max(0, [Math]::Min(100, [Math]::Round($load)))
            }
            $script:previousIdleTicks = $times[0]
            $script:previousTotalTicks = $times[1]
        }
        $memory = [PhosphorLiveMetrics]::ReadMemoryLoad()
        if ($memory -ge 0) { $script:memoryPercent = $memory }
        $disk = [PhosphorLiveMetrics]::ReadDiskLoad()
        if ($disk -ge 0) { $script:diskPercent = [Math]::Round($disk) }
        $network = [PhosphorLiveMetrics]::ReadNetworkLoad()
        if ($network -ge 0) { $script:networkPercent = [Math]::Round($network) }
    } catch {
        # Les mesures sont facultatives : conserver les dernières valeurs valides.
    }
}

function Get-EpochMilliseconds {
    return [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
}

function Wait-WinRtOperation {
    param($Operation, [Type]$ResultType, [int]$TimeoutMs = 4000)
    $task = $script:asTaskMethod.MakeGenericMethod($ResultType).Invoke($null, @($Operation))
    if (-not $task.Wait($TimeoutMs)) { throw "Délai dépassé pour la réponse multimédia Windows." }
    return $task.GetAwaiter().GetResult()
}

function Find-SpotifySession {
    if ($null -eq $sessionManager) { return $null }
    $script:spotifyProcessSeen = $false
    $script:sessionFallback = $false
    $script:sessionDetail = ""
    $candidates = @()
    try { $candidates = @($sessionManager.GetSessions()) } catch {}

    # Méthode principale : identité déclarée par Spotify à Windows.
    foreach ($candidate in $candidates) {
        try {
            if (([string]$candidate.SourceAppUserModelId) -match "(?i)(spotify|spotifymusic|spoti\.fi)") {
                return $candidate
            }
        } catch {}
    }

    $current = $null
    try {
        $current = $sessionManager.GetCurrentSession()
        if ($null -ne $current -and ([string]$current.SourceAppUserModelId) -match "(?i)(spotify|spotifymusic|spoti\.fi)") {
            return $current
        }
    } catch { $current = $null }

    # Certaines versions de Spotify masquent leur identité. Vérifier également
    # le processus local, mais ne plus en dépendre pour choisir la session active.
    try {
        $script:spotifyProcessSeen = @(Get-Process -Name "Spotify" -ErrorAction SilentlyContinue).Count -gt 0
    } catch { $script:spotifyProcessSeen = $false }

    # Secours universel : la session multimédia active de Windows est celle que
    # pilotent aussi les touches lecture/pause du clavier. Cela couvre Spotify
    # même lorsque son identifiant ou son nom de processus n'est pas exposé.
    if ($null -ne $current) {
        $script:sessionFallback = $true
        $script:sessionDetail = "Session reconnue par le lecteur multimédia actif de Windows."
        return $current
    }
    $playing = @()
    foreach ($candidate in $candidates) {
        try {
            if (([string]$candidate.GetPlaybackInfo().PlaybackStatus) -eq "Playing") { $playing += $candidate }
        } catch {}
    }
    if ($playing.Count -eq 1) {
        $script:sessionFallback = $true
        $script:sessionDetail = "Session reconnue par l'unique lecture active de Windows."
        return $playing[0]
    }
    if ($candidates.Count -eq 1) {
        $script:sessionFallback = $true
        $script:sessionDetail = "Session reconnue par le lecteur multimédia de Windows."
        return $candidates[0]
    }
    if ($script:spotifyProcessSeen) {
        $script:sessionDetail = "Spotify est ouvert, mais Windows ne transmet aucune session multimédia."
    } else {
        $script:sessionDetail = "Ouvrez Spotify et lancez un morceau."
    }
    return $null
}

function Invoke-MediaCommand {
    param([string]$Command)
    if ($null -eq $session) { return }
    try {
        switch ($Command) {
            "PREVIOUS"  { Wait-WinRtOperation ($session.TrySkipPreviousAsync()) ([bool]) | Out-Null }
            "PLAYPAUSE" { Wait-WinRtOperation ($session.TryTogglePlayPauseAsync()) ([bool]) | Out-Null }
            "NEXT"      { Wait-WinRtOperation ($session.TrySkipNextAsync()) ([bool]) | Out-Null }
        }
    } catch {}
}

function Read-PendingCommand {
    if (-not [IO.File]::Exists($CommandPath)) { return "" }
    try {
        $raw = [IO.File]::ReadAllText($CommandPath)
        [IO.File]::Delete($CommandPath)
        return ($raw -split "\|", 2)[0].Trim().ToUpperInvariant()
    } catch {
        return ""
    }
}

function Heartbeat-IsAlive {
    if (-not [IO.File]::Exists($HeartbeatPath)) { return $false }
    try {
        $raw = [IO.File]::ReadAllText($HeartbeatPath).Trim()
        $timestamp = [long]0
        if ([long]::TryParse($raw, [ref]$timestamp)) {
            return ((Get-EpochMilliseconds) - $timestamp) -lt 30000
        }
        $age = [DateTime]::UtcNow - [IO.File]::GetLastWriteTimeUtc($HeartbeatPath)
        return $age.TotalSeconds -lt 30
    } catch {
        return $false
    }
}

try {
    [Reflection.Assembly]::LoadWithPartialName("System.Runtime.WindowsRuntime") | Out-Null
    [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager, Windows.Media.Control, ContentType=WindowsRuntime] | Out-Null
    [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionMediaProperties, Windows.Media.Control, ContentType=WindowsRuntime] | Out-Null

    $script:asTaskMethod = [System.WindowsRuntimeSystemExtensions].GetMethods() |
        Where-Object {
            $_.Name -eq "AsTask" -and $_.IsGenericMethodDefinition -and
            $_.GetParameters().Count -eq 1 -and
            $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
        } | Select-Object -First 1
    if ($null -eq $script:asTaskMethod) { throw "Extension WinRT AsTask introuvable" }

    $request = [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager]::RequestAsync()
    $sessionManager = Wait-WinRtOperation $request ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager]) 10000

    Update-SystemMetrics
    Write-State ([ordered]@{
        version = 1; error = $false; online = $false; playback = "Offline";
        title = "AUCUNE LECTURE DÉTECTÉE"; artist = "Ouvrez Spotify et lancez un morceau.";
        album = ""; position = 0; duration = 0; capturedAt = (Get-EpochMilliseconds);
        coverPath = ""; coverVersion = 0; detail = "Ouvrez Spotify et lancez un morceau.";
        cpu = $cpuPercent; memory = $memoryPercent; disk = $diskPercent; network = $networkPercent;
        metricsAvailable = $metricsReady; spotifyProcess = $false; fallback = $false
    }) | Out-Null

    while (-not [IO.File]::Exists($StopPath)) {
        if (-not (Heartbeat-IsAlive) -and
            ([DateTime]::UtcNow - $bridgeStartedAt).TotalSeconds -ge 45) { break }
        Update-SystemMetrics
        $session = Find-SpotifySession
        $command = Read-PendingCommand
        if ($command -match "^(PREVIOUS|PLAYPAUSE|NEXT)$") {
            Invoke-MediaCommand $command
            Start-Sleep -Milliseconds 180
            $session = Find-SpotifySession
        }

        if ($null -eq $session) {
            if ($metricsReady) { [PhosphorLiveMetrics]::SetAudioMeterEnabled($false) }
            $state = [ordered]@{
                version = 1; error = $false; online = $false; playback = "Offline";
                title = "AUCUNE LECTURE DÉTECTÉE"; artist = "Ouvrez Spotify et lancez un morceau.";
                album = ""; position = 0; duration = 0; capturedAt = (Get-EpochMilliseconds);
                coverPath = ""; coverVersion = 0; detail = $sessionDetail;
                cpu = $cpuPercent; memory = $memoryPercent; disk = $diskPercent; network = $networkPercent;
                metricsAvailable = $metricsReady; spotifyProcess = $spotifyProcessSeen; fallback = $false
            }
            $signature = "offline|$spotifyProcessSeen|$sessionDetail"
        } else {
            try {
                $playback = "Unknown"
                try { $playback = [string]$session.GetPlaybackInfo().PlaybackStatus } catch {}
                if ($metricsReady) { [PhosphorLiveMetrics]::SetAudioMeterEnabled($playback -eq "Playing") }
                $position = 0
                $duration = 0
                try {
                    $timeline = $session.GetTimelineProperties()
                    $position = [Math]::Max(0, ($timeline.Position - $timeline.StartTime).TotalSeconds)
                    $duration = [Math]::Max(0, ($timeline.EndTime - $timeline.StartTime).TotalSeconds)
                } catch {}

                # Les métadonnées sont utiles, mais elles ne doivent jamais figer
                # le lecteur. En cas de délai Windows, garder la session active et
                # retenter seulement quinze secondes plus tard.
                if ([DateTime]::UtcNow -ge $propertiesRetryAt) {
                    try {
                        $propertiesOperation = $session.TryGetMediaPropertiesAsync()
                        $properties = Wait-WinRtOperation $propertiesOperation ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionMediaProperties]) 3500
                        $script:cachedTitle = [string]$properties.Title
                        $script:cachedArtist = [string]$properties.Artist
                        $script:cachedAlbum = [string]$properties.AlbumTitle
                        if ([string]::IsNullOrWhiteSpace($script:cachedTitle)) { $script:cachedTitle = "TITRE NON RENSEIGNÉ" }
                        if ([string]::IsNullOrWhiteSpace($script:cachedArtist)) { $script:cachedArtist = "ARTISTE NON RENSEIGNÉ" }
                        $script:propertiesIssue = ""
                        $script:propertiesRetryAt = [DateTime]::MinValue
                    } catch {
                        $script:propertiesIssue = "Métadonnées temporairement indisponibles sous Windows 11."
                        $script:propertiesRetryAt = [DateTime]::UtcNow.AddSeconds(15)
                    }
                }
                $title = $cachedTitle
                $artist = $cachedArtist
                $album = $cachedAlbum
                $trackKey = "$title|$artist|$album"
                $captured = Get-EpochMilliseconds
                $state = [ordered]@{
                    version = 1; error = $false; online = $true; playback = $playback;
                    title = $title; artist = $artist; album = $album;
                    position = [Math]::Round($position, 3); duration = [Math]::Round($duration, 3);
                    capturedAt = $captured; coverPath = "";
                    coverVersion = 0; detail = $propertiesIssue;
                    cpu = $cpuPercent; memory = $memoryPercent; disk = $diskPercent; network = $networkPercent;
                    metricsAvailable = $metricsReady; spotifyProcess = $spotifyProcessSeen; fallback = $sessionFallback
                }
                $signature = "$trackKey|$playback|$([Math]::Floor($position / 4))"
            } catch {
                if ($metricsReady) { [PhosphorLiveMetrics]::SetAudioMeterEnabled($false) }
                $state = [ordered]@{
                    version = 1; error = $false; online = $false; playback = "Offline";
                    title = "SESSION SPOTIFY ILLISIBLE"; artist = "Relancez Spotify.";
                    album = ""; position = 0; duration = 0; capturedAt = (Get-EpochMilliseconds);
                    coverPath = ""; coverVersion = 0; detail = "Relancez Spotify.";
                    cpu = $cpuPercent; memory = $memoryPercent; disk = $diskPercent; network = $networkPercent;
                    metricsAvailable = $metricsReady; spotifyProcess = $spotifyProcessSeen; fallback = $false
                }
                $signature = "session-error"
            }
        }

        if ($signature -ne $lastSignature -or ([DateTime]::UtcNow - $lastStateWrite).TotalMilliseconds -ge 900) {
            if (Write-State $state) {
                $lastSignature = $signature
                $lastStateWrite = [DateTime]::UtcNow
            }
        }
        Start-Sleep -Milliseconds 1000
    }
} catch {
    try {
        $reason = [string]$_.Exception.Message
        if ([string]::IsNullOrWhiteSpace($reason)) { $reason = "Erreur Windows non précisée." }
        if ($reason.Length -gt 180) { $reason = $reason.Substring(0, 180) }
        try { [IO.File]::WriteAllText($ErrorPath, $reason, [Text.Encoding]::Unicode) } catch {}
        Write-State ([ordered]@{
            version = 1; error = $true; online = $false; playback = "Error";
            title = "LECTEUR NON DISPONIBLE"; artist = "Module Windows non démarré.";
            album = ""; position = 0; duration = 0; capturedAt = (Get-EpochMilliseconds);
            coverPath = ""; coverVersion = 0;
            detail = "Erreur Windows : $reason";
            cpu = $cpuPercent; memory = $memoryPercent; disk = $diskPercent; network = $networkPercent;
            metricsAvailable = $metricsReady; spotifyProcess = $spotifyProcessSeen; fallback = $false
        }) | Out-Null
    } catch {}
} finally {
    try { if ($metricsReady) { [PhosphorLiveMetrics]::Shutdown() } } catch {}
    try {
        $sessionFolder = [IO.Path]::GetDirectoryName($StatePath)
        if ([IO.Path]::GetFileName($sessionFolder) -like "session-*") {
            [IO.Directory]::Delete($sessionFolder, $true)
        }
    } catch {}
}
