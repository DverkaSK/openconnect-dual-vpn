# openconnect-dual-vpn

Патч для OpenConnect-GUI на Windows, чтобы корпоративный VPN нормально
работал одновременно со вторым VPN/прокси-клиентом с TUN-адаптером
(например, на базе sing-box) - без ручных танцев после каждого
подключения.

## Проблема

Когда параллельно с OpenConnect работает ещё один TUN-клиент, всплывают
три независимых бага:

1. **Не тот default-шлюз.** `getDefaultGateway4()` в штатном
   `vpnc-script.js` берёт первый default-маршрут из вывода `route print`,
   а не с минимальной метрикой. Порядок строк там не стабилен между
   перезагрузками, поэтому посторонний default-маршрут (например, у
   Radmin VPN метрика ~9000) мог случайно выиграть. Туннель поднимался,
   но трафик не ходил - адрес VPN-шлюза пришпиливался к интерфейсу,
   откуда тот недостижим.

2. **DNS корпоративных зон резолвится не туда.** Если у второго
   TUN-клиента метрика интерфейса ниже, он перехватывает весь DNS, и
   зоны со split-horizon (внутренние домены компании) резолвятся во
   внешние адреса вместо внутренних.

3. **TLS зависает на минуты.** Шлюз анонсирует MTU (например, 1372),
   который путь на самом деле не пропускает целиком. Пакеты чуть меньше
   анонсированного значения (замечено - от ~1345 байт) молча терялись
   где-то по пути, без ICMP «нужна фрагментация». TCP уходил в
   ретрансмиссии на минуты - особенно заметно на TLS-рукопожатии, где
   браузер шлёт пакеты крупнее, чем простые запросы вроде `curl`.

## Что делает скрипт

`Install-OpenConnectFix.ps1` патчит `vpnc-script.js` внутри установки
OpenConnect-GUI:

- `getDefaultGateway4()` выбирает default-маршрут с минимальной
  метрикой, а не первый попавшийся.
- На подключение/отключение ставятся/снимаются NRPT-правила для
  заданных корпоративных DNS-зон, чтобы они всегда резолвились через
  DNS-сервер VPN.
- MTU туннельного интерфейса клэмпится сверху безопасным значением
  (по умолчанию 1300).

Скрипт идемпотентен: повторный запуск ничего не дублирует и не ломает.
Перед изменением делается бэкап `vpnc-script.js`.

## Использование

Запускать от имени администратора:

```powershell
powershell -ExecutionPolicy Bypass -File .\Install-OpenConnectFix.ps1
```

С нестандартными зонами и MTU:

```powershell
powershell -ExecutionPolicy Bypass -File .\Install-OpenConnectFix.ps1 `
    -Namespaces '.corp.example.com','.internal' `
    -MaxMtu 1250
```

Если путь к OpenConnect-GUI не определился автоматически:

```powershell
powershell -ExecutionPolicy Bypass -File .\Install-OpenConnectFix.ps1 -InstallDir "C:\Path\To\OpenConnect-GUI"
```

## Проверка после подключения VPN

```powershell
Get-DnsClientNrptRule | Where-Object Comment -eq 'openconnect-gui-auto'
Get-NetIPInterface -AddressFamily IPv4 | Where-Object InterfaceAlias -like "gateway.*" | Select NlMtu
```

Ожидается: 2 NRPT-правила при поднятом VPN (0 при опущенном), MTU не
выше значения `-MaxMtu`.

## Откат

```powershell
powershell -ExecutionPolicy Bypass -File .\Install-OpenConnectFix.ps1 -Rollback
```

Восстанавливает `vpnc-script.js` из последнего бэкапа и удаляет
вспомогательный `nrpt-openconnect.ps1`.

## Важно

Обновление OpenConnect-GUI затирает `vpnc-script.js` - после него
просто запусти скрипт снова.
