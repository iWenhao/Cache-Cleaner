# 一键清理缓存 / Cache Cleaner

Windows 单文件缓存清理工具。双击即用，不需要安装任何依赖，也不需要任何配套文件。

## 产物是什么样的

交付物只有一个文件：`一键清理缓存.bat`（约 76 KB，纯 ASCII 文本，没有配套文件、不需要安装）。里面是 cmd 引导壳 + base64 的 PowerShell 正文，运行时自己解码执行，所以双击它等于同时带了脚本和解释器入口。

双击后的流程：

1. 开一个控制台窗口，显示标题和当前权限（普通用户 / 管理员）；不是管理员时会提示哪四项需要右键"以管理员身份运行"才能解锁
2. 扫描各项目占用（本机实测十几秒，视缓存量而定）
3. 打印一张表，列为 `# 项目 占用 默认 说明`：灰色 = 本机这项没内容，红色 = 危险项（需 `DEL` 确认），黄色 = 非默认项
4. 等待输入选择
5. 逐项删除，每项输出 `释放 X，删除 N 个文件`；被占用或无权限的文件记成 `跳过 N 个`，不会静默失败
6. 汇总本次释放、删除/跳过数量、清理后系统盘可用空间，然后"按任意键关闭窗口"

## 普通用户怎么用

三步：双击 → 等扫描完 → 直接回车。回车只清理默认项（用户 Temp、包管理器缓存含 pnpm store 瘦身、浏览器缓存含 Firefox、VS Code 缓存、Windows 错误报告、缩略图缓存），其余一律不动。

想做得更多：

- **清得更彻底**：右键 → 以管理员身份运行，会多出 Windows 更新缓存 / 传递优化 / 系统 Temp / Windows.old
- **先看看会删什么**：命令行运行 `一键清理缓存.bat -DryRun`，只扫描、什么都不删。第一次用建议先跑这个
- **只列残留目录**：`-Report`，只读，供人工判断，不删除

首次运行可能被 Windows SmartScreen 拦一下（文件没有代码签名）：出现"Windows 已经保护你的电脑"时点"更多信息 → 仍要执行"。它就是纯文本，用记事本打开可以看全部内容，顶部注释块写着用法。

## 用法

```
双击运行                      扫描后进入选择界面，回车即清理默认项
一键清理缓存.bat -DryRun       只扫描，不删除任何文件
一键清理缓存.bat -Yes          跳过选择，直接清理默认项
一键清理缓存.bat -IncludeAdmin 额外列出需要管理员权限的项目
一键清理缓存.bat -MinAgeDays 7 只清理 7 天前修改的文件（注册表项不适用，回收站会被跳过）
一键清理缓存.bat -NoPause      结束时不等待按键
一键清理缓存.bat -Report       只列出疑似残留的用户目录（只读，不删除；要遍历整个 AppData，慢）
一键清理缓存.bat -NoArrow      去掉快捷方式的小箭头（改注册表，需管理员，不删文件）
一键清理缓存.bat -RestoreArrow 还原小箭头
```

选择界面支持：回车（默认项）、`1,3,5`（指定编号）、`A`（全部，**不含危险项**）、`N`（退出）。
回收站、残留快捷方式、打开方式残留、卸载表残留、旧版本残留、Windows.old、快捷方式小箭头 这七项要先输入 `DEL` 二次确认（大小写都行，输入 `DEL`/`del`/`Del` 都接受）；`A` 不会把它们带进来。

### 快捷方式小箭头

`-NoArrow` / `-RestoreArrow` 是独立开关：给了就直接改注册表然后退出，**不会顺带清理任何缓存**。原理是删掉文件类上的 `IsShortcut` 值，覆盖 `.lnk`（lnkfile）、`.pif`（piffile）、`.url`（InternetShortcut）三类，还原就是写回一个空的 String 值。

菜单里也能选：这一项叫「快捷方式小箭头」，属危险项，要 `DEL` 确认；表格的"占用"列显示的是还带着 `IsShortcut` 的类个数（例如 `1 项` = 只剩 `.url`）。还原只走命令行，菜单里没有"还原"。

- 需要管理员：HKCR 的写入实际落在 `HKLM\SOFTWARE\Classes`，普通用户申请写句柄会被拒。
- 生效要重启资源管理器（任务管理器 → Windows 资源管理器 → 重新启动，或注销一次）。脚本不代你做：`taskkill /f /im explorer.exe` 会连带关掉你所有已打开的文件夹窗口，而从提权进程重新拉起的 explorer 可能让之后所有程序都跟着提权。
- Windows 大版本更新后系统会不会重建这些值、以及删掉它有没有别的副作用，未做验证。
- 本机实测还定义 `IsShortcut` 的另外几个类（`IE.AssocFile.URL`、`Microsoft.Website`、`WSHFile`、`Application.Reference`）没有验证是否也参与画箭头，所以不动。

## 可清理项

| # | 项目 | 默认 |
|---|---|---|
| 1 | 用户 Temp | 是 |
| 2 | Updater 更新缓存（按目录名后缀匹配，需自行确认） | 否 |
| 3 | 包管理器缓存（npm / pnpm / yarn / bun / pip / uv） | 是 |
| 4 | pnpm store 瘦身（占用列 = 仓库总体积） | 是 |
| 5 | 浏览器缓存（Chrome / Edge 的 `Cache` / `Code Cache` / `GPUCache` + Firefox 的 `cache2` / `startupCache`） | 是 |
| 6 | VS Code 缓存（`%APPDATA%\Code` 与 `Code - Insiders`，见下） | 是 |
| 7 | Windows 错误报告 | 是 |
| 8 | 缩略图/图标缓存 | 是 |
| 9 | 回收站 | 否，需 DEL 确认 |
| 10 | 残留快捷方式 | 否，需 DEL 确认 |
| 11 | 打开方式残留（按 exe **文件名**判定，不比较路径） | 否，需 DEL 确认 |
| 12 | 卸载表残留（按 InstallLocation 是否存在判定） | 否，需 DEL 确认 |
| 13 | 旧版本残留（Electron，整目录递归删除） | 否，需 DEL 确认 |
| 14-16 | Windows 更新缓存 / 传递优化 / 系统 Temp | 否，需管理员 |
| 17 | Windows.old | 否，需管理员，且需 DEL 确认 |
| 18 | 快捷方式小箭头（改注册表，不是缓存） | 否，需管理员，且需 DEL 确认 |

第 14-17 项在以管理员身份运行时自动列出（或加 `-IncludeAdmin`）。第 18 项始终列出，普通用户选中只会提示需要提权、不改动任何东西；非管理员运行时因为 14-17 不列出，它是第 14 行。选中危险项后会逐条列出明细再让你确认。

### 浏览器缓存

浏览器按 profile 枚举，只认白名单里的子目录：Chrome / Edge 取 `Default` 与 `Profile N`，Firefox 取 `%LOCALAPPDATA%\Mozilla\Firefox\Profiles\*`。

Firefox 的磁盘缓存在 **LOCALAPPDATA** 那份 profile 里，不在 Roaming 那份——本机实测 Roaming profile 根本没有 `cache2`，1020 MB 全在 LOCALAPPDATA 同名目录下。Roaming 里的 `storage`（IndexedDB，105.6 MB）、`security_state`、`extensions`、`gmp-*` 都是数据不是缓存，不碰。`safebrowsing`（12.2 MB）是恶意网站特征库，删了要重新下载、且短期内降低防护，也不碰。

### VS Code 缓存

只删这几个目录里的文件，目录本身保留：

`Cache`、`Code Cache`、`GPUCache`、`CachedData`、`CachedExtensionVSIXs`、`Crashpad`、`DawnCache`、`DawnGraphiteCache`、`DawnWebGPUCache`

本机实测合计约 1.7 GB，其中 `CachedExtensionVSIXs` 807 MB（已装完的安装包）、`Crashpad` 386 MB（崩溃转储）、`Cache` 331 MB、`CachedData` 203 MB（重启后自动重建）。

明确不碰：`User`（设置、`History`、`workspaceStorage`）、`%USERPROFILE%\.vscode\extensions`（插件本体）、`Local Storage` / `Session Storage` / `WebStorage`、`Service Worker`、`Dictionaries`、`logs`（崩溃后还要靠它排查，而且只有 1 MB）。

VS Code 开着的时候删，被占用的文件会统计成"跳过 N 个"，不会静默——先关掉再清更干净。

## 安全设计

- **先扫描后删除**，默认项之外一律不勾选。默认项删的都是可重建的缓存，代价是重新下载；真正不可恢复的那几项（回收站、注册表残留、旧版本目录、Windows.old、小箭头）必须显式选中并输入 `DEL`
- 删除失败**不静默**：被占用或无权限的文件会统计成"跳过 N 个"并显示出来
- 认不出的命令行参数会显式提示，不会静默忽略——写错 `-DryRun` 却当没事发生就太危险了
- pnpm 用 `pnpm store prune`，只删没有项目引用的包；表格左列是仓库总体积，不等于 prune 能回收的量
- 只认固定的缓存路径，不扫 AppData 整棵树，不碰任何项目目录
- 目录联接（junction / 符号链接目录）一律不进入：目标本身是联接时该项目按空处理。副作用是把缓存整体搬到别的盘（用联接指回来）的机器，这一项不会被清理
- 注册表删除只用 `-LiteralPath`。键名里的 `? * [ ]` 会被 `-Path` 当通配符，实测会连带删掉隔壁正常程序的键
- `-MinAgeDays` 在统计阶段就生效，表格里显示的占用等于实际会删的量
- 遍历不依赖 `Get-ChildItem -Recurse`：PowerShell 5.1 下它会整片漏掉子树（本机 pnpm store 实测只报 22899 / 99326 个文件），脚本自己按栈递归，与 `[IO.Directory]::EnumerateFiles` 计数一致

## 刻意不做的事

以下类别删除代价过大或风险过高，工具一律不处理，避免误伤：

- AI 模型缓存（Ollama / HuggingFace）、Maven `~/.m2`、Gradle 缓存
- 站点本地数据（`Service Worker\CacheStorage`、`IndexedDB`、`Local Storage`）——名字里带 cache，实际是网站存的离线数据，删了等于清掉用户在该站点的数据
- 微信等**应用自身的缓存**（聊天记录与缓存目录同级并列，误判代价不可接受）
- Windows Installer 缓存（删除后已装程序无法修复/卸载）
- WinSxS 组件存储（需用 `DISM`，风险更高）
- 卸载后残留的用户目录——只用 `-Report` 列出供人工判断，**不自动删除**

## 已知还没覆盖的缓存

本机实测（2026-10-16 的快照，数字会变）体积不小但工具目前不碰的几处：

| 位置 | 实测 | 没做的原因 |
|---|---|---|
| `%LOCALAPPDATA%\Microsoft\Terminal Server Client\Cache` | 300.2 MB / 4 个文件 | 远程桌面位图缓存，其实是最好加的一项，还没加 |
| `C:\Windows\Logs\CBS` | 112.9 MB / 8 个文件 | 需管理员；组件服务日志，删法要确认 |
| `%LOCALAPPDATA%\Microsoft\Windows\WebCache` | 62.5 MB / 11 个文件 | 被 SearchIndexer 长期独占，删除多半只会得到"跳过 N 个" |
| `C:\Windows\Logs\DISM` | 7.7 MB / 1 个文件 | 需管理员 |
| Chrome 的 `DawnWebGPUCache` + `DawnGraphiteCache` | 6.6 MB | 浏览器项只认 `Cache` / `Code Cache` / `GPUCache`，这两处没列进白名单 |

另外两处实测过、确认不该加的：

- Chrome `Service Worker\CacheStorage` 1.9 GB——读了一下它的 LevelDB，登记的是 `mail.google.com` 之类的站点离线数据，删了等于清掉用户在网站上的本地数据，属于"数据"不是"缓存"。
- Edge `User Data\Default` 在本机一个 `Cache` / `Code Cache` / `GPUCache` 都没有，这一项对 Edge 实际贡献 0；换台机器才有。

## 实现说明

源码是 `src/cleaner.ps1`（UTF-8 with BOM）。`一键清理缓存.bat` 是**生成产物**，不要手工编辑：

```
powershell -NoProfile -ExecutionPolicy Bypass -File build.ps1
```

build 把 PowerShell 正文 base64 后按每行 100 字符写成 `REM #B64#`，追加到 ASCII 包装器之后，并做两项自检：解码结果必须与源码一致（比较前源码已去掉 UTF-8 BOM、换行统一成 LF，所以载荷与源码文件并非逐字节相同），产物不得含任何非 ASCII 字节。

之所以要这层封装，是因为 cmd 的一个已知缺陷：**含中文的 UTF-8 批处理文件，cmd 分块读取时会把注释行里的中文片段当成命令执行**，导致脚本一闪而过。保持 `.bat` 100% 纯 ASCII（最大字节值 126）可以彻底规避；代价是脚本正文里的中文提示与 `█` 字符画标题只能待在 base64 里。

包装器自己会校验正文：正文行缺失退出 9，base64 长度不是 4 的倍数（说明被截断）或解码失败退出 8，两种情况都不会跑到"删文件"那一步。找不到 `powershell` 时退回 `pwsh`，两者都没有才报错退出。

命令行参数经 `CC_ARGS` 环境变量传给 PowerShell 再切分，不用 `%*` 直接拼进 `-Command`——后者会把参数原样写进一条命令行语句里。

同理，`.lnk` 快捷方式的目标是直接用二进制解析的，不依赖 `WScript.Shell`；旧格式 .lnk 的路径以系统 ANSI 代码页存储，需显式按 ANSI 代码页解码（`[Text.Encoding]::Default` 在 PowerShell 7 下是 UTF-8，不能用）。

## License

MIT
