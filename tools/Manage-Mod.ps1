[CmdletBinding(SupportsShouldProcess=$true)]
param([ValidateSet('Install','Disable')][string]$Action = 'Install')
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$manifestPath = Join-Path $root 'dist\manifest.json'
$source = Join-Path $root 'mods\tasktune-media.wh.cpp'
$id = 'tasktune-media'
$key = 'HKLM:\SOFTWARE\Windhawk\Engine\Mods\tasktune-media'
$oldKey = 'HKLM:\SOFTWARE\Windhawk\Engine\Mods\native-taskbar-media-controller'
$base = Join-Path $env:ProgramData 'Windhawk'
$sourceDir = Join-Path $base 'ModsSource'
$dllDir = Join-Path $base 'Engine\Mods\64'
$compilerRuntime = Join-Path $env:ProgramFiles 'Windhawk\Compiler\x86_64-w64-mingw32\bin'

if ($Action -eq 'Install') {
    $service = Get-Service -Name Windhawk -ErrorAction Stop
    if ($service.Status -ne 'Stopped') {
        throw 'Windhawk is running. Exit Windhawk from its tray menu first. This installer never force-unloads mods or restarts Explorer.'
    }
    if (Test-Path -LiteralPath $key) { throw 'TaskTune is already installed. Refusing to overwrite its settings.' }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    if ($manifest.id -ne $id -or [IO.Path]::GetFileName($manifest.dll) -ne $manifest.dll -or $manifest.dll -notmatch '^tasktune-media_[A-Za-z0-9_.-]+\.dll$') {
        throw 'Invalid build manifest. Rebuild with tools/build.py.'
    }
    $dll = Join-Path $root ('dist\' + $manifest.dll)
    if ((Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash -ne $manifest.source_sha256 -or
        (Get-FileHash -LiteralPath $dll -Algorithm SHA256).Hash -ne $manifest.dll_sha256) {
        throw 'Build/source hash mismatch. Rebuild before installing.'
    }
    foreach ($destination in @((Join-Path $sourceDir ($id + '.wh.cpp')), (Join-Path $dllDir $manifest.dll))) {
        if (Test-Path -LiteralPath $destination) { throw "Refusing to overwrite: $destination" }
    }
    $runtimePairs = @(@('libc++.dll','libc++.whl'), @('libunwind.dll','libunwind.whl'), @('windhawk-mod-shim.dll','windhawk-mod-shim.dll'))
    foreach ($pair in $runtimePairs) {
        $from = Join-Path $compilerRuntime $pair[0]
        $to = Join-Path $dllDir $pair[1]
        if (-not (Test-Path -LiteralPath $from -PathType Leaf)) { throw "Runtime missing: $from" }
        if ((Test-Path -LiteralPath $to) -and (Get-FileHash -LiteralPath $from).Hash -ne (Get-FileHash -LiteralPath $to).Hash) {
            throw "Existing runtime differs; refusing to replace: $to"
        }
    }
} elseif (-not (Test-Path -LiteralPath $key)) {
    Write-Output 'TaskTune is not installed; nothing to disable.'
    return
}

$operation = if ($Action -eq 'Install') {
    'Install TaskTune DISABLED and disable the previous incompatible native media mod. Do not start Windhawk or restart Explorer.'
} else {
    'Set TaskTune Disabled=1. Do not restart Explorer or change other mods.'
}
if (-not $PSCmdlet.ShouldProcess($key, $operation)) { return }

$admin = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) {
    $arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $PSCommandPath + '" -Action ' + $Action
    $process = Start-Process -FilePath (Get-Command pwsh).Source -Verb RunAs -ArgumentList $arguments -Wait -PassThru
    if ($process.ExitCode -ne 0) { throw "Administrator step failed ($($process.ExitCode)). See dist/manage-*.log." }
    Write-Output 'Administrator step finished. See dist/manage-*.log for details.'
    return
}

# Disable must work from a fresh checkout even when no build has created dist.
[IO.Directory]::CreateDirectory((Join-Path $root 'dist')) | Out-Null
$log = Join-Path $root ('dist\manage-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '.log')
Start-Transcript -Path $log | Out-Null
try {
    if ($Action -eq 'Disable') {
        # The user can restart Explorer manually if an upstream unload hangs.
        # This script deliberately never kills Explorer or the Windhawk service.
        Get-ItemProperty -LiteralPath $key | Select-Object Disabled,LibraryFileName | Format-List
        Set-ItemProperty -LiteralPath $key -Name Disabled -Value 1
        Write-Output 'Disabled flag saved. If the taskbar is frozen, use Task Manager > Windows Explorer > Restart.'
    } else {
        # Recheck after elevation in case Windhawk was started in the meantime.
        if ((Get-Service Windhawk).Status -ne 'Stopped') { throw 'Windhawk was started; exit it before installing.' }
        if (Test-Path -LiteralPath $key) { throw 'TaskTune was installed concurrently; refusing to overwrite.' }
        New-Item -ItemType Directory -Path $sourceDir -Force | Out-Null
        New-Item -ItemType Directory -Path $dllDir -Force | Out-Null
        Copy-Item -LiteralPath $source -Destination (Join-Path $sourceDir ($id + '.wh.cpp'))
        Copy-Item -LiteralPath $dll -Destination (Join-Path $dllDir $manifest.dll)
        foreach ($pair in $runtimePairs) {
            $to = Join-Path $dllDir $pair[1]
            if (-not (Test-Path -LiteralPath $to)) { Copy-Item -LiteralPath (Join-Path $compilerRuntime $pair[0]) -Destination $to }
        }
        New-Item -Path $key -Force | Out-Null
        New-ItemProperty -Path $key -Name Disabled -PropertyType DWord -Value 1 | Out-Null
        foreach ($entry in @{LibraryFileName=$manifest.dll;Version=$manifest.version;Include='explorer.exe';Exclude='';Architecture='x86-64'}.GetEnumerator()) {
            New-ItemProperty -Path $key -Name $entry.Key -Value $entry.Value -PropertyType String | Out-Null
        }
        foreach ($name in @('LoggingEnabled','DebugLoggingEnabled','IncludeExcludeCustomOnly','PatternsMatchCriticalSystemProcesses')) {
            New-ItemProperty -Path $key -Name $name -Value 0 -PropertyType DWord | Out-Null
        }
        $settingsKey = Join-Path $key 'Settings'
        New-Item -Path $settingsKey -Force | Out-Null
        foreach ($property in $manifest.settings.PSObject.Properties) {
            $type = if ($property.Value -is [string]) { 'String' } else { 'DWord' }
            New-ItemProperty -Path $settingsKey -Name $property.Name -Value $property.Value -PropertyType $type | Out-Null
        }
        New-ItemProperty -Path $key -Name SettingsChangeTime -Value ([int][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()) -PropertyType DWord | Out-Null
        if (Test-Path -LiteralPath $oldKey) {
            Get-ItemProperty -LiteralPath $oldKey | Select-Object Disabled,LibraryFileName | Format-List
            Set-ItemProperty -LiteralPath $oldKey -Name Disabled -Value 1
            Write-Output 'Previous Native Taskbar Media Controller disabled to prevent loading both mods.'
        }
        Write-Output 'Installed TaskTune DISABLED. Nothing was loaded into Explorer.'
        Write-Output 'Open Windhawk, find TaskTune Media (local fork) under installed mods, then enable it when ready to test.'
    }
} catch {
    Write-Output ('FAILED: ' + $_.Exception.Message)
    Stop-Transcript | Out-Null
    exit 1
}
Stop-Transcript | Out-Null
