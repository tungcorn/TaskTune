# Windows PowerShell 5.1 supplies WinRT projection; PowerShell 7 does not.
# Reports playback status only, never titles, URLs, or artwork.
$ErrorActionPreference = 'Stop'
try {
    Add-Type -AssemblyName System.Runtime.WindowsRuntime
    $managerType = [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager, Windows.Media.Control, ContentType=WindowsRuntime]
    $operation = $managerType::RequestAsync()
    $asTask = [System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
        $_.Name -eq 'AsTask' -and $_.IsGenericMethod -and $_.GetParameters().Count -eq 1 -and
        $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
    } | Select-Object -First 1
    $task = $asTask.MakeGenericMethod($managerType).Invoke($null, @($operation))
    $manager = $task.GetAwaiter().GetResult()
    $sessions = @($manager.GetSessions())
    # Allow a newly connected manager a short discovery window before reporting
    # an empty session list. Persistent absence remains explicit, not 'Playing'.
    for ($attempt=0; $sessions.Count -eq 0 -and $attempt -lt 5; $attempt++) {
        Start-Sleep -Milliseconds 200
        $sessions = @($manager.GetSessions())
    }
    $states = @($sessions | ForEach-Object { $_.GetPlaybackInfo().PlaybackStatus.ToString() })
    $current = $manager.GetCurrentSession()
    [pscustomobject]@{
        status='ok'; sessionCount=$sessions.Count;
        playingCount=@($states | Where-Object { $_ -eq 'Playing' }).Count;
        currentStatus=if ($current) { $current.GetPlaybackInfo().PlaybackStatus.ToString() } else { 'None' }
    } | ConvertTo-Json -Compress
} catch {
    [pscustomobject]@{status='failed';error=$_.Exception.Message} | ConvertTo-Json -Compress
    exit 1
}
