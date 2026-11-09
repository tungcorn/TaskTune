[CmdletBinding()]
param(
    [ValidateRange(10,120)][int]$Samples = 25,
    [ValidatePattern('^[0-9A-Za-z-]+$')][string]$RunId = ((Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0,6))
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$outputDirectory = Join-Path $root ('benchmarks\' + $RunId)
New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
$admin = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) {
    Write-Output "Benchmark results: $outputDirectory"
    $arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $PSCommandPath + '" -Samples ' + $Samples + ' -RunId ' + $RunId
    $process = Start-Process -FilePath (Get-Command pwsh).Source -Verb RunAs -ArgumentList $arguments -PassThru -Wait
    if ($process.ExitCode -ne 0) { throw "Benchmark failed ($($process.ExitCode)). Inspect $outputDirectory\run.log and result.json." }
    Write-Output "Benchmark completed. Results: $outputDirectory\result.json"
    return
}
Start-Transcript -Path (Join-Path $outputDirectory 'run.log') | Out-Null
$key = 'HKLM:\SOFTWARE\Windhawk\Engine\Mods\tasktune-media'
$changed = $false
$phases = [System.Collections.Generic.List[object]]::new()
$result = [ordered]@{
    runId=$RunId; status='starting'; started=(Get-Date).ToString('o'); logicalProcessors=[Environment]::ProcessorCount;
    method='Same Explorer PID, ON1/OFF/ON2, 5-second settling and 1-second sampling; CPU normalized to all logical processors.';
    caveats=@('Keep the same video and avoid user interaction. Playback status is probed at phase boundaries, not continuously; content identity is not checked.', 'No Explorer restart or forced process termination.', 'Working set/private bytes include all of Explorer, not an isolated mod allocation. DLL pages and shared runtimes may remain cached after unloading.', 'Short sequential test; ON1/ON2 drift indicates temporal noise. GPU Engine samples are coarse, driver-dependent, and not a power measurement. DWM also includes unrelated desktop work.');
    samplesPerPhase=$Samples; phases=@()
}
try {
    if ((Get-Service Windhawk).Status -ne 'Running') { throw 'Windhawk is not running.' }
    $config = Get-ItemProperty -LiteralPath $key
    if ($config.Disabled -ne 0) { throw 'Expected the mod to be enabled at the start.' }
    $dllName = [string]$config.LibraryFileName
    $explorer = @(Get-Process explorer)
    if ($explorer.Count -ne 1) { throw 'Expected one Explorer process for an unambiguous same-PID test.' }
    $script:explorerId = $explorer[0].Id
    $script:explorerStarted = $explorer[0].StartTime
    $script:windhawkIds = @(Get-Process -Name windhawk | Select-Object -ExpandProperty Id)
    $result.explorerPID = $script:explorerId
    $result.explorerStarted = $script:explorerStarted.ToString('o')
    $result.dll = $dllName
    $dwm = @(Get-Process dwm | Where-Object SessionId -eq $explorer[0].SessionId)
    if ($dwm.Count -ne 1) { throw 'Expected one DWM in the Explorer session.' }
    $script:dwmID = $dwm[0].Id
    $script:dwmStarted = $dwm[0].StartTime
    $result.dwmPID = $script:dwmID
    $result.graphicsMethod = 'DWM cumulative CPU sampled with Explorer; optional GPU Engine WMI snapshots every five samples. GPU metric is each process busiest engine, not summed engine utilization or power.'
    $script:gpuAvailable = $true
    try { Get-CimInstance Win32_PerfFormattedData_GPUPerformanceCounters_GPUEngine -Filter "Name LIKE '%pid_$($script:dwmID)_%'" -OperationTimeoutSec 3 -ErrorAction Stop | Out-Null }
    catch { $script:gpuAvailable = $false; $result.gpuError = $_.Exception.Message }
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class TaskTuneBenchmarkWindow {
    [DllImport("user32.dll", CharSet=CharSet.Unicode)]
    public static extern IntPtr FindWindow(string cls, string title);
    [DllImport("user32.dll", SetLastError=true)]
    public static extern IntPtr SendMessageTimeout(IntPtr hwnd, uint msg, UIntPtr wParam, IntPtr lParam, uint flags, uint timeout, out UIntPtr result);
    public static bool Responsive() {
        IntPtr hwnd=FindWindow("Shell_TrayWnd",null);
        if(hwnd==IntPtr.Zero) return false;
        UIntPtr result;
        return SendMessageTimeout(hwnd,0,UIntPtr.Zero,IntPtr.Zero,2,1000,out result)!=IntPtr.Zero;
    }
}
'@
    function Get-ExplorerChecked {
        $p = Get-Process -Id $script:explorerId -ErrorAction Stop
        if ($p.StartTime -ne $script:explorerStarted) { throw 'Explorer changed; benchmark is invalid.' }
        return $p
    }
    function Test-ModLoaded {
        $p = Get-ExplorerChecked
        return @($p.Modules | Where-Object { $_.ModuleName -eq $dllName }).Count -gt 0
    }
    function Assert-Responsive {
        if (-not [TaskTuneBenchmarkWindow]::Responsive()) { throw 'Taskbar did not respond to WM_NULL within one second. No Explorer restart will be attempted.' }
    }
    function Wait-ModState([bool]$Enabled) {
        $timer = [Diagnostics.Stopwatch]::StartNew()
        do {
            Assert-Responsive
            if ((Test-ModLoaded) -eq $Enabled) { return }
            Start-Sleep -Milliseconds 500
        } while ($timer.Elapsed.TotalSeconds -lt 15)
        throw "DLL did not reach enabled=$Enabled within 15 seconds. Unload/load may be stuck."
    }
    function Get-Snapshot {
        $p = Get-ExplorerChecked
        $cpu = 0.0; $ws = 0L; $private = 0L
        foreach ($id in $script:windhawkIds) {
            $w = Get-Process -Id $id -ErrorAction Stop
            $cpu += $w.TotalProcessorTime.TotalSeconds
            $ws += $w.WorkingSet64
            $private += $w.PrivateMemorySize64
        }
        $d = Get-Process -Id $script:dwmID -ErrorAction Stop
        if ($d.StartTime -ne $script:dwmStarted) { throw 'DWM changed during the benchmark.' }
        [pscustomobject]@{
            ExplorerCPU=$p.TotalProcessorTime.TotalSeconds; ExplorerWorkingMB=$p.WorkingSet64/1MB; ExplorerPrivateMB=$p.PrivateMemorySize64/1MB;
            WindhawkCPU=$cpu; WindhawkWorkingMB=$ws/1MB; WindhawkPrivateMB=$private/1MB; DwmCPU=$d.TotalProcessorTime.TotalSeconds
        }
    }
    function Get-GpuSnapshot {
        if (-not $script:gpuAvailable) { return $null }
        try {
            $counters = @(Get-CimInstance Win32_PerfFormattedData_GPUPerformanceCounters_GPUEngine -Filter "Name LIKE '%pid_$($script:explorerId)_%' OR Name LIKE '%pid_$($script:dwmID)_%'" -OperationTimeoutSec 3 -ErrorAction Stop)
            if (-not $counters.Count) { throw 'No GPU Engine counters for Explorer or DWM.' }
            $e = @($counters | Where-Object { $_.Name -like "pid_$($script:explorerId)_*" })
            $d = @($counters | Where-Object { $_.Name -like "pid_$($script:dwmID)_*" })
            [pscustomobject]@{
                explorerMaxEnginePercent=if ($e.Count) { [double]($e | Measure-Object UtilizationPercentage -Maximum).Maximum } else { $null }
                dwmMaxEnginePercent=if ($d.Count) { [double]($d | Measure-Object UtilizationPercentage -Maximum).Maximum } else { $null }
            }
        } catch { $script:gpuAvailable=$false; $result.gpuError=$_.Exception.Message; return $null }
    }
    function Get-MediaState {
        $text = & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'Get-MediaState.ps1')
        if ($LASTEXITCODE -ne 0) { return [pscustomobject]@{status='failed'} }
        return ($text | ConvertFrom-Json)
    }
    function Get-Median([double[]]$Values) {
        $sorted = @($Values | Sort-Object)
        $n = $sorted.Count
        if ($n % 2) { return $sorted[[int][Math]::Floor($n/2)] }
        return ($sorted[$n/2-1] + $sorted[$n/2])/2
    }
    function Measure-Phase([string]$Name, [bool]$Enabled) {
        Write-Output "Phase $Name : enabled=$Enabled; settling 5 seconds, sampling $Samples seconds."
        Wait-ModState $Enabled
        Start-Sleep -Seconds 5
        Assert-Responsive
        $mediaStart = Get-MediaState
        $rows = [System.Collections.Generic.List[object]]::new()
        $clock = [Diagnostics.Stopwatch]::StartNew()
        $previous = Get-Snapshot
        $previousTime = $clock.Elapsed.TotalSeconds
        for ($i=0; $i -lt $Samples; $i++) {
            Start-Sleep -Seconds 1
            $current = Get-Snapshot
            $now = $clock.Elapsed.TotalSeconds
            $elapsed = $now - $previousTime
            $rows.Add([pscustomobject]@{
                sample=$i+1; elapsed=$elapsed;
                explorerCPUPercent=100*($current.ExplorerCPU-$previous.ExplorerCPU)/$elapsed/[Environment]::ProcessorCount;
                windhawkCPUPercent=100*($current.WindhawkCPU-$previous.WindhawkCPU)/$elapsed/[Environment]::ProcessorCount;
                dwmCPUPercent=100*($current.DwmCPU-$previous.DwmCPU)/$elapsed/[Environment]::ProcessorCount;
                gpu=if (($i+1)%5 -eq 0) { Get-GpuSnapshot } else { $null };
                explorerWorkingMB=$current.ExplorerWorkingMB; explorerPrivateMB=$current.ExplorerPrivateMB;
                windhawkWorkingMB=$current.WindhawkWorkingMB; windhawkPrivateMB=$current.WindhawkPrivateMB
            })
            $previous = $current; $previousTime = $now
        }
        Assert-Responsive
        if ((Test-ModLoaded) -ne $Enabled) { throw 'DLL state changed during phase.' }
        $totalTime = ($rows | Measure-Object elapsed -Sum).Sum
        $explorerMean = ($rows | ForEach-Object { $_.explorerCPUPercent*$_.elapsed } | Measure-Object -Sum).Sum/$totalTime
        $windhawkMean = ($rows | ForEach-Object { $_.windhawkCPUPercent*$_.elapsed } | Measure-Object -Sum).Sum/$totalTime
        $sortedCPU = @($rows.explorerCPUPercent | Sort-Object)
        $summary = [pscustomobject]@{
            name=$Name; enabled=$Enabled; measuredSeconds=$totalTime;
            mediaStart=$mediaStart; mediaEnd=(Get-MediaState);
            explorerCPUPercentMean=$explorerMean; explorerCPUPercentP95=$sortedCPU[[int][Math]::Ceiling($sortedCPU.Count*.95)-1];
            windhawkCPUPercentMean=$windhawkMean;
            dwmCPUPercentMean=($rows | ForEach-Object { $_.dwmCPUPercent*$_.elapsed } | Measure-Object -Sum).Sum/$totalTime;
            gpuSnapshots=@($rows | Where-Object { $null -ne $_.gpu } | ForEach-Object gpu);
            explorerWorkingMBMedian=(Get-Median $rows.explorerWorkingMB); explorerPrivateMBMedian=(Get-Median $rows.explorerPrivateMB);
            windhawkWorkingMBMedian=(Get-Median $rows.windhawkWorkingMB); windhawkPrivateMBMedian=(Get-Median $rows.windhawkPrivateMB);
            samples=$rows.ToArray()
        }
        $summary | Add-Member -NotePropertyName playingAtBothBoundaries -NotePropertyValue ($summary.mediaStart.status -eq 'ok' -and $summary.mediaEnd.status -eq 'ok' -and $summary.mediaStart.currentStatus -eq 'Playing' -and $summary.mediaEnd.currentStatus -eq 'Playing')
        $script:phases.Add($summary)
        $summary | Select-Object name,explorerCPUPercentMean,windhawkCPUPercentMean,dwmCPUPercentMean,gpuSnapshots,explorerPrivateMBMedian,explorerWorkingMBMedian | Format-List | Out-Host
    }
    Assert-Responsive
    if (-not (Test-ModLoaded)) { throw 'The enabled mod DLL is not loaded; cannot benchmark.' }
    Measure-Phase 'ON1' $true
    $changed = $true
    Set-ItemProperty -LiteralPath $key -Name Disabled -Value 1
    Measure-Phase 'OFF' $false
    Set-ItemProperty -LiteralPath $key -Name Disabled -Value 0
    Measure-Phase 'ON2' $true
    $result.status = 'completed'
    $result.finalDisabled = (Get-ItemProperty -LiteralPath $key).Disabled
} catch {
    $result.status = 'failed'
    $result.error = $_.Exception.Message
    if ($changed) {
        # If an unload/reload hangs, persist OFF rather than force another load.
        Set-ItemProperty -LiteralPath $key -Name Disabled -Value 1 -ErrorAction Continue
        $result.finalDisabled = 1
    }
    Write-Output ('BENCHMARK_FAILED: ' + $_.Exception.Message)
} finally {
    $result.finished = (Get-Date).ToString('o')
    $result.phases = $phases.ToArray()
    $result.allPhasesPlayingAtBoundaries = $phases.Count -eq 3 -and @($phases | Where-Object { -not $_.playingAtBothBoundaries }).Count -eq 0
    $result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $outputDirectory 'result.json') -Encoding utf8
    Stop-Transcript | Out-Null
}
if ($result.status -ne 'completed') { exit 1 }
