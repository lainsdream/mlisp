# lisp-vpn

Минимальный VPN-клиент на Common Lisp: поднимает системный TUN-туннель поверх
произвольного sing-box outbound (shadowsocks / vless / что угодно ещё
поддерживаемое sing-box), без GUI-клиентов вроде v2box.

Управляется из REPL — никакого автозапуска, никакого демона. Запустил
`(start-full)`, попользовался, вызвал `(stop-full)`.

## Файлы

- `singbox-ctl.lisp` — запуск/остановка самого sing-box-процесса
  (SOCKS5-инбаунд на `127.0.0.1:1080` + заданный outbound из конфига).
- `tun-ctl.lisp` — создание TUN-интерфейса через `tun2socks`, заворачивает
  через него весь системный трафик, плюс аккуратный откат маршрутов при
  остановке.

## Как это работает

```
весь трафик системы
        │
   default route → TUN (utun9)
        │
     tun2socks (перехватывает IP-пакеты, шлёт в SOCKS5)
        │
   127.0.0.1:1080 (sing-box inbound)
        │
     sing-box outbound (shadowsocks / vless / ...)
        │
   твой прокси-сервер
```

Трафик именно **к самому прокси-серверу** явно исключается из TUN
(`exclude-proxy-server`), иначе получается петля: TUN заворачивает всё,
включая соединение к прокси, которое само должно идти через TUN — и ничего
не работает.

## Зависимости

Ставятся один раз, руками, не через package manager проекта — это внешние
бинарники, которыми Lisp просто рулит через `run-program`.

```bash
# sing-box — сам прокси-движок (VLESS/Shadowsocks/Trojan/...)
brew install sing-box

# tun2socks — создаёт TUN-интерфейс, форвардит в SOCKS5
# в homebrew core этого пакета нет, ставится бинарником с GitHub Releases:
# https://github.com/xjasonlyu/tun2socks/releases
# (взять tun2socks-darwin-arm64.zip для Apple Silicon, -amd64 для Intel)
sudo mv tun2socks-darwin-arm64 /usr/local/bin/tun2socks

# setsid — отвязывает sing-box/tun2socks от Lisp-сессии на уровне process
# group, чтобы закрытие терминала/краш Lisp не убивали уже поднятый VPN
brew install util-linux
# keg-only, бинарник лежит по прямому пути:
# /opt/homebrew/opt/util-linux/bin/setsid
```

Узнать реальные пути после установки (могут отличаться на Intel Mac):
```bash
which sing-box
which tun2socks
ls /opt/homebrew/opt/util-linux/bin/setsid
```
Подставить в `*singbox-bin*` / `*tun2socks-bin*` / `*setsid-bin*` в начале
`singbox-ctl.lisp`.

## sudo без пароля

Создание TUN-интерфейса и изменение таблицы маршрутизации требует root.
Чтобы не вводить пароль на каждый вызов, разреши конкретные бинарники без
пароля через `sudo visudo`:

```
твой_username ALL=(ALL) NOPASSWD: /usr/local/bin/tun2socks, /sbin/route, /sbin/ifconfig, /opt/homebrew/opt/util-linux/bin/setsid
```

Проверка, что сработало (не должно просить пароль):
```bash
sudo /sbin/route -n get default
```

## Конфиг

`*config-path*` в `singbox-ctl.lisp` указывает на JSON-конфиг sing-box —
обычный формат с `inbounds`/`outbounds`, `inbound` всегда:

```json
{
  "type": "mixed",
  "listen": "127.0.0.1",
  "listen_port": 1080
}
```

`outbound` — под конкретный протокол (shadowsocks/vless/...), сгенерировать
можно вручную или взять из `speedtest-configs.lisp` (парсер `vless://`/`ss://`
URI в этом же репо).

**`*proxy-server-ip*` в `tun-ctl.lisp` должен совпадать с IP сервера в
конфиге** — иначе будет петля (TUN пытается завернуть даже трафик к самому
прокси). Забыть поменять при смене конфига — самая частая причина "всё
сломалось, интернет не работает".

## Использование

```lisp
(load "singbox-ctl.lisp")
(load "tun-ctl.lisp")

(start-full)   ; поднимает всё: sing-box → tun2socks → маршруты
(status)       ; проверить, жив ли sing-box
(stop-full)    ; корректно всё останавливает и откатывает маршруты
```

Проверка, что реально работает (в отдельном терминале):
```bash
curl https://cloudflare.com/cdn-cgi/trace
```
Должен показать IP и `loc` прокси-сервера, а не твой настоящий.

## Если что-то пошло не так и пропал интернет

Самое частое: `route add default` упал на середине, default route отсутствует
(`route -n get default` → `not in table`). Восстановить вручную:

```bash
sudo route delete default
sudo route add default <твой_обычный_gateway>
```

Узнать/записать свой обычный gateway заранее, **до** первого эксперимента:
```bash
route -n get default
```

Если ничего не помогает — просто переключи Wi-Fi (система сама пропишет route
через DHCP):
```bash
sudo networksetup -setairportpower en0 off
sudo networksetup -setairportpower en0 on
```

## Известные грабли (из личного опыта отладки)

- **`route add default` не заменяет существующий route** — если default уже
  есть, будет `File exists`. Нужно сначала `route delete default`.
- **`--interface` у tun2socks — это НЕ имя создаваемого TUN**, это физический
  исходящий интерфейс (обычно определяется сам). Указание туда имени TUN даёт
  `no such network interface`, потому что интерфейс с таким именем ещё не
  существует на момент старта.
- **`sudo`-обёрнутый процесс без `:input nil` в `run-program`** может зависать
  в статусе `T` (Stopped) — задаётся терминалом/tty-хендшейком. Всегда
  указывай `:input nil` для фоновых sudo-процессов.
- **Перезагрузка `.lisp`-файла через `(load ...)` сбрасывает
  `defparameter`-переменные** (`*process*`, `*tun-process*`) обратно в `nil`
  — если процессы уже были запущены, Lisp "теряет" их PID, и `stop`/`stop-tun`
  перестают их видеть и убивать. Процессы при этом продолжают работать сами
  по себе — проверяй `ps aux | grep -E "sing-box|tun2socks"` вручную, если
  `(stop-full)` отчитался об успехе, а `curl` всё ещё идёт через старый IP.
- **tun2socks не всегда сам назначает IP интерфейсу** — иногда нужно вручную
  `ifconfig utun9 198.18.0.1 198.18.0.1 up` перед прописыванием default route
  через него.
- **`setsid` форкает, а не exec'ает себя** — `run-program` возвращает PID
  самого `setsid`-обёртки, а не реального дочернего процесса (sing-box /
  tun2socks). `setsid` быстро завершается сам, `*process*`/`*tun-process*`
  в Lisp начинают указывать на уже мёртвый процесс, и `process-alive-p`
  всегда возвращает `NIL` — обычный `process-kill` по этому PID ничего не
  убивает. Решение: не полагаться на PID из `run-program` вообще, искать и
  убивать процессы по имени командной строки через `pgrep -f` /
  `find-and-kill-by-name`, это основной путь остановки, не fallback.
- **`sudo kill` требует отдельной строки в sudoers** — если разрешил
  `NOPASSWD` только для `route`/`ifconfig`/`tun2socks`/`setsid`, а `stop`
  дёргает `sudo kill`, REPL зависнет молча на запросе пароля. Добавь `kill`
  в sudoers, и используй `sudo -n kill ...` (non-interactive) в коде — так
  при отсутствии прав команда сразу упадёт с ошибкой вместо зависания.