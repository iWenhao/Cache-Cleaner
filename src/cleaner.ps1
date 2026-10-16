# ------------------------------------------------------------
#  用法：
#    双击运行                    扫描后进入选择界面，回车即清理默认项
#    参数（在 cmd 里传入）：
#      -DryRun         只扫描，不删除任何文件
#      -Yes            跳过选择，直接清理默认项
#      -IncludeAdmin   额外列出需要管理员权限的项目（以管理员运行时自动列出）
#      -MinAgeDays N   只清理 N 天前修改的文件（注册表项不适用；回收站会被跳过）
#      -NoPause        结束立刻退出，不挂住窗口
#      -NoArrow        去掉快捷方式的小箭头（改注册表，需管理员；不删任何文件）
#      -RestoreArrow   还原快捷方式的小箭头
#    示例：一键清理缓存.bat -DryRun
# ------------------------------------------------------------
#  注：结束时的"挂住窗口不自动关闭"由批处理负责，不在 PowerShell 里等待

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$Host.UI.RawUI.WindowTitle = '一键清理缓存'

$DryRun = $false
$Yes = $false
$IncludeAdmin = $false
$NoPause = $false
$Report = $false
$NoArrow = $false
$RestoreArrow = $false
$MinAgeDays = 0
$script:ArgIssues = @()
for ($i = 0; $i -lt $args.Count; $i++) {
    $a = [string]$args[$i]
    if ($a -eq '-DryRun') { $DryRun = $true }
    elseif ($a -eq '-Yes') { $Yes = $true }
    elseif ($a -eq '-IncludeAdmin') { $IncludeAdmin = $true }
    elseif ($a -eq '-NoPause') { $NoPause = $true }
    elseif ($a -eq '-Report') { $Report = $true }
    elseif ($a -eq '-NoArrow') { $NoArrow = $true }
    elseif ($a -eq '-RestoreArrow') { $RestoreArrow = $true }
    elseif ($a -eq '-MinAgeDays') {
        $i++
        $n = ''
        if ($i -lt $args.Count) { $n = [string]$args[$i] }
        $v = 0
        if ([int]::TryParse($n, [ref]$v) -and $v -ge 0) { $MinAgeDays = $v }
        elseif ([string]::IsNullOrWhiteSpace($n)) { $script:ArgIssues += '-MinAgeDays 后面缺少天数，本次不按年龄过滤' }
        else { $script:ArgIssues += ('-MinAgeDays 的值 "{0}" 不是非负整数，本次不按年龄过滤' -f $n) }
    }
    else { $script:ArgIssues += ('未识别的参数 "{0}"，已忽略' -f $a) }
}

$script:Cutoff = $null
if ($MinAgeDays -gt 0) { $script:Cutoff = (Get-Date).AddDays(-$MinAgeDays) }

$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference   = 'SilentlyContinue'
$IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

function Format-Size($bytes) {
    if ($bytes -lt 0)   { return '未知' }
    if ($bytes -ge 1GB) { return ('{0:N2} GB' -f ($bytes / 1GB)) }
    if ($bytes -ge 1MB) { return ('{0:N1} MB' -f ($bytes / 1MB)) }
    if ($bytes -ge 1KB) { return ('{0:N0} KB' -f ($bytes / 1KB)) }
    return ('{0} B' -f $bytes)
}

function Get-DisplayWidth($s) {
    $w = 0
    foreach ($ch in $s.ToCharArray()) {
        $c = [int]$ch
        $wide = ($c -ge 0x1100 -and $c -le 0x115F) -or
                ($c -ge 0x2E80 -and $c -le 0xA4CF) -or
                ($c -ge 0xAC00 -and $c -le 0xD7A3) -or
                ($c -ge 0xF900 -and $c -le 0xFAFF) -or
                ($c -ge 0xFE30 -and $c -le 0xFE6F) -or
                ($c -ge 0xFF00 -and $c -le 0xFF60) -or
                ($c -ge 0xFFE0 -and $c -le 0xFFE6)
        if ($wide) { $w += 2 } else { $w += 1 }
    }
    return $w
}

function Pad-Right($s, $width) {
    return $s + (' ' * [math]::Max(0, $width - (Get-DisplayWidth $s)))
}

function Pad-Left($s, $width) {
    return (' ' * [math]::Max(0, $width - (Get-DisplayWidth $s))) + $s
}

function Test-Pattern($name, $patterns) {
    if (-not $patterns) { return $true }
    if ($patterns.Count -eq 0) { return $true }
    foreach ($p in $patterns) { if ($name -like $p) { return $true } }
    return $false
}

function Test-AgeOk($item) {
    if ($null -eq $script:Cutoff) { return $true }
    return ($item.LastWriteTime -lt $script:Cutoff)
}

function Get-FilesSafe($path, $recurse, $patterns) {
    if ([string]::IsNullOrWhiteSpace($path)) { return @() }
    if (-not (Test-Path -LiteralPath $path)) { return @() }
    $rootItem = Get-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    if ($null -eq $rootItem) { return @() }
    # 根目录自身是链接时不碰：删它等于删链接指向的真实内容
    if (($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return @() }
    $items = New-Object System.Collections.Generic.List[object]
    if ($recurse) {
        # 手动递归，两个原因：
        # 1) 目录联接不能下钻。穿过联接拿到的文件自身不带 ReparsePoint 标记，事后过滤拦不住。
        # 2) PowerShell 5.1 的 Get-ChildItem -Recurse 会整片漏掉子树。本机 pnpm store 实测：
        #    手动递归与 [IO.Directory]::EnumerateFiles 都是 99326 个文件，-Recurse 只有 22899，
        #    差的正好是 projects 整个子树（-Recurse 对它返回 0 个文件）。
        #    少报体积、该删的文件删不掉，而且清单和实删不一致更危险。
        $stack = New-Object System.Collections.Generic.Stack[string]
        $stack.Push($path)
        while ($stack.Count -gt 0) {
            $dir = $stack.Pop()
            foreach ($e in @(Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue)) {
                if ($e.PSIsContainer) {
                    if (($e.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) { $stack.Push($e.FullName) }
                } else {
                    $items.Add($e)
                }
            }
        }
    } else {
        foreach ($e in @(Get-ChildItem -LiteralPath $path -File -Force -ErrorAction SilentlyContinue)) {
            $items.Add($e)
        }
    }
    if (-not $patterns -or $patterns.Count -eq 0) { return $items.ToArray() }
    $filtered = New-Object System.Collections.Generic.List[object]
    foreach ($e in $items) { if (Test-Pattern $e.Name $patterns) { $filtered.Add($e) } }
    return $filtered.ToArray()
}

# 进度动画。不用后台线程：删除/统计循环每处理够多个文件自己刷一帧，
# 这样画面只在真干活时动，也不会和 Write-Host 的输出互相打断。
# 输出被重定向时完全不画——日志文件里塞一堆 \r 是垃圾行。
$script:SpinFrames = @('|', '/', '-', '\')
$script:SpinTick = 0
function Test-SpinOn { return (-not [Console]::IsOutputRedirected) }
function Write-Spin([int]$n, [string]$verb) {
    if (-not (Test-SpinOn)) { return }
    $script:SpinTick = ($script:SpinTick + 1) % $script:SpinFrames.Count
    [Console]::Write(("`r     {0}  已{1} {2} 个文件 ..." -f $script:SpinFrames[$script:SpinTick], $verb, $n))
}
function Stop-Spin {
    if (-not (Test-SpinOn)) { return }
    [Console]::Write("`r" + (' ' * 90) + "`r")
}

function Measure-One($t) {
    $bytes = 0L
    $count = 0
    Write-Spin 0 '扫描'
    foreach ($p in $t.Paths) {
        foreach ($f in (Get-FilesSafe $p $t.Recurse $t.Patterns)) {
            if (-not (Test-AgeOk $f)) { continue }
            $bytes += $f.Length
            $count++
            if (($count % 500) -eq 0) { Write-Spin $count '扫描' }
        }
    }
    return [pscustomobject]@{ Bytes = $bytes; Files = $count }
}

function Clear-One($t) {
    $r = [pscustomobject]@{ Freed = 0L; Deleted = 0; Skipped = 0 }
    Write-Spin 0 '处理'
    foreach ($p in $t.Paths) {
        foreach ($f in (Get-FilesSafe $p $t.Recurse $t.Patterns)) {
            if (-not (Test-AgeOk $f)) { continue }
            try {
                Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop
                $r.Deleted++
                $r.Freed += $f.Length
            } catch {
                $r.Skipped++
            }
            if ((($r.Deleted + $r.Skipped) % 200) -eq 0) { Write-Spin ($r.Deleted + $r.Skipped) '处理' }
        }
    }
    return $r
}

function Get-PnpmStorePath {
    $cmd = Get-Command pnpm -ErrorAction SilentlyContinue
    if (-not $cmd) { return $null }
    $p = (& pnpm store path 2>$null | Select-Object -First 1)
    if ([string]::IsNullOrWhiteSpace($p)) { return $null }
    return $p.Trim()
}

# 各文件系统卷上的回收站桶，不要只盯着 C:
function Get-RecycleBinPaths {
    $out = @()
    foreach ($d in @(Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue)) {
        if (-not $d.Root) { continue }
        $p = Join-Path $d.Root '$Recycle.Bin'
        if (Test-Path -LiteralPath $p) { $out += $p }
    }
    return @($out)
}

# 直接解析 .lnk 二进制，不依赖 WScript.Shell
function Get-LnkTarget([string]$lnkPath) {
    try {
        $b = [System.IO.File]::ReadAllBytes($lnkPath)
        if ($b.Length -lt 0x4C) { return $null }
        if ([BitConverter]::ToUInt32($b, 0) -ne 0x4C) { return $null }
        $flags = [BitConverter]::ToUInt32($b, 0x14)
        $pos = 0x4C
        if ($flags -band 1) {
            if ($pos + 2 -gt $b.Length) { return $null }
            $pos += 2 + [BitConverter]::ToUInt16($b, $pos)
        }
        if (-not ($flags -band 2)) { return $null }
        if ($pos + 0x24 -gt $b.Length) { return $null }
        $hdr = [BitConverter]::ToUInt32($b, $pos + 4)
        if ($hdr -ge 0x24) {
            $bOff = [BitConverter]::ToUInt32($b, $pos + 0x1C)
            $sOff = [BitConverter]::ToUInt32($b, $pos + 0x20)
            # 偏移异常就当解析不出来。掉到下面 ANSI 分支会拿 VolumeID 偏移当路径读，
            # 拼出一个不存在的路径，正常快捷方式会被判成残留而删掉。
            if ($bOff -le 0) { return $null }
            $base = ''; $i = $pos + $bOff
            while ($i + 1 -lt $b.Length) { $u = [BitConverter]::ToUInt16($b, $i); if ($u -eq 0) { break }; $base += [char]$u; $i += 2 }
            $suff = ''
            if ($sOff -gt 0) {
                $j = $pos + $sOff
                while ($j + 1 -lt $b.Length) { $u = [BitConverter]::ToUInt16($b, $j); if ($u -eq 0) { break }; $suff += [char]$u; $j += 2 }
            }
            return ($base + $suff)
        }
        # 旧格式：LocalBasePath / CommonPathSuffix 以系统 ANSI 代码页存储。
        # 不能写 [Text.Encoding]::Default —— 它在 PowerShell 7 下是 UTF-8。
        $bOff = [BitConverter]::ToUInt32($b, $pos + 0x10)
        $sOff = [BitConverter]::ToUInt32($b, $pos + 0x18)
        if ($bOff -le 0 -or $sOff -le 0) { return $null }
        if ($pos + $bOff -ge $b.Length -or $pos + $sOff -ge $b.Length) { return $null }
        $enc = [System.Text.Encoding]::GetEncoding([System.Globalization.CultureInfo]::CurrentCulture.TextInfo.ANSICodePage)
        $bb = New-Object System.Collections.Generic.List[byte]
        $i = $pos + $bOff
        while ($i -lt $b.Length -and $b[$i] -ne 0) { $bb.Add($b[$i]); $i++ }
        $sb = New-Object System.Collections.Generic.List[byte]
        $j = $pos + $sOff
        while ($j -lt $b.Length -and $b[$j] -ne 0) { $sb.Add($b[$j]); $j++ }
        return ($enc.GetString($bb.ToArray()) + $enc.GetString($sb.ToArray()))
    } catch {
        return $null
    }
}

function Get-ExeFromCommand($cmd) {
    if (-not $cmd) { return $null }
    $exe = $null
    if ($cmd -match '^"([^"]+\.exe)"') { $exe = $Matches[1] }
    elseif ($cmd -match '^([^\s"]+\.exe)') { $exe = $Matches[1] }
    else { return $null }
    $exe = [Environment]::ExpandEnvironmentVariables($exe)
    if ($exe -match '[\\/]') { return $exe }
    # 裸文件名（如 notepad.exe）走 PATH 解析，查得到就不算残留
    $found = Get-Command $exe -CommandType Application -ErrorAction SilentlyContinue
    if ($found -and $found.Source) { return $found.Source }
    return $null
}

function Find-DeadShortcuts {
    $roots = @(
        [Environment]::GetFolderPath('Desktop')
        "$env:APPDATA\Microsoft\Windows\Start Menu\Programs"
        "$env:APPDATA\Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar"
    )
    $out = @()
    foreach ($r in $roots) {
        if ([string]::IsNullOrWhiteSpace($r)) { continue }
        if (-not (Test-Path -LiteralPath $r)) { continue }
        foreach ($l in (Get-FilesSafe $r $true @('*.lnk'))) {
            if (-not (Test-AgeOk $l)) { continue }
            $t = Get-LnkTarget $l.FullName
            if ([string]::IsNullOrWhiteSpace($t)) { continue }
            if ($t -match '^::\{' -or $t -match '^\\\\') { continue }
            if ($t -match '^([A-Za-z]):\\') { if (-not (Test-Path "$($Matches[1]):\")) { continue } }
            if (Test-Path -LiteralPath $t) { continue }
            $out += [pscustomobject]@{ Path = $l.FullName; Name = $l.Name; Target = $t }
        }
    }
    return @($out)
}

function Find-DeadAppRegs {
    $out = @()
    foreach ($hive in @(
        'HKCU:\SOFTWARE\Classes\Applications',
        'HKLM:\SOFTWARE\Classes\Applications',
        'HKLM:\SOFTWARE\WOW6432Node\Classes\Applications')) {
        if (-not (Test-Path $hive)) { continue }
        foreach ($k in @(Get-ChildItem $hive -ErrorAction SilentlyContinue)) {
            $cmd = (Get-ItemProperty "$($k.PSPath)\shell\open\command" -ErrorAction SilentlyContinue).'(default)'
            $exe = Get-ExeFromCommand $cmd
            if (-not $exe) { continue }
            if (Test-Path -LiteralPath $exe) { continue }
            $out += [pscustomobject]@{ Path = $k.PSPath; App = $k.PSChildName; Exe = $exe; Hive = $hive }
        }
    }
    return @($out)
}

function Find-DeadUninstall {
    $out = @()
    foreach ($hive in @(
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall')) {
        if (-not (Test-Path $hive)) { continue }
        foreach ($k in @(Get-ChildItem $hive -ErrorAction SilentlyContinue)) {
            $p = Get-ItemProperty $k.PSPath -ErrorAction SilentlyContinue
            if (-not $p.DisplayName) { continue }
            $il = ([string]$p.InstallLocation).Trim().Trim('"').TrimEnd('\')
            if ([string]::IsNullOrWhiteSpace($il)) { continue }
            if (Test-Path -LiteralPath $il) { continue }
            $out += [pscustomobject]@{ Path = $k.PSPath; Name = $p.DisplayName; Location = $il; Hive = $hive }
        }
    }
    return @($out)
}

function Find-OldVersions {
    $out = @()
    foreach ($root in @("$env:LOCALAPPDATA", "$env:LOCALAPPDATA\Programs")) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        foreach ($app in @(Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction SilentlyContinue)) {
            if (($app.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
            $vs = @(Get-ChildItem -LiteralPath $app.FullName -Directory -Force -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match '^app-[0-9]' -and (($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) })
            if ($vs.Count -lt 2) { continue }
            $parsed = @()
            $ok = $true
            foreach ($v in $vs) {
                $s = $v.Name.Substring(4)
                if ($s -match '^(\d+)\.(\d+)\.(\d+)') {
                    try { $parsed += [pscustomobject]@{ Dir = $v; Ver = [version]$Matches[0] } } catch { $ok = $false }
                } else { $ok = $false }
            }
            if (-not $ok) { continue }
            $sorted = @($parsed | Sort-Object Ver)
            for ($i = 0; $i -lt $sorted.Count - 1; $i++) {
                if (-not (Test-AgeOk $sorted[$i].Dir)) { continue }
                $out += $sorted[$i].Dir
            }
        }
    }
    return @($out)
}

$script:targets = @()
$script:nextId = 1

function Add-Target([hashtable]$s) {
    if (-not $s.ContainsKey('Kind'))        { $s.Kind = 'Files' }
    if (-not $s.ContainsKey('Recurse'))     { $s.Recurse = $true }
    if (-not $s.ContainsKey('Patterns'))    { $s.Patterns = @() }
    if (-not $s.ContainsKey('Paths'))       { $s.Paths = @() }
    if (-not $s.ContainsKey('Default'))     { $s.Default = $true }
    if (-not $s.ContainsKey('Admin'))       { $s.Admin = $false }
    if (-not $s.ContainsKey('Danger'))      { $s.Danger = $false }
    if (-not $s.ContainsKey('SizeUnknown')) { $s.SizeUnknown = $false }
    if (-not $s.ContainsKey('Note'))        { $s.Note = '' }
    $s.Id = $script:nextId
    $script:nextId++
    $script:targets += [pscustomobject]$s
}

# ---------- 收集目标 ----------

$updaterPaths = @()
Get-ChildItem -LiteralPath $env:LOCALAPPDATA -Directory -Force -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match 'updater$' } |
    ForEach-Object { $updaterPaths += $_.FullName }

$pkgPaths = @(
    "$env:APPDATA\npm-cache"
    "$env:LOCALAPPDATA\npm-cache"
    "$env:USERPROFILE\.npm-cache"
    "$env:LOCALAPPDATA\pnpm-cache"
    "$env:LOCALAPPDATA\Yarn\Cache"
    "$env:APPDATA\yarn-cache"
    "$env:USERPROFILE\.bun\install\cache"
    "$env:LOCALAPPDATA\.bun\install\cache"
    "$env:LOCALAPPDATA\.bun\cache"
    "$env:LOCALAPPDATA\pip\cache"
    "$env:LOCALAPPDATA\uv\cache"
)

$browserPaths = @()
foreach ($root in @("$env:LOCALAPPDATA\Google\Chrome\User Data", "$env:LOCALAPPDATA\Microsoft\Edge\User Data")) {
    if (-not (Test-Path -LiteralPath $root)) { continue }
    Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^Default$' -or $_.Name -match '^Profile \d+$' } |
        ForEach-Object {
            foreach ($sub in @('Cache', 'Code Cache', 'GPUCache')) {
                $full = Join-Path $_.FullName $sub
                if (Test-Path -LiteralPath $full) { $browserPaths += $full }
            }
        }
}
# Firefox 的 disk cache 在 LOCALAPPDATA 那份 profile 里，不在 Roaming 那份。
# 本机实测：Roaming\...\Profiles\yad34gi4.default-release-1737036297271 没有 cache2，
# cache2 1020.2 MB / 12649 文件在 LOCALAPPDATA 同名目录下。
$ffRoot = "$env:LOCALAPPDATA\Mozilla\Firefox\Profiles"
if (Test-Path -LiteralPath $ffRoot) {
    Get-ChildItem -LiteralPath $ffRoot -Directory -Force -ErrorAction SilentlyContinue |
        ForEach-Object {
            foreach ($sub in @('cache2', 'startupCache')) {
                $full = Join-Path $_.FullName $sub
                if (Test-Path -LiteralPath $full) { $browserPaths += $full }
            }
        }
}

# VS Code：只收纯缓存目录。User（设置/历史/workspaceStorage）、.vscode\extensions（插件本体）、
# Local Storage / Session Storage / WebStorage（站点数据）、logs（崩溃后还要看）都不碰。
$vscodePaths = @()
foreach ($codeRoot in @("$env:APPDATA\Code", "$env:APPDATA\Code - Insiders")) {
    if (-not (Test-Path -LiteralPath $codeRoot)) { continue }
    foreach ($sub in @('Cache', 'Code Cache', 'GPUCache', 'CachedData', 'CachedExtensionVSIXs',
                       'Crashpad', 'DawnCache', 'DawnGraphiteCache', 'DawnWebGPUCache')) {
        $full = Join-Path $codeRoot $sub
        if (Test-Path -LiteralPath $full) { $vscodePaths += $full }
    }
}

Add-Target @{
    Name    = '用户 Temp'
    Paths   = @($env:TEMP)
    Note    = '各类软件产生的临时文件'
}

Add-Target @{
    Name    = 'Updater 更新缓存'
    Paths   = $updaterPaths
    Default = $false
    Note    = '按目录名后缀匹配，需自行确认；只清内容，保留目录本身'
}

Add-Target @{
    Name    = '包管理器缓存'
    Paths   = $pkgPaths
    Note    = 'npm/yarn/bun/pip 下载缓存'
}

Add-Target @{
    Name    = 'pnpm store 瘦身'
    Kind    = 'Pnpm'
    Note    = 'pnpm store prune 只删无引用的包；左列是整个仓库体积'
}

Add-Target @{
    Name    = '浏览器缓存'
    Paths   = $browserPaths
    Note    = 'Chrome/Edge/Firefox，建议先关闭浏览器'
}

Add-Target @{
    Name    = 'VS Code 缓存'
    Paths   = $vscodePaths
    Note    = '只清 Cache/CachedData/CachedExtensionVSIXs/Crashpad 等，不动设置与插件本体；建议先关闭 VS Code'
}

Add-Target @{
    Name    = 'Windows 错误报告'
    Paths   = @("$env:LOCALAPPDATA\Microsoft\Windows\WER", "$env:APPDATA\Microsoft\Windows\WER")
    Note    = '崩溃转储与错误报告'
}

Add-Target @{
    Name     = '缩略图/图标缓存'
    Paths    = @("$env:LOCALAPPDATA\Microsoft\Windows\Explorer")
    Recurse  = $false
    Patterns = @('thumbcache_*.db', 'iconcache_*.db')
    Note     = '被资源管理器占用时跳过，重启后生效'
}

Add-Target @{
    Name    = '回收站'
    Kind    = 'RecycleBin'
    Paths   = (Get-RecycleBinPaths)
    Default = $false
    Danger  = $true
    Note    = '清空后不可恢复'
}

Add-Target @{
    Name    = '残留快捷方式'
    Kind    = 'Shortcut'
    Default = $false
    Danger  = $true
    Note    = '目标已失效的 .lnk（桌面/开始菜单/任务栏）'
}

Add-Target @{
    Name    = '打开方式残留'
    Kind    = 'OpenWith'
    Default = $false
    Danger  = $true
    Note    = '已卸载软件残留在「打开方式」里的条目'
}

Add-Target @{
    Name    = '卸载表残留'
    Kind    = 'Uninstall'
    Default = $false
    Danger  = $true
    Note    = '安装目录已消失的卸载条目'
}

Add-Target @{
    Name    = '旧版本残留'
    Kind    = 'OldVersion'
    Default = $false
    Danger  = $true
    Note    = 'Electron 应用留下的旧版本目录，整目录递归删除'
}

if ($IncludeAdmin -or $IsAdmin) {
    Add-Target @{
        Name   = 'Windows 更新缓存'
        Paths  = @("$env:SystemRoot\SoftwareDistribution\Download")
        Admin  = $true
        Default = $false
        Note   = '已安装的补丁不受影响'
    }
    Add-Target @{
        Name   = '传递优化缓存'
        Paths  = @("$env:SystemRoot\ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization")
        Admin  = $true
        Default = $false
        Note   = '更新分发用去重缓存'
    }
    Add-Target @{
        Name   = '系统 Temp'
        Paths  = @("$env:SystemRoot\Temp")
        Admin  = $true
        Default = $false
        Note   = 'Windows 目录临时文件'
    }
    Add-Target @{
        Name   = 'Windows.old'
        Kind   = 'WinOld'
        Paths  = @((Join-Path (Split-Path $env:SystemRoot -Parent) 'Windows.old'))
        Admin  = $true
        Default = $false
        Danger = $true
        SizeUnknown = $true
        Note   = '删除后无法回退旧系统，失败请用磁盘清理'
    }
}

# 放在管理员块外面：普通用户也要能在表格里看到这一行，选中时才提示需要提权
Add-Target @{
    Name    = '快捷方式小箭头'
    Kind    = 'Arrow'
    Paths   = @()
    Admin   = $true
    Default = $false
    Danger  = $true
    Note    = '移除 .lnk/.pif/.url 的 IsShortcut 值，改注册表不删文件；重启资源管理器才生效'
}

# ---------- 扫描 ----------

Write-Host ''
Write-Host '  ██   ██   ██  █  █ ████       ██  █    ████  ██  █  █ ████ ███' -ForegroundColor Cyan
Write-Host ' █  █ █  █ █  █ █  █ █         █  █ █    █    █  █ ██ █ █    █  █' -ForegroundColor Cyan
Write-Host ' █    ████ █    ████ ███       █    █    ███  ████ █ ██ ███  ███' -ForegroundColor Cyan
Write-Host ' █  █ █  █ █  █ █  █ █         █  █ █    █    █  █ █  █ █    █ █' -ForegroundColor DarkCyan
Write-Host '  ██  █  █  ██  █  █ ████       ██  ████ ████ █  █ █  █ ████ █  █' -ForegroundColor DarkCyan
Write-Host ''
Write-Host '              一键清理缓存   ·   Cache Cleaner' -ForegroundColor Gray
Write-Host ''
if ($IsAdmin) {
    Write-Host '  权限: 管理员（已解锁系统级项目）' -ForegroundColor Green
} else {
    Write-Host '  权限: 普通用户' -ForegroundColor DarkYellow
    Write-Host '  提示: 右键本文件 → 以管理员身份运行，可解锁' -ForegroundColor DarkYellow
    Write-Host '        「Windows 更新缓存 / 传递优化缓存 / 系统 Temp / Windows.old」' -ForegroundColor DarkYellow
}
Write-Host ''
if ($script:ArgIssues.Count -gt 0) {
    foreach ($w in $script:ArgIssues) {
        Write-Host ('  参数提示: {0}' -f $w) -ForegroundColor Yellow
    }
    if ($script:ArgIssues.Count -gt 0 -and -not $DryRun -and -not $Report -and -not $NoArrow -and -not $RestoreArrow) {
        Write-Host '  若本意是只看不删，请改用 -DryRun 再运行一次。' -ForegroundColor Yellow
    }
    Write-Host ''
}

# 小箭头由文件类注册表项上的 IsShortcut 值触发。这里只动 .lnk / .pif / .url 三个类。
# 本机实测还定义该值的另外几个类（IE.AssocFile.URL、Microsoft.Website、WSHFile、
# Application.Reference）没有验证过它们是否也参与画箭头，所以不碰。
$script:ArrowClasses = @('lnkfile', 'piffile', 'InternetShortcut')

function Get-ShortcutArrowPending {
    # 读取不需要管理员（写入才需要：HKCR 的写实际落在 HKLM\SOFTWARE\Classes）
    $pending = @()
    try {
        $cr = [Microsoft.Win32.Registry]::ClassesRoot
        foreach ($c in $script:ArrowClasses) {
            $k = $cr.OpenSubKey($c, $false)
            if ($null -eq $k) { continue }
            if (@($k.GetValueNames()) -contains 'IsShortcut') { $pending += $c }
            $k.Close()
        }
    } catch { }
    return @($pending)
}

function Set-ShortcutArrow([bool]$remove) {
    $removed = 0; $restored = 0; $unchanged = 0; $failed = 0
    try { $cr = [Microsoft.Win32.Registry]::ClassesRoot } catch { $cr = $null }
    foreach ($c in $script:ArrowClasses) {
        try {
            $k = $cr.OpenSubKey($c, $true)
            if ($null -eq $k) {
                Write-Host ('    {0,-18} 类不存在，跳过' -f $c) -ForegroundColor DarkGray
                $unchanged++
                continue
            }
            $has = @($k.GetValueNames()) -contains 'IsShortcut'
            if ($remove) {
                if ($has) {
                    $k.DeleteValue('IsShortcut')
                    Write-Host ('    {0,-18} 已移除 IsShortcut' -f $c) -ForegroundColor Green
                    $removed++
                } else {
                    Write-Host ('    {0,-18} 本来就没有' -f $c) -ForegroundColor DarkGray
                    $unchanged++
                }
            } else {
                if ($has) {
                    Write-Host ('    {0,-18} 已存在，未改动' -f $c) -ForegroundColor DarkGray
                    $unchanged++
                } else {
                    $k.SetValue('IsShortcut', '', [Microsoft.Win32.RegistryValueKind]::String)
                    Write-Host ('    {0,-18} 已写回空 String 值' -f $c) -ForegroundColor Green
                    $restored++
                }
            }
            $k.Close()
        } catch {
            Write-Host ('    {0,-18} 失败：{1}' -f $c, $_.Exception.Message) -ForegroundColor Red
            $failed++
        }
    }
    return [pscustomobject]@{ Removed = $removed; Restored = $restored; Unchanged = $unchanged; Failed = $failed }
}

function Show-ArrowRestartHint {
    Write-Host ''
    Write-Host '  生效要重启资源管理器：任务管理器 → Windows 资源管理器 → 重新启动，或注销一次。' -ForegroundColor Cyan
    Write-Host '  这一步不代你做：taskkill /f /im explorer.exe 会连带关掉你所有已打开的文件夹窗口，' -ForegroundColor DarkGray
    Write-Host '  而且从提权进程重新拉起的 explorer 可能让之后的所有程序都跟着提权。' -ForegroundColor DarkGray
}

if ($NoArrow -or $RestoreArrow) {
    if ($NoArrow -and $RestoreArrow) {
        Write-Host '  -NoArrow 与 -RestoreArrow 不能同时给，本次什么都不改。' -ForegroundColor Red
        return
    }
    $remove = [bool]$NoArrow
    Write-Host ('  快捷方式小箭头：{0}（只改注册表，不删除任何文件）' -f $(if ($remove) { '去掉' } else { '还原' })) -ForegroundColor White
    if (-not $IsAdmin) {
        Write-Host ''
        Write-Host '  需要管理员权限。HKCR 的写入实际落在 HKLM\SOFTWARE\Classes，' -ForegroundColor Red
        Write-Host '  本机实测：普通用户申请写句柄直接 UnauthorizedAccessException。' -ForegroundColor Red
        Write-Host '  请右键本文件 → 以管理员身份运行，再执行一次。' -ForegroundColor DarkYellow
        return
    }
    $ar = Set-ShortcutArrow $remove
    Write-Host ('    合计：改动 {0} 个，未变 {1} 个，失败 {2} 个' -f ($ar.Removed + $ar.Restored), $ar.Unchanged, $ar.Failed) -ForegroundColor White
    Show-ArrowRestartHint
    return
}

if ($Report) {
    Write-Host '  正在枚举疑似残留的用户目录（只读，不删除任何东西），请稍候...' -ForegroundColor DarkGray
    Write-Host ''
    $known = @{}
    foreach ($hive in @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall')) {
        if (-not (Test-Path $hive)) { continue }
        foreach ($k in @(Get-ChildItem $hive -ErrorAction SilentlyContinue)) {
            $p = Get-ItemProperty $k.PSPath -ErrorAction SilentlyContinue
            if ($p.DisplayName)     { $known[($p.DisplayName -replace '[^a-zA-Z0-9]', '').ToLower()] = 1 }
            if ($p.InstallLocation) { $known[(($p.InstallLocation.TrimEnd('\') -split '\\')[-1] -replace '[^a-zA-Z0-9]', '').ToLower()] = 1 }
            if ($p.DisplayIcon) {
                $ic = (($p.DisplayIcon -replace '^"', '') -split ',')[0]
                if ($ic) { $known[((($ic -split '\\')[-2]) -replace '[^a-zA-Z0-9]', '').ToLower()] = 1 }
            }
        }
    }
    $skip = '^(Microsoft|Windows|WindowsPowerShell|Adobe|Google|Mozilla|NVIDIA|Intel|Apple|Packages|Temp|CrashDumps|D3DSCache|ElevatedDiagnostics|ConnectedDevicesPlatform|IconCache|GroupPolicy|VirtualStore|LocalLow|PeerDistRepub|Publishers|SquirrelTemp|FontCache|Comms|UninstallInfo|ADAM)$'
    $cands = @()
    foreach ($r in @("$env:APPDATA", "$env:LOCALAPPDATA")) {
        if (-not (Test-Path -LiteralPath $r)) { continue }
        foreach ($d in @(Get-ChildItem -LiteralPath $r -Directory -Force -ErrorAction SilentlyContinue)) {
            $key = ($d.Name -replace '[^a-zA-Z0-9]', '').ToLower()
            if ($key.Length -lt 2) { continue }
            if ($known.ContainsKey($key)) { continue }
            if ($d.Name -match $skip) { continue }
            $files = Get-FilesSafe $d.FullName $true @()
            $sum = 0L
            $newest = $null
            foreach ($f in $files) {
                $sum += $f.Length
                if ($null -eq $newest -or $f.LastWriteTime -gt $newest) { $newest = $f.LastWriteTime }
            }
            $cands += [pscustomobject]@{
                MB = [math]::Round($sum / 1MB, 1); Files = $files.Count; Full = $d.FullName
                Newest = $newest; Days = if ($newest) { [math]::Round(((Get-Date) - $newest).TotalDays) } else { 99999 }
            }
        }
    }
    $cands = @($cands | Sort-Object MB -Descending)
    $totalMB = [math]::Round(($cands | Measure-Object -Property MB -Sum).Sum, 1)
    Write-Host ('  候选 {0} 个，合计约 {1} MB' -f $cands.Count, $totalMB) -ForegroundColor White
    Write-Host ''
    Write-Host '  重要：以下只是"名字在卸载表里查不到"的目录，里面很可能是' -ForegroundColor Yellow
    Write-Host '        正在使用的软件数据（如微信、钉钉、WPS），请勿直接删除。' -ForegroundColor Yellow
    Write-Host '        本脚本不会自动清理这类目录，仅列出供你人工判断。' -ForegroundColor Yellow
    Write-Host '        判断依据看「最近修改」：日期很近的说明仍在被读写。' -ForegroundColor Yellow
    Write-Host ''
    foreach ($c in ($cands | Select-Object -First 25)) {
        if ($null -eq $c.Newest) { $age = '  无文件' }
        else { $age = $c.Newest.ToString('yyyy-MM-dd') }
        if ($c.Days -le 30) { $mark = '[近期在用]' } elseif ($c.Days -le 180) { $mark = '[半年内]' } else { $mark = '[长期未动]' }
        $color = if ($c.Days -le 30) { 'DarkGray' } elseif ($c.Days -le 180) { 'Gray' } else { 'White' }
        Write-Host ('  {0,9} MB  最近修改 {1}  {2,-10} {3}' -f $c.MB, $age, $mark, $c.Full) -ForegroundColor $color
    }
    if ($cands.Count -gt 25) { Write-Host ('  ... 另有 {0} 个未列出' -f ($cands.Count - 25)) -ForegroundColor DarkGray }
    return
}

Write-Host '  正在扫描各项目占用，请稍候...' -ForegroundColor DarkGray
Write-Host ''

$pnpmStore = Get-PnpmStorePath

foreach ($t in $targets) {
    if ($t.Kind -eq 'Pnpm') {
        if ($pnpmStore) {
            $m = Measure-One ([pscustomobject]@{ Paths = @($pnpmStore); Recurse = $true; Patterns = @() })
            $t | Add-Member -MemberType NoteProperty -Name Bytes -Value $m.Bytes -Force
            $t | Add-Member -MemberType NoteProperty -Name FileCount -Value $m.Files -Force
            $t | Add-Member -MemberType NoteProperty -Name Available -Value $true -Force
        } else {
            $t | Add-Member -MemberType NoteProperty -Name Bytes -Value 0L -Force
            $t | Add-Member -MemberType NoteProperty -Name FileCount -Value 0 -Force
            $t | Add-Member -MemberType NoteProperty -Name Available -Value $false -Force
        }
        continue
    }
    if ($t.Kind -eq 'RecycleBin') {
        $m = Measure-One ([pscustomobject]@{ Paths = $t.Paths; Recurse = $true; Patterns = @() })
        $t | Add-Member -MemberType NoteProperty -Name Bytes -Value $m.Bytes -Force
        $t | Add-Member -MemberType NoteProperty -Name FileCount -Value $m.Files -Force
        $t | Add-Member -MemberType NoteProperty -Name Available -Value ($m.Files -gt 0) -Force
        continue
    }
    if ($t.Kind -eq 'WinOld') {
        $t | Add-Member -MemberType NoteProperty -Name Bytes -Value -1L -Force
        $t | Add-Member -MemberType NoteProperty -Name FileCount -Value 0 -Force
        $t | Add-Member -MemberType NoteProperty -Name Available -Value (Test-Path -LiteralPath $t.Paths[0]) -Force
        continue
    }
    if ($t.Kind -eq 'Arrow') {
        $ap = Get-ShortcutArrowPending
        $t | Add-Member -MemberType NoteProperty -Name Items -Value $ap -Force
        $t | Add-Member -MemberType NoteProperty -Name Bytes -Value 0L -Force
        $t | Add-Member -MemberType NoteProperty -Name FileCount -Value $ap.Count -Force
        $t | Add-Member -MemberType NoteProperty -Name Available -Value ($ap.Count -gt 0) -Force
        continue
    }
    if ($t.Kind -eq 'Shortcut') {
        $sc = Find-DeadShortcuts
        $t | Add-Member -MemberType NoteProperty -Name Items -Value $sc -Force
        $t | Add-Member -MemberType NoteProperty -Name Bytes -Value 0L -Force
        $t | Add-Member -MemberType NoteProperty -Name FileCount -Value $sc.Count -Force
        $t | Add-Member -MemberType NoteProperty -Name Available -Value ($sc.Count -gt 0) -Force
        continue
    }
    if ($t.Kind -eq 'OpenWith') {
        $ar = Find-DeadAppRegs
        $t | Add-Member -MemberType NoteProperty -Name Items -Value $ar -Force
        $t | Add-Member -MemberType NoteProperty -Name Bytes -Value 0L -Force
        $t | Add-Member -MemberType NoteProperty -Name FileCount -Value $ar.Count -Force
        $t | Add-Member -MemberType NoteProperty -Name Available -Value ($ar.Count -gt 0) -Force
        continue
    }
    if ($t.Kind -eq 'Uninstall') {
        $du = Find-DeadUninstall
        $t | Add-Member -MemberType NoteProperty -Name Items -Value $du -Force
        $t | Add-Member -MemberType NoteProperty -Name Bytes -Value 0L -Force
        $t | Add-Member -MemberType NoteProperty -Name FileCount -Value $du.Count -Force
        $t | Add-Member -MemberType NoteProperty -Name Available -Value ($du.Count -gt 0) -Force
        continue
    }
    if ($t.Kind -eq 'OldVersion') {
        $ov = Find-OldVersions
        $m = Measure-One ([pscustomobject]@{
            Paths    = @($ov | ForEach-Object { $_.FullName })
            Recurse  = $true
            Patterns = @()
        })
        $t | Add-Member -MemberType NoteProperty -Name Items -Value $ov -Force
        $t | Add-Member -MemberType NoteProperty -Name Bytes -Value $m.Bytes -Force
        $t | Add-Member -MemberType NoteProperty -Name FileCount -Value $ov.Count -Force
        $t | Add-Member -MemberType NoteProperty -Name Available -Value ($ov.Count -gt 0) -Force
        continue
    }
    $m = Measure-One $t
    $t | Add-Member -MemberType NoteProperty -Name Bytes -Value $m.Bytes -Force
    $t | Add-Member -MemberType NoteProperty -Name FileCount -Value $m.Files -Force
    $t | Add-Member -MemberType NoteProperty -Name Available -Value ($t.Paths.Count -gt 0 -and ($m.Bytes -gt 0 -or $m.Files -gt 0)) -Force
}

Stop-Spin
$header = '  ' + (Pad-Right '#' 4) + (Pad-Right '项目' 18) + (Pad-Left '占用' 10) + '  ' + (Pad-Right '默认' 5) + '说明'
Write-Host $header -ForegroundColor White
Write-Host ('  ' + ('-' * 76)) -ForegroundColor DarkGray
foreach ($t in $targets) {
    $flag = '否'
    if ($t.Default) { $flag = '是' }
    $sizeText = Format-Size $t.Bytes
    if ($t.SizeUnknown) { $sizeText = '未知' }
    if ($t.Bytes -eq 0 -and $t.FileCount -gt 0) { $sizeText = ('{0} 项' -f $t.FileCount) }
    if (-not $t.Available) {
        if ($t.Kind -eq 'Pnpm') { $sizeText = '无 pnpm' }
        elseif ($t.Paths.Count -eq 0) { $sizeText = '无' }
        else { $sizeText = '空' }
    }
    $line = '  ' + (Pad-Right ([string]$t.Id) 4) + (Pad-Right $t.Name 18) + (Pad-Left $sizeText 10) + '  ' + (Pad-Right $flag 5) + $t.Note
    if (-not $t.Available) { Write-Host $line -ForegroundColor DarkGray }
    elseif ($t.Danger) { Write-Host $line -ForegroundColor Red }
    elseif (-not $t.Default) { Write-Host $line -ForegroundColor DarkYellow }
    else { Write-Host $line -ForegroundColor Gray }
}

$usable = @($targets | Where-Object { $_.Available })
$defaultTotal = 0L
$allTotal = 0L
foreach ($t in $usable) {
    if ($t.Bytes -gt 0) {
        $allTotal += $t.Bytes
        if ($t.Default) { $defaultTotal += $t.Bytes }
    }
}

Write-Host ('  ' + ('-' * 76)) -ForegroundColor DarkGray
Write-Host ('  默认项合计: {0}    全部项合计: {1}' -f (Format-Size $defaultTotal), (Format-Size $allTotal)) -ForegroundColor White
Write-Host ''

# 残留类项目逐条列出，让人看清楚要删的是什么
foreach ($t in $targets) {
    if ($t.Kind -notmatch '^(Shortcut|OpenWith|Uninstall|OldVersion|Arrow)$') { continue }
    if (-not $t.Available) { continue }
    Write-Host ('  · {0} 明细：' -f $t.Name) -ForegroundColor DarkGray
    foreach ($it in ($t.Items | Select-Object -First 12)) {
        if ($t.Kind -eq 'Shortcut')   { Write-Host ('      {0}   -> {1}' -f $it.Name, $it.Target) -ForegroundColor DarkGray }
        if ($t.Kind -eq 'OpenWith')   { Write-Host ('      {0}   -> {1}' -f $it.App, $it.Exe) -ForegroundColor DarkGray }
        if ($t.Kind -eq 'Uninstall')  { Write-Host ('      {0}   -> {1}' -f $it.Name, $it.Location) -ForegroundColor DarkGray }
        if ($t.Kind -eq 'OldVersion') { Write-Host ('      {0}' -f $it.FullName) -ForegroundColor DarkGray }
        if ($t.Kind -eq 'Arrow')      { Write-Host ('      {0}' -f $it) -ForegroundColor DarkGray }
    }
    if ($t.Items.Count -gt 12) { Write-Host ('      ... 另有 {0} 项' -f ($t.Items.Count - 12)) -ForegroundColor DarkGray }
}

if ($DryRun) {
    Write-Host '  预演模式：以上为扫描结果，未删除任何文件。' -ForegroundColor Green
    return
}

if (-not $Yes) {
    Write-Host '  选择要清理的项目：' -ForegroundColor White
    Write-Host '    回车          = 清理默认项（推荐）' -ForegroundColor Gray
    Write-Host '    编号如 1,3,5  = 只清理指定项目' -ForegroundColor Gray
    Write-Host '    A             = 全部（不含危险项）' -ForegroundColor Gray
    Write-Host '    N             = 直接退出' -ForegroundColor Gray
    Write-Host ''
    $choice = $null
    try { $choice = Read-Host '  请输入' } catch { $choice = $null }
    if ($null -eq $choice) {
        Write-Host '  无法读取键盘输入，已取消，未删除任何文件。' -ForegroundColor Yellow
        return
    }
    if ([string]::IsNullOrWhiteSpace($choice)) {
        if ([Console]::IsInputRedirected) {
            Write-Host '  输入被重定向且为空，视为未确认，已取消，未删除任何文件。' -ForegroundColor Yellow
            Write-Host '  非交互场景请显式传入 -Yes。' -ForegroundColor Yellow
            return
        }
        $selected = @($usable | Where-Object { $_.Default })
    } elseif ($choice.Trim() -match '^[Nn]$') {
        Write-Host '  已取消，未删除任何文件。' -ForegroundColor Yellow
        return
    } elseif ($choice.Trim() -match '^[Aa]$') {
        $selected = @($usable | Where-Object { -not $_.Danger })
    } else {
        $ids = @()
        foreach ($part in $choice.Split(@(',', ' ', ';'), [System.StringSplitOptions]::RemoveEmptyEntries)) {
            $n = 0
            if ([int]::TryParse($part, [ref]$n)) { $ids += $n }
            else { Write-Host ('  无法识别的输入已忽略: {0}' -f $part) -ForegroundColor Yellow }
        }
        $selected = @($usable | Where-Object { $ids -contains $_.Id })
        # 输入里被丢掉的两类要分别说明，否则用户以为已经清理了
        $knownIds = @($targets | ForEach-Object { $_.Id })
        $selIds   = @($selected | ForEach-Object { $_.Id })
        $unknown  = @($ids | Where-Object { $knownIds -notcontains $_ })
        $nothing  = @($ids | Where-Object { ($knownIds -contains $_) -and ($selIds -notcontains $_) })
        if ($unknown.Count -gt 0) { Write-Host ('  没有这些编号: {0}' -f ($unknown -join '、')) -ForegroundColor Yellow }
        if ($nothing.Count -gt 0) {
            $names = @($targets | Where-Object { $nothing -contains $_.Id } | ForEach-Object { ('{0} {1}' -f $_.Id, $_.Name) })
            Write-Host ('  这些项目本次没有可清理内容，已跳过: {0}' -f ($names -join '、')) -ForegroundColor Yellow
        }
    }
} else {
    $selected = @($usable | Where-Object { $_.Default })
}

if ($selected.Count -eq 0) {
    Write-Host '  没有选中任何可清理项目。' -ForegroundColor Yellow
    return
}

$dangerList = @($selected | Where-Object { $_.Danger })
if ($dangerList.Count -gt 0) {
    Write-Host ''
    Write-Host ('  警告：以下项目会删除内容或改动系统设置 -> {0}' -f (($dangerList | ForEach-Object { $_.Name }) -join '、')) -ForegroundColor Red
    $ack = $null
    try { $ack = Read-Host '  确认请输入 DEL，其他任意输入则取消' } catch { $ack = $null }
    if ($null -eq $ack) {
        Write-Host '  无法读取键盘输入，已取消，未删除任何文件。' -ForegroundColor Yellow
        return
    }
    if ($ack -ne 'DEL') {
        Write-Host '  已取消，未删除任何文件。' -ForegroundColor Yellow
        return
    }
}

if ($IncludeAdmin -and -not $IsAdmin) {
    Write-Host ''
    Write-Host '  当前不是管理员，管理员项目将全部跳过，其余项目照常清理。' -ForegroundColor DarkYellow
}

# ---------- 清理 ----------

Write-Host ''
Write-Host '==============================================' -ForegroundColor Cyan
Write-Host '  开始清理' -ForegroundColor Cyan
Write-Host '==============================================' -ForegroundColor Cyan
Write-Host ''

$totalFreed = 0L
$totalSkipped = 0
$totalDeleted = 0
$touchedItems = 0

foreach ($t in $selected) {
    Write-Host ('  [{0}] {1} ...' -f $t.Id, $t.Name) -ForegroundColor Gray

    if ($t.Admin -and -not $IsAdmin) {
        Write-Host '       跳过：需要管理员权限' -ForegroundColor DarkYellow
        continue
    }

    if ($t.Kind -eq 'Files') {
        $r = Clear-One $t
        Stop-Spin
        $totalFreed += $r.Freed
        $totalDeleted += $r.Deleted
        $totalSkipped += $r.Skipped
        if ($r.Deleted -gt 0) { $touchedItems++ }
        Write-Host ('       释放 {0}，删除 {1} 个文件' -f (Format-Size $r.Freed), $r.Deleted) -ForegroundColor Green
        if ($r.Skipped -gt 0) {
            Write-Host ('       跳过 {0} 个文件（被占用或无权限）' -f $r.Skipped) -ForegroundColor DarkYellow
        }
        continue
    }

    if ($t.Kind -eq 'Pnpm') {
        if (-not $pnpmStore) {
            Write-Host '       跳过：未检测到 pnpm' -ForegroundColor DarkYellow
            continue
        }
        & pnpm store prune 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Host '       已执行 pnpm store prune' -ForegroundColor Green
            $touchedItems++
        } else {
            Write-Host '       pnpm store prune 未成功执行' -ForegroundColor DarkYellow
        }
        continue
    }

    if ($t.Kind -eq 'Arrow') {
        $ar = Set-ShortcutArrow $true
        if ($ar.Removed -gt 0) {
            Write-Host ('       已移除 {0} 个文件类的 IsShortcut' -f $ar.Removed) -ForegroundColor Green
            $touchedItems++
        }
        if ($ar.Unchanged -gt 0) {
            Write-Host ('       {0} 个类本来就没有，未改动' -f $ar.Unchanged) -ForegroundColor DarkGray
        }
        if ($ar.Failed -gt 0) {
            Write-Host ('       {0} 个类写入失败' -f $ar.Failed) -ForegroundColor Red
            $totalSkipped += $ar.Failed
        }
        Show-ArrowRestartHint
        continue
    }

    if ($t.Kind -eq 'RecycleBin') {
        if ($MinAgeDays -gt 0) {
            Write-Host '       跳过：清空回收站无法按文件年龄筛选，与 -MinAgeDays 冲突' -ForegroundColor DarkYellow
            continue
        }
        try {
            Clear-RecycleBin -Force -ErrorAction Stop
            Write-Host ('       已清空 {0} 个卷的回收站，释放 {1}' -f $t.Paths.Count, (Format-Size $t.Bytes)) -ForegroundColor Green
            $totalFreed += $t.Bytes
            $touchedItems++
        } catch {
            Write-Host '       清空失败（可能需要管理员权限）' -ForegroundColor DarkYellow
            $totalSkipped++
        }
        continue
    }

    if ($t.Kind -eq 'WinOld') {
        try {
            Remove-Item -LiteralPath $t.Paths[0] -Recurse -Force -ErrorAction Stop
            Write-Host '       已删除 Windows.old' -ForegroundColor Green
            $touchedItems++
        } catch {
            Write-Host '       删除失败，建议用系统「磁盘清理 → 清理系统文件」处理' -ForegroundColor DarkYellow
            $totalSkipped++
        }
        continue
    }

    if ($t.Kind -eq 'Shortcut') {
        $d = 0; $s = 0
        foreach ($it in $t.Items) {
            try { Remove-Item -LiteralPath $it.Path -Force -ErrorAction Stop; $d++ } catch { $s++ }
        }
        Write-Host ('       删除 {0} 个失效快捷方式' -f $d) -ForegroundColor Green
        if ($s -gt 0) { Write-Host ('       跳过 {0} 个（无权限）' -f $s) -ForegroundColor DarkYellow }
        if ($d -gt 0) { $touchedItems++ }
        $totalDeleted += $d
        $totalSkipped += $s
        continue
    }

    if ($t.Kind -eq 'OpenWith') {
        $d = 0; $s = 0
        if ($MinAgeDays -gt 0) { Write-Host '       注意：注册表项没有文件年龄，-MinAgeDays 对本项不生效' -ForegroundColor DarkYellow }
        $dead = @{}
        foreach ($it in $t.Items) { $dead[$it.App.ToLower()] = 1 }
        # FileExts 只遍历一遍，原来这个清扫嵌在每条 item 的循环里
        $extRoot = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\FileExts'
        if ($dead.Count -gt 0 -and (Test-Path $extRoot)) {
            foreach ($e in @(Get-ChildItem $extRoot -ErrorAction SilentlyContinue)) {
                $owlPath = "$($e.PSPath)\OpenWithList"
                $key = Get-Item $owlPath -ErrorAction SilentlyContinue
                if (-not $key) { continue }
                $removed = @()
                foreach ($vn in @($key.GetValueNames())) {
                    if ($vn -eq 'MRUList') { continue }
                    $v = [string]$key.GetValue($vn)
                    if ([string]::IsNullOrWhiteSpace($v)) { continue }
                    if (-not $dead.ContainsKey($v.ToLower())) { continue }
                    try {
                        Remove-ItemProperty -LiteralPath $owlPath -Name $vn -ErrorAction Stop
                        $removed += $vn
                    } catch { }
                }
                if ($removed.Count -eq 0) { continue }
                $mru = [string](Get-Item $owlPath -ErrorAction SilentlyContinue).GetValue('MRUList')
                if ($mru) {
                    $new = (($mru.ToCharArray() | Where-Object { $removed -notcontains [string]$_ }) -join '')
                    Set-ItemProperty -LiteralPath $owlPath -Name 'MRUList' -Value $new -ErrorAction SilentlyContinue
                }
            }
        }

        foreach ($it in $t.Items) {
            # 必须 -LiteralPath：键名里的 ? * [ ] 会被 -Path 当通配符，实测能删掉隔壁正常程序的键
            try { Remove-Item -LiteralPath $it.Path -Recurse -Force -ErrorAction Stop; $d++ } catch { $s++ }
        }
        Write-Host ('       清除 {0} 个打开方式条目' -f $d) -ForegroundColor Green
        if ($s -gt 0) { Write-Host ('       跳过 {0} 个（多为 HKLM 项，需管理员）' -f $s) -ForegroundColor DarkYellow }
        if ($d -gt 0) { $touchedItems++ }
        $totalDeleted += $d
        $totalSkipped += $s
        continue
    }

    if ($t.Kind -eq 'Uninstall') {
        $d = 0; $s = 0
        if ($MinAgeDays -gt 0) { Write-Host '       注意：注册表项没有文件年龄，-MinAgeDays 对本项不生效' -ForegroundColor DarkYellow }
        foreach ($it in $t.Items) {
            # 同上：卸载表键名常含 [ ] ，-Path 会误伤同级正常键
            try { Remove-Item -LiteralPath $it.Path -Recurse -Force -ErrorAction Stop; $d++ } catch { $s++ }
        }
        Write-Host ('       清除 {0} 个卸载条目' -f $d) -ForegroundColor Green
        if ($s -gt 0) { Write-Host ('       跳过 {0} 个（多为 HKLM 项，需管理员）' -f $s) -ForegroundColor DarkYellow }
        if ($d -gt 0) { $touchedItems++ }
        $totalDeleted += $d
        $totalSkipped += $s
        continue
    }

    if ($t.Kind -eq 'OldVersion') {
        $d = 0; $s = 0; $freed = 0L
        foreach ($dir in $t.Items) {
            $size = 0L
            foreach ($f in (Get-FilesSafe $dir.FullName $true @())) { $size += $f.Length }
            try {
                Remove-Item -LiteralPath $dir.FullName -Recurse -Force -ErrorAction Stop
                $d++; $freed += $size
            } catch { $s++ }
        }
        Write-Host ('       删除 {0} 个旧版本目录，释放 {1}' -f $d, (Format-Size $freed)) -ForegroundColor Green
        if ($s -gt 0) { Write-Host ('       跳过 {0} 个（被占用）' -f $s) -ForegroundColor DarkYellow }
        $totalFreed += $freed
        if ($d -gt 0) { $touchedItems++ }
        $totalDeleted += $d
        $totalSkipped += $s
        continue
    }
}

# 打印汇总前清屏，让「清理完成」落在窗口可视区的第一屏。
# 扫描十几秒 + 逐项删除几十行，不清屏的话汇总会被顶到滚屏外，
# 用户第一眼看到的仍是过程输出，以为"没有结束提示"。
# 只发 2J（清当前屏）+ H（光标归位），**不发 3J**：3J 会连回滚缓冲一起清掉，
# 那样就再也翻不回去看逐项的「释放 X，删除 N 个文件」了。
# 输出被重定向时不清（转义序列进日志文件是纯垃圾），复用 Test-SpinOn 的判断。
#
# ESC 必须用 [char]27 拼，**不能用反引号 `e**：那是 PowerShell 6+ 才加的转义，
# 本脚本跑在 5.1 上，`e 被当成普通字母，屏幕上会直接冒出 "e[2Je[H" 这串乱码。
if (Test-SpinOn) {
    $esc = [char]27
    [Console]::Write("$esc[2J$esc[H")
}

Write-Host '==============================================' -ForegroundColor Cyan
Write-Host '  清理完成' -ForegroundColor Green
Write-Host '==============================================' -ForegroundColor Cyan
Write-Host ''
Write-Host ('  本次清理 {0} 个项目，释放 {1}（共删除 {2} 个文件）' -f $touchedItems, (Format-Size $totalFreed), $totalDeleted) -ForegroundColor Green
Write-Host ('  跳过 {0} 项（被占用、无权限或需管理员）' -f $totalSkipped) -ForegroundColor Gray
$sysDrive = if ($env:SystemDrive) { $env:SystemDrive.TrimEnd(':') } else { 'C' }
$sd = Get-PSDrive -Name $sysDrive -PSProvider FileSystem -ErrorAction SilentlyContinue
if ($sd) {
    Write-Host ('  清理后 {0} 盘可用: {1:N2} GB' -f $sysDrive, ($sd.Free / 1GB)) -ForegroundColor Green
} else {
    Write-Host '  清理后剩余空间: 无法读取系统盘' -ForegroundColor DarkGray
}
Write-Host ''
Write-Host '  说明：仅清理临时文件与缓存，不影响软件本体、账号数据与项目文件。' -ForegroundColor DarkGray
Write-Host ''

if (-not $NoPause) {
    Write-Host '  窗口不会自己关，看完直接关掉窗口即可（Ctrl+C 也能退出）。' -ForegroundColor DarkGray
    # 挂住窗口的动作在批处理包装器里做（纯等待，不吃按键），这里不等待：
    # 脚本里还有十几处提前 return 的出口，等待放在一处才覆盖得到它们。
}
return
