# Capture only the taskbar, not the rest of the desktop. No upload/publication.
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class TaskTuneCapture {
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left,Top,Right,Bottom; }
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr FindWindow(string cls,string title);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hwnd,out RECT rect);
    [DllImport("user32.dll")] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
}
'@
$previous = [TaskTuneCapture]::SetThreadDpiAwarenessContext([IntPtr](-4))
try {
    $window = [TaskTuneCapture]::FindWindow('Shell_TrayWnd',$null)
    $rect = [TaskTuneCapture+RECT]::new()
    if ($window -eq [IntPtr]::Zero -or -not [TaskTuneCapture]::GetWindowRect($window,[ref]$rect)) { throw 'Cannot locate taskbar.' }
    $width = $rect.Right-$rect.Left; $height = $rect.Bottom-$rect.Top
    if ($width -lt 10 -or $height -lt 10 -or $width -gt 1024 -or $height -gt 8192) { throw 'Unexpected taskbar bounds; no capture taken.' }
    $folder = Join-Path (Split-Path $PSScriptRoot -Parent) ('dist\capture-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
    New-Item -ItemType Directory -Path $folder | Out-Null
    foreach ($name in @('a','b')) {
        if ($name -eq 'b') { Start-Sleep -Milliseconds 1250 }
        $image = [System.Drawing.Bitmap]::new($width,$height)
        $graphics = [System.Drawing.Graphics]::FromImage($image)
        try {
            $graphics.CopyFromScreen($rect.Left,$rect.Top,0,0,[System.Drawing.Size]::new($width,$height))
            $path = Join-Path $folder ($name + '.png')
            $image.Save($path,[System.Drawing.Imaging.ImageFormat]::Png)
            Write-Output $path
        } finally { $graphics.Dispose(); $image.Dispose() }
    }
} finally { [void][TaskTuneCapture]::SetThreadDpiAwarenessContext($previous) }
