#Requires -Version 5.0
<#
.SYNOPSIS
    启动 whisper.cpp（由 wanggang-run-oss 生成）。实际逻辑按 PowerShell 7 执行。
.DESCRIPTION
    主路径：无参运行后交互选择 CLI 样例转写或 HTTP server。
.PARAMETER Mode
    direct = 本机直接运行；docker = 未配置（官方镜像多为 Linux）。
.PARAMETER Port
    仅当最终只启动一个需端口的服务时，作为该服务的端口搜索起点。
.PARAMETER Service
    内部/自动化用：跳过菜单，直接启动指定 Id。日常请无参走交互。
.PARAMETER Audio
    CLI 模式下的音频路径，默认 samples\jfk.wav。
.PARAMETER Model
    模型路径，默认 models\ggml-base.en.bin。
#>
[CmdletBinding()]
param(
    [ValidateSet('direct', 'docker')]
    [string]$Mode = 'direct',

    [int]$Port = 0,

    [string]$Service = '',

    [string]$Audio = '',

    [string]$Model = ''
)

$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSVersion.Major -lt 7) {
    $pwsh = Get-Command pwsh -ErrorAction SilentlyContinue
    if (-not $pwsh) {
        throw '未找到 PowerShell 7 (pwsh)。请先全局安装：winget install --id Microsoft.PowerShell -e'
    }
    $argList = @('-NoProfile', '-File', $PSCommandPath)
    foreach ($key in $PSBoundParameters.Keys) {
        $argList += "-$key"
        $val = $PSBoundParameters[$key]
        if ($val -isnot [System.Management.Automation.SwitchParameter]) {
            $argList += [string]$val
        }
    }
    & $pwsh.Source @argList
    exit $LASTEXITCODE
}

Set-Location $PSScriptRoot

$FfmpegBin = 'E:\Programs\ffmpeg-master-latest-win64-gpl\bin'
if (Test-Path $FfmpegBin) {
    $env:Path = "$FfmpegBin;$env:Path"
} else {
    Write-Warning "未找到本机 ffmpeg：$FfmpegBin"
}

function Show-GpuStatus {
    $smi = Get-Command nvidia-smi -ErrorAction SilentlyContinue
    if (-not $smi) {
        Write-Warning '未检测到 nvidia-smi，跳过 GPU 检查。'
        return
    }
    Write-Host '=== GPU 状态 ===' -ForegroundColor Cyan
    & nvidia-smi --query-gpu=name,memory.total,memory.used,memory.free,utilization.gpu --format=csv
}

function Test-PortBusy {
    param([int]$TargetPort)
    $listener = $null
    try {
        $listener = New-Object System.Net.Sockets.TcpListener ([System.Net.IPAddress]::Loopback, $TargetPort)
        $listener.Start()
        return $false
    } catch {
        return $true
    } finally {
        if ($null -ne $listener) { $listener.Stop() }
    }
}

function Get-FreePort {
    param(
        [int]$StartPort,
        [int]$MaxTries = 50
    )
    if ($StartPort -lt 1) { $StartPort = 1024 }
    $end = $StartPort + $MaxTries - 1
    if ($end -gt 65535) { $end = 65535 }
    $p = $StartPort
    while ($p -le $end) {
        if (-not (Test-PortBusy -TargetPort $p)) {
            if ($p -ne $StartPort) {
                Write-Host "端口 $StartPort 已占用，顺延到 $p" -ForegroundColor Yellow
            }
            return $p
        }
        $p++
    }
    throw "从 $StartPort 起连续探测均被占用，放弃。"
}

function Select-ServicesInteractive {
    param([object[]]$AllServices)

    if ($AllServices.Count -eq 0) {
        throw '未配置 $Services，请按项目改写模板。'
    }
    if ($AllServices.Count -eq 1) {
        Write-Host "仅一个服务，直接启动：$($AllServices[0].Label)" -ForegroundColor Cyan
        return @($AllServices[0])
    }

    Write-Host ''
    Write-Host '=== 启动哪些服务？===' -ForegroundColor Cyan
    for ($i = 0; $i -lt $AllServices.Count; $i++) {
        $svc = $AllServices[$i]
        $portHint = if ($svc.NeedsPort) { "端口起点 $($svc.PreferredPort)" } else { '无需端口' }
        Write-Host ("  [{0}] {1}  ({2})" -f ($i + 1), $svc.Label, $portHint)
    }
    Write-Host ("  [{0}] 全部开" -f ($AllServices.Count + 1))
    Write-Host '  [0] 取消'
    Write-Host ''

    $defaultChoice = '1'
    $raw = Read-Host "请选择（可多选，逗号分隔，如 1,2；默认 $defaultChoice）"
    if ([string]::IsNullOrWhiteSpace($raw)) { $raw = $defaultChoice }

    if ($raw.Trim() -eq '0') {
        throw '已取消启动。'
    }

    $allIndex = $AllServices.Count + 1
    $parts = $raw.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
    $selected = [System.Collections.Generic.List[object]]::new()

    foreach ($part in $parts) {
        $n = 0
        if (-not [int]::TryParse($part, [ref]$n)) {
            throw "无效选项：$part"
        }
        if ($n -eq $allIndex) {
            return @($AllServices)
        }
        if ($n -lt 1 -or $n -gt $AllServices.Count) {
            throw "选项超出范围：$n"
        }
        $selected.Add($AllServices[$n - 1])
    }

    if ($selected.Count -eq 0) {
        throw '未选择任何服务。'
    }

    $byId = [ordered]@{}
    foreach ($s in $selected) { $byId[$s.Id] = $s }
    return @($byId.Values)
}

function Assert-GpuOkForSelection {
    param([object[]]$Selected)

    $gpuServices = @($Selected | Where-Object { $_.UsesGpu })
    if ($gpuServices.Count -le 1) { return }

    $labels = ($gpuServices | ForEach-Object { $_.Label }) -join ', '
    Write-Host ''
    Write-Host "已选多个占卡服务：$labels" -ForegroundColor Yellow
    Write-Host '16GB 显存下同时加载多个推理服务容易 OOM。请确认剩余显存足够，或改回只开一个。' -ForegroundColor Yellow
    $confirm = Read-Host '仍要继续？[y/N]'
    if ($confirm -notmatch '^[yY]') {
        throw '已取消：多服务占卡未确认。'
    }
}

function Resolve-WhisperExe {
    param([string]$Name)
    $candidates = @(
        (Join-Path $PSScriptRoot "build\bin\Release\$Name.exe"),
        (Join-Path $PSScriptRoot "build\bin\$Name.exe"),
        (Join-Path $PSScriptRoot "build\Release\$Name.exe")
    )
    foreach ($c in $candidates) {
        if (Test-Path $c) { return $c }
    }
    throw "未找到 $Name.exe。请先执行：cmake -B build; cmake --build build -j --config Release"
}

function Resolve-DefaultModel {
    param([string]$Override)
    if ($Override) { return $Override }
    $p = Join-Path $PSScriptRoot 'models\ggml-base.en.bin'
    if (-not (Test-Path $p)) {
        throw "缺少模型：$p`n请先下载：见 RUN.md（hf-mirror.com / download-ggml-model）"
    }
    return $p
}

function Resolve-DefaultAudio {
    param([string]$Override)
    if ($Override) { return $Override }
    $p = Join-Path $PSScriptRoot 'samples\jfk.wav'
    if (-not (Test-Path $p)) {
        throw "缺少样例音频：$p"
    }
    return $p
}

$Services = @(
    [pscustomobject]@{
        Id            = 'cli'
        Label         = 'cli（whisper-cli 样例转写 jfk.wav）'
        PreferredPort = 0
        NeedsPort     = $false
        UsesGpu       = $false
    }
    [pscustomobject]@{
        Id            = 'server'
        Label         = 'server（whisper-server HTTP）'
        PreferredPort = 8080
        NeedsPort     = $true
        UsesGpu       = $false
    }
)

function Start-ProjectService {
    param(
        [Parameter(Mandatory)]
        [object]$Service,

        [Parameter(Mandatory)]
        [string]$RunMode,

        [int]$ListenPort = 0
    )

    if ($RunMode -eq 'docker') {
        throw '本机脚本未配置 docker 模式；请用 -Mode direct，或自行参考官方 ghcr.io/ggml-org/whisper.cpp 镜像。'
    }

    $modelPath = Resolve-DefaultModel -Override $Model

    switch ($Service.Id) {
        'cli' {
            $exe = Resolve-WhisperExe -Name 'whisper-cli'
            $audioPath = Resolve-DefaultAudio -Override $Audio
            Write-Host "运行：$exe -m $modelPath -f $audioPath" -ForegroundColor Cyan
            & $exe -m $modelPath -f $audioPath
            if ($LASTEXITCODE -ne 0) {
                throw "whisper-cli 退出码 $LASTEXITCODE"
            }
            return
        }
        'server' {
            $exe = Resolve-WhisperExe -Name 'whisper-server'
            Write-Host "启动 server：$exe --host 127.0.0.1 --port $ListenPort -m $modelPath" -ForegroundColor Cyan
            Write-Host "健康检查：浏览器打开 http://127.0.0.1:$ListenPort 或向 /inference 上传 wav" -ForegroundColor Yellow
            & $exe -m $modelPath --host 127.0.0.1 --port $ListenPort
            return
        }
        default {
            throw "未知服务：$($Service.Id)"
        }
    }
}

Show-GpuStatus

if ($Service) {
    $match = @($Services | Where-Object { $_.Id -eq $Service })
    if ($match.Count -eq 0) {
        throw "未知服务 Id：$Service。可选：$($Services.Id -join ', ')"
    }
    $chosen = $match
} else {
    $chosen = Select-ServicesInteractive -AllServices $Services
    Assert-GpuOkForSelection -Selected $chosen
}

$multi = $chosen.Count -gt 1

if ($multi) {
    $started = @()
    foreach ($svc in $chosen) {
        $listen = 0
        if ($svc.NeedsPort) {
            $listen = Get-FreePort -StartPort $svc.PreferredPort
            Write-Host "$($svc.Label) 使用端口 $listen" -ForegroundColor Cyan
        }

        $argList = [System.Collections.Generic.List[string]]::new()
        $argList.AddRange([string[]]@('-NoProfile', '-File', $PSCommandPath, '-Mode', $Mode, '-Service', $svc.Id))
        if ($listen -gt 0) {
            $argList.Add('-Port')
            $argList.Add("$listen")
        }
        if ($Model) {
            $argList.Add('-Model')
            $argList.Add($Model)
        }
        if ($Audio) {
            $argList.Add('-Audio')
            $argList.Add($Audio)
        }

        $p = Start-Process -FilePath 'pwsh' -ArgumentList $argList -PassThru -WorkingDirectory $PSScriptRoot
        $started += [pscustomobject]@{ Id = $svc.Id; Label = $svc.Label; Port = $listen; Pid = $p.Id }
        Write-Host "已后台启动 $($svc.Label) PID=$($p.Id)" -ForegroundColor Green
    }

    Write-Host ''
    Write-Host '=== 已启动 ===' -ForegroundColor Cyan
    foreach ($s in $started) {
        $portInfo = if ($s.Port -gt 0) { " port=$($s.Port)" } else { '' }
        Write-Host ("- {0}{1} pid={2}" -f $s.Label, $portInfo, $s.Pid)
    }
    Write-Host '各服务在独立进程中运行；结束请自行停对应 PID。' -ForegroundColor Yellow
    return
}

$svc = $chosen[0]
$listen = 0
if ($svc.NeedsPort) {
    $startPort = $svc.PreferredPort
    if ($Port -gt 0) { $startPort = $Port }
    $listen = Get-FreePort -StartPort $startPort
    Write-Host "$($svc.Label) 使用端口 $listen" -ForegroundColor Cyan
}

Start-ProjectService -Service $svc -RunMode $Mode -ListenPort $listen