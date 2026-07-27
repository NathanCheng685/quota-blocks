#Requires -Version 5.1
<#
.SYNOPSIS
  Publishes Quota Blocks into %LOCALAPPDATA%\Programs\QuotaBlocks, registers
  launch at login, and starts it. Safe to re-run to update in place.
#>
[CmdletBinding()]
param(
    [switch]$NoLaunchAtLogin,
    [switch]$NoStart
)

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$project = Join-Path $root 'QuotaBlocksWin.csproj'
$install = Join-Path $env:LOCALAPPDATA 'Programs\QuotaBlocks'
$exe = Join-Path $install 'QuotaBlocks.exe'

if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
    throw '找不到 dotnet。请先安装 .NET 8 SDK: winget install Microsoft.DotNet.SDK.8'
}

Write-Host '停止正在运行的实例…' -ForegroundColor Cyan
Get-Process QuotaBlocks -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Milliseconds 500

Write-Host "发布到 $install …" -ForegroundColor Cyan
dotnet publish $project -c Release -o $install --nologo -v quiet
if ($LASTEXITCODE -ne 0) { throw "发布失败（退出码 $LASTEXITCODE）" }

$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
if ($NoLaunchAtLogin) {
    Remove-ItemProperty $runKey -Name QuotaBlocks -ErrorAction SilentlyContinue
    Write-Host '开机自动启动：已关闭' -ForegroundColor Yellow
}
else {
    Set-ItemProperty $runKey -Name QuotaBlocks -Value "`"$exe`""
    Write-Host '开机自动启动：已开启' -ForegroundColor Green
}

if (-not $NoStart) {
    Start-Process $exe
    Write-Host '已启动，看屏幕左下角。' -ForegroundColor Green
}
