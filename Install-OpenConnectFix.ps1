<#
    Install-OpenConnectFix.ps1

    Накатывает на OpenConnect-GUI три независимые правки:

    1. getDefaultGateway4() выбирает default-маршрут с МИНИМАЛЬНОЙ метрикой,
       а не первый попавшийся в выводе "route print". Порядок строк там не
       стабилен между перезагрузками, поэтому посторонний default-маршрут
       (например, у Radmin VPN он с метрикой ~9000) мог случайно выиграть.
       Тогда скрипт пришпиливал адрес VPN-шлюза к интерфейсу, откуда тот
       недостижим, и туннель поднимался, но не передавал трафик.

    2. NRPT-правила для корпоративных DNS-зон: ставятся при подключении,
       снимаются при отключении. Нужны, когда параллельно работает клиент
       с TUN-адаптером (Throne / sing-box и подобные) с низкой метрикой
       интерфейса — он перехватывает весь DNS, и зоны со split-horizon
       резолвятся во внешние адреса вместо внутренних.

    3. Клэмп MTU туннельного интерфейса сверху значением -MaxMtu (по
       умолчанию 1300). Шлюз анонсирует MTU (например, 1372), который
       туннель на самом деле не пропускает целиком: пакеты чуть меньше
       анонсированного значения (замечено — от ~1345 байт) молча терялись
       где-то на пути, без ICMP "нужна фрагментация", и TCP/TLS зависал на
       ретрансмиссиях на минуты. Итоговый MTU = min(то, что прислал шлюз,
       -MaxMtu).

    Постоянными правила делать нельзя: при выключенном VPN перестанет
    резолвиться адрес самого шлюза, и подключиться будет невозможно.

    Запускать от имени администратора. Скрипт идемпотентен — повторный
    запуск ничего не сломает и не продублирует.

    Usage:
        powershell -ExecutionPolicy Bypass -File .\Install-OpenConnectFix.ps1
        powershell -ExecutionPolicy Bypass -File .\Install-OpenConnectFix.ps1 -MaxMtu 1250
        powershell -ExecutionPolicy Bypass -File .\Install-OpenConnectFix.ps1 -Rollback
#>
[CmdletBinding()]
param(
    # Путь к каталогу OpenConnect-GUI, если автоопределение не сработало.
    [string]$InstallDir,

    # Корпоративные DNS-зоны. Ведущая точка обязательна.
    [string[]]$Namespaces = @('.rtl-consulting.ru', '.ru-central1.internal'),

    # Верхняя граница MTU туннельного интерфейса.
    [int]$MaxMtu = 1300,

    # Откатить правки из последнего бэкапа и удалить helper.
    [switch]$Rollback
)

$ErrorActionPreference = 'Stop'

function Write-Step($msg)  { Write-Host "  $msg" }
function Write-Ok($msg)    { Write-Host "  [ OK ] $msg"   -ForegroundColor Green }
function Write-Skip($msg)  { Write-Host "  [ -- ] $msg"   -ForegroundColor DarkGray }
function Write-Warn2($msg) { Write-Host "  [ !! ] $msg"   -ForegroundColor Yellow }
function Fail($msg)        { Write-Host "  [FAIL] $msg"   -ForegroundColor Red; exit 1 }

Write-Host ""
Write-Host "OpenConnect-GUI: установка правок" -ForegroundColor Cyan
Write-Host ("-" * 50)

# --- права ---------------------------------------------------------------
$isAdmin = ([Security.Principal.WindowsPrincipal] `
            [Security.Principal.WindowsIdentity]::GetCurrent()
           ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Fail 'Нужны права администратора. Запусти PowerShell от имени администратора.'
}

# --- поиск установки -----------------------------------------------------
if (-not $InstallDir) {
    $candidates = @(
        "$env:ProgramFiles\OpenConnect-GUI"
        "${env:ProgramFiles(x86)}\OpenConnect-GUI"
    )
    # Подстраховка: спросим у реестра, если в стандартных местах пусто.
    $regPaths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    foreach ($rp in $regPaths) {
        try {
            Get-ItemProperty $rp -ErrorAction SilentlyContinue |
                Where-Object { $_.DisplayName -like '*OpenConnect*' -and $_.InstallLocation } |
                ForEach-Object { $candidates += $_.InstallLocation }
        } catch { }
    }
    $InstallDir = $candidates | Where-Object { $_ -and (Test-Path (Join-Path $_ 'vpnc-script.js')) } | Select-Object -First 1
}

if (-not $InstallDir -or -not (Test-Path (Join-Path $InstallDir 'vpnc-script.js'))) {
    Fail 'Не найден vpnc-script.js. Укажи каталог вручную: -InstallDir "C:\Path\To\OpenConnect-GUI"'
}

$script = Join-Path $InstallDir 'vpnc-script.js'
$helper = Join-Path $InstallDir 'nrpt-openconnect.ps1'
Write-Ok "Найдена установка: $InstallDir"

# --- откат ---------------------------------------------------------------
if ($Rollback) {
    $backup = Get-ChildItem (Join-Path $InstallDir 'vpnc-script.js.bak-*') -ErrorAction SilentlyContinue |
              Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $backup) { Fail 'Бэкап не найден, откатывать нечего.' }

    Copy-Item $backup.FullName $script -Force
    Write-Ok "Восстановлено из $($backup.Name)"

    if (Test-Path $helper) { Remove-Item $helper -Force; Write-Ok 'Удалён nrpt-openconnect.ps1' }

    Get-DnsClientNrptRule -ErrorAction SilentlyContinue |
        Where-Object { $_.Comment -eq 'openconnect-gui-auto' } |
        ForEach-Object { Remove-DnsClientNrptRule -Name $_.Name -Force -ErrorAction SilentlyContinue }
    Write-Ok 'Снятые NRPT-правила очищены'
    Write-Host ''
    exit 0
}

# --- бэкап ---------------------------------------------------------------
$backupPath = "$script.bak-" + (Get-Date -Format 'yyyyMMdd-HHmmss')
Copy-Item $script $backupPath -Force
Write-Ok "Бэкап: $(Split-Path $backupPath -Leaf)"

# --- helper --------------------------------------------------------------
$nsLiteral = ($Namespaces | ForEach-Object { "    '$_'" }) -join "`r`n"

$helperBody = @'
<#
    Ставит и снимает NRPT-правила для корпоративных DNS-зон.
    Вызывается из vpnc-script.js на connect/disconnect. Руками запускать не надо.
#>
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('add', 'remove')]
    [string]$Action,

    [string]$Servers = ''
)

$ErrorActionPreference = 'Continue'
$Tag = 'openconnect-gui-auto'

# Корпоративные DNS-зоны. Ведущая точка обязательна.
$Namespaces = @(
__NAMESPACES__
)

# Свои прошлые правила снимаем всегда - и при remove, и перед add,
# чтобы переподключение не плодило дубликаты.
Get-DnsClientNrptRule -ErrorAction SilentlyContinue |
    Where-Object { $_.Comment -eq $Tag } |
    ForEach-Object {
        Remove-DnsClientNrptRule -Name $_.Name -Force -ErrorAction SilentlyContinue
        Write-Output ("NRPT: removed " + ($_.Namespace -join ' '))
    }

if ($Action -eq 'add') {
    $list = @($Servers -split '[,\s]+' | Where-Object { $_ })
    if ($list.Count -eq 0) {
        Write-Output 'NRPT: VPN did not push any DNS server, nothing to do'
    } else {
        foreach ($ns in $Namespaces) {
            Add-DnsClientNrptRule -Namespace $ns -NameServers $list `
                -Comment $Tag -DisplayName "OpenConnect $ns" -ErrorAction SilentlyContinue | Out-Null
            Write-Output ("NRPT: " + $ns + " -> " + ($list -join ' '))
        }
    }
}

Clear-DnsClientCache -ErrorAction SilentlyContinue
exit 0
'@

$helperBody = $helperBody.Replace('__NAMESPACES__', $nsLiteral)
# UTF-8 с BOM: helper запускается через powershell.exe (5.1), который без BOM
# читает файл как ANSI и портит кириллицу в комментариях.
[IO.File]::WriteAllText($helper, $helperBody, (New-Object Text.UTF8Encoding($true)))
Write-Ok "Записан nrpt-openconnect.ps1 (зон: $($Namespaces.Count))"

# --- патч vpnc-script.js -------------------------------------------------
$src = [IO.File]::ReadAllText($script)
$changed = $false

# 1. выбор шлюза по минимальной метрике
if ($src -match 'bestMetric') {
    Write-Skip 'getDefaultGateway4() уже пропатчен'
} else {
    $newGw = @'
function getDefaultGateway4()
{
    // Pick the default route with the LOWEST metric rather than whichever one
    // "route print" happens to list first: that ordering is not stable across
    // reboots (interface indexes get reassigned), so a stray default route --
    // e.g. Radmin VPN's, metric ~9000 -- would otherwise win at random and pin
    // the VPN gateway to an interface that cannot reach it, killing the tunnel.
    var out = run("route print -4");
    var re = /0\.0\.0\.0\s+(?:0|128)\.0\.0\.0\s+(\d+\.\d+\.\d+\.\d+)\s+\S+\s+(\d+)/g;
    var best = "", bestMetric = -1, m;

    while ((m = re.exec(out)) !== null) {
        if (m[1] === "0.0.0.0")
            continue;
        var metric = parseInt(m[2], 10);
        if (bestMetric < 0 || metric < bestMetric) {
            bestMetric = metric;
            best = m[1];
        }
    }

    if (best)
        echo(DEBUG, "Default Legacy IP gateway: " + best + " (metric " + bestMetric + ")");
    else
        echo(ERROR, "Could not determine default Legacy IP gateway");

    return (best);
}
'@
    $rx = [regex]'(?s)function\s+getDefaultGateway4\s*\(\s*\)\s*\r?\n?\{.*?\r?\n\}'
    if (-not $rx.IsMatch($src)) {
        Fail 'Не найдена функция getDefaultGateway4() — версия vpnc-script.js не та, патч не применён.'
    }
    $src = $rx.Replace($src, [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $newGw }, 1)
    $changed = $true
    Write-Ok 'getDefaultGateway4() -> выбор по минимальной метрике'
}

# 2. helper-функция nrpt()
if ($src -match 'function\s+nrpt\s*\(') {
    Write-Skip 'функция nrpt() уже есть'
} else {
    $nrptFn = @'
// Point corporate DNS zones at the VPN's resolver via NRPT, so that a
// concurrent TUN client (Throne / sing-box) with a low interface metric does
// not answer them from a public resolver. Zone list lives in the .ps1 next to
// this script. Uses ws.Exec directly rather than run(): the script path can
// contain spaces and would need nested quoting to survive %comspec% /C.
function nrpt(action, servers)
{
    var sep = String.fromCharCode(92);
    var full = WScript.ScriptFullName;
    var ps1 = full.substring(0, full.lastIndexOf(sep) + 1) + "nrpt-openconnect.ps1";
    var cmd = "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File " +
              String.fromCharCode(34) + ps1 + String.fromCharCode(34) +
              " -Action " + action +
              " -Servers " + String.fromCharCode(34) + servers + String.fromCharCode(34);
    echo(DEBUG, "-> " + cmd);
    try {
        var oExec = ws.Exec(cmd);
        oExec.StdIn.Close();
        var s = oExec.StdOut.ReadAll();
        while (s.length && (s.charAt(s.length - 1) === "\n" || s.charAt(s.length - 1) === "\r"))
            s = s.substring(0, s.length - 1);
        if (s)
            echo(INFO, s);
    } catch (e) {
        // Never fail the VPN connection over a name-resolution tweak.
        echo(ERROR, "NRPT step failed: " + e.message);
    }
}

'@
    $anchor = 'if (!String.prototype.trim) {'
    $i = $src.IndexOf($anchor)
    if ($i -lt 0) { Fail "Не найден якорь для вставки nrpt(): '$anchor'" }
    $src = $src.Substring(0, $i) + $nrptFn + $src.Substring($i)
    $changed = $true
    Write-Ok 'добавлена функция nrpt()'
}

# 3. вызов на connect
if ($src -match 'nrpt\("add"') {
    Write-Skip 'вызов nrpt("add") уже есть'
} else {
    $anchor = '// Add internal network routes'
    $i = $src.IndexOf($anchor)          # первое вхождение = ветка IPv4
    if ($i -lt 0) { Fail "Не найден якорь для nrpt(add): '$anchor'" }
    $src = $src.Substring(0, $i) +
           "nrpt(`"add`", env(`"INTERNAL_IP4_DNS`"));`r`n`r`n    " +
           $src.Substring($i)
    $changed = $true
    Write-Ok 'добавлен вызов nrpt("add") в ветку connect'
}

# 4. вызов на disconnect
if ($src -match 'nrpt\("remove"') {
    Write-Skip 'вызов nrpt("remove") уже есть'
} else {
    $anchor = 'case "disconnect":'
    $i = $src.IndexOf($anchor)
    if ($i -lt 0) { Fail "Не найден якорь для nrpt(remove): '$anchor'" }
    $i += $anchor.Length
    $src = $src.Substring(0, $i) + "`r`n    nrpt(`"remove`", `"`");" + $src.Substring($i)
    $changed = $true
    Write-Ok 'добавлен вызов nrpt("remove") в ветку disconnect'
}

# 5. клэмп MTU
if ($src -match 'MAX_SAFE_MTU') {
    Write-Skip 'клэмп MTU уже установлен'
} else {
    $oldMtu = @'
    if (env("INTERNAL_IP4_MTU")) {
        echo(INFO, "MTU: " + env("INTERNAL_IP4_MTU"));
        run("netsh interface ipv4 set subinterface " + env("TUNIDX") +
            " mtu=" + env("INTERNAL_IP4_MTU") + " store=active");

        if (env("INTERNAL_IP6_ADDRESS")) {
            run("netsh interface ipv6 set subinterface " + env("TUNIDX") +
                " mtu=" + env("INTERNAL_IP4_MTU") + " store=active");
        }
    }
'@
    $newMtu = @"
    if (env("INTERNAL_IP4_MTU")) {
        // Gateway advertises an MTU that the tunnel doesn't actually pass in
        // full: packets a bit under that value get silently dropped
        // somewhere on the path (no ICMP frag-needed comes back), stalling
        // TCP/TLS handshakes for minutes. Clamp to a value confirmed by
        // testing to get through cleanly.
        var MAX_SAFE_MTU = $MaxMtu;
        var pushedMtu = parseInt(env("INTERNAL_IP4_MTU"), 10);
        var mtu = Math.min(pushedMtu, MAX_SAFE_MTU);
        echo(INFO, "MTU: " + pushedMtu + " (clamped to " + mtu + ")");
        run("netsh interface ipv4 set subinterface " + env("TUNIDX") +
            " mtu=" + mtu + " store=active");

        if (env("INTERNAL_IP6_ADDRESS")) {
            run("netsh interface ipv6 set subinterface " + env("TUNIDX") +
                " mtu=" + mtu + " store=active");
        }
    }
"@
    if ($src -notmatch [regex]::Escape($oldMtu)) {
        Fail 'Не найден ожидаемый блок MTU — версия vpnc-script.js не та, патч не применён.'
    }
    $src = $src.Replace($oldMtu, $newMtu)
    $changed = $true
    Write-Ok "клэмп MTU до $MaxMtu добавлен"
}

if ($changed) {
    # Без BOM: вставки в .js чисто ASCII, исходный файл его не имел,
    # и cscript не должен получить лишние байты в начале.
    [IO.File]::WriteAllText($script, $src, (New-Object Text.UTF8Encoding($false)))
} else {
    Write-Skip 'vpnc-script.js уже был пропатчен целиком'
    Remove-Item $backupPath -Force -ErrorAction SilentlyContinue
}

# --- проверка синтаксиса -------------------------------------------------
Write-Host ''
Write-Step 'Проверка синтаксиса JScript...'
$env:reason = 'pre-init'
try {
    $null = & cscript //nologo //E:jscript $script 2>&1
    $code = $LASTEXITCODE
} finally {
    Remove-Item Env:reason -ErrorAction SilentlyContinue
}

if ($code -ne 0) {
    Write-Warn2 "cscript вернул $code — откатываю из бэкапа"
    if (Test-Path $backupPath) { Copy-Item $backupPath $script -Force }
    Fail 'Патч откачен, файл не изменён.'
}
Write-Ok 'синтаксис в порядке'

# --- итог ----------------------------------------------------------------
Write-Host ''
Write-Host ("-" * 50)
Write-Host 'Готово.' -ForegroundColor Green
Write-Host ''
Write-Host '  Проверить после подключения VPN:'
Write-Host '    Get-DnsClientNrptRule | Where-Object Comment -eq ''openconnect-gui-auto'''
Write-Host ''
Write-Host '  Ожидается: 2 правила при поднятом VPN, 0 при опущенном.'
Write-Host ''
Write-Host '  Проверить MTU после подключения VPN:'
Write-Host '    Get-NetIPInterface -AddressFamily IPv4 | Where-Object InterfaceAlias -like "gateway.*" | Select NlMtu'
Write-Host "  Ожидается: NlMtu <= $MaxMtu."
Write-Host ''
Write-Host '  Откат:     -Rollback'
Write-Host ''
Write-Host '  Обновление OpenConnect-GUI затирает vpnc-script.js —'
Write-Host '  после него просто запусти этот скрипт снова.'
Write-Host ''
