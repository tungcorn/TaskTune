# Build a static presentation around a real screenshot crop. No screen capture or upload.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$InputPath,
    [Parameter(Mandatory)][ValidateRange(0,32768)][int]$X,
    [Parameter(Mandatory)][ValidateRange(0,32768)][int]$Y,
    [Parameter(Mandatory)][ValidateRange(1,4096)][int]$Width,
    [Parameter(Mandatory)][ValidateRange(1,8192)][int]$Height,
    [string]$OutputPath = (Join-Path (Split-Path $PSScriptRoot -Parent) 'docs\images\demo.png')
)
$ErrorActionPreference = 'Stop'
if (Test-Path -LiteralPath $OutputPath) { throw 'Output exists. Choose a new output path; inspect it before replacing it.' }
Add-Type -AssemblyName System.Drawing
$source = [Drawing.Bitmap]::new((Resolve-Path -LiteralPath $InputPath).Path)
$canvas = [Drawing.Bitmap]::new(1000,560)
$graphics = [Drawing.Graphics]::FromImage($canvas)
$resources = [Collections.Generic.List[IDisposable]]::new()
function New-Brush([string]$Hex) {
    $brush = [Drawing.SolidBrush]::new([Drawing.ColorTranslator]::FromHtml($Hex))
    $resources.Add($brush)
    return $brush
}
function Add-Label([string]$Text, [float]$Size, [float]$Left, [float]$Top, [Drawing.Brush]$Brush, [bool]$Bold=$false) {
    $style = if ($Bold) { [Drawing.FontStyle]::Bold } else { [Drawing.FontStyle]::Regular }
    $font = [Drawing.Font]::new('Segoe UI',$Size,$style,[Drawing.GraphicsUnit]::Pixel)
    $resources.Add($font)
    $graphics.DrawString($Text,$font,$Brush,$Left,$Top)
}
try {
    if ($X+$Width -gt $source.Width -or $Y+$Height -gt $source.Height) { throw 'Crop extends beyond the input image.' }
    $background = New-Brush '#111720'
    $panel = New-Brush '#1b2430'
    $white = New-Brush '#f0f4f8'
    $muted = New-Brush '#aab9c9'
    $accent = New-Brush '#70dfc3'
    $graphics.FillRectangle($background,0,0,1000,560)
    $graphics.FillRectangle($accent,52,50,34,4)
    $graphics.TextRenderingHint = [Drawing.Text.TextRenderingHint]::AntiAliasGridFit
    Add-Label 'TaskTune Media' 48 48 76 $white $true
    Add-Label 'Media controls for a vertical Windows taskbar.' 23 52 145 $muted
    Add-Label 'Always in reach' 25 52 222 $white $true
    Add-Label 'Inline controls. No hover or click to reveal.' 20 52 259 $muted
    Add-Label 'Keep the disc spinning' 25 52 315 $white $true
    Add-Label 'Steady rotation powered by Windows Composition.' 20 52 352 $muted
    Add-Label 'Built on Island Media Controls' 20 52 436 $accent
    Add-Label 'Unofficial Windhawk fork / MIT-licensed source' 18 52 467 $muted
    $graphics.FillRectangle($panel,736,24,220,484)
    Add-Label 'REAL CAPTURE' 14 790 32 $accent $true
    $scale = [Math]::Min(2.0,[Math]::Min(160.0/$Width,410.0/$Height))
    $destinationWidth = [int][Math]::Round($Width*$scale)
    $destinationHeight = [int][Math]::Round($Height*$scale)
    $left = 736 + [int]((220-$destinationWidth)/2)
    $top = 72 + [int]((422-$destinationHeight)/2)
    $graphics.InterpolationMode = [Drawing.Drawing2D.InterpolationMode]::NearestNeighbor
    $graphics.PixelOffsetMode = [Drawing.Drawing2D.PixelOffsetMode]::Half
    $graphics.DrawImage($source,[Drawing.Rectangle]::new($left,$top,$destinationWidth,$destinationHeight),$X,$Y,$Width,$Height,[Drawing.GraphicsUnit]::Pixel)
    Add-Label 'Real screenshot crop / enlarged / static preview - not an animation demo' 15 52 525 $muted
    $destination = [IO.Path]::GetFullPath($OutputPath)
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destination)) | Out-Null
    # A fresh bitmap stores no original screenshot metadata.
    $canvas.Save($destination,[Drawing.Imaging.ImageFormat]::Png)
    Write-Output $destination
    Write-Output 'Review the entire output before sharing. Cropping alone does not guarantee privacy.'
} finally {
    foreach ($resource in $resources) { $resource.Dispose() }
    $graphics.Dispose()
    $canvas.Dispose()
    $source.Dispose()
}
