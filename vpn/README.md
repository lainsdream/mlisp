# lisp-vpn

Минимальный VPN-клиент на Common Lisp: поднимает системный TUN-туннель поверх
произвольного sing-box outbound (shadowsocks / vless / что угодно ещё
поддерживаемое sing-box), без GUI-клиентов вроде v2box.

Управляется из REPL — никакого автозапуска, никакого демона. Запустил
`(start-full)`, попользовался, вызвал `(stop-full)`.

## Файлы

- `singbox-ctl.lisp` — запуск/остановка самого sing-box-процесса
  (SOCKS5-инбаунд на `127.0.0.1:1080` + заданный outbound из конфига).
  Запускается **без sudo**, от текущего пользователя, через `setsid`.
- `tun-ctl.lisp` — создание TUN-интерфейса и перенаправление системного
  трафика через него, плюс аккуратный откат маршрутов при остановке. Все
  привилегированные действия (создание TUN, назначение IP, изменение
  таблицы маршрутизации, запуск/остановка `tun2socks`) идут не напрямую, а
  через один root-хелпер — см. ниже.

Оба файла управляют внешними процессами через `sb-ext:run-program`, но
делают это по-разному:

```
singbox-ctl.lisp:  sb-ext:run-program → setsid → sing-box   (без sudo)
tun-ctl.lisp:       sb-ext:run-program → sudo -n → lisp-vpn-priv <subcommand>
```

- `lisp-vpn-priv.c` — исходник самого хелпера, `*priv-helper-bin*` в
  `tun-ctl.lisp`. Небольшой C-бинарник с фиксированным списком сабкоманд
  (`add-proxy-route`, `remove-proxy-route`, `enable-tun-default`,
  `restore-default`, `assign-tun`, `start-tun`, `stop-tun`), который сам,
  уже будучи root, вызывает `route`/`ifconfig`/`tun2socks` по абсолютным
  путям, без шелла. Компилируется и ставится в
  `/usr/local/libexec/lisp-vpn-priv` — см. «Сборка root-хелпера» ниже.

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

# setsid — отвязывает sing-box от Lisp-сессии на уровне process group,
# чтобы закрытие терминала/краш Lisp не убивали уже поднятый VPN
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
`*singbox-bin*` и `*setsid-bin*` в начале `singbox-ctl.lisp` — подставить
сюда.

## Сборка root-хелпера (lisp-vpn-priv)

Путь к `tun2socks` из Lisp напрямую не используется. Вместо этого хелпер
исполняет фиксированный, **root-owned** путь `/usr/local/libexec/lisp-vpn-tun2socks`
— это намеренно: `tun2socks` лежит в `/usr/local/bin`, который писать может
не только root (обычно владелец — текущий пользователь или группа `admin`,
это тот самый путь, куда вы вручную положили бинарник с GitHub Releases).
Если бы хелпер исполнял `tun2socks` прямо оттуда, то любой, кто может
подменить этот файл (не обязательно root — например, скомпрометированный
процесс от вашего же пользователя), получал бы код-выполнение от root через
`sudo -n lisp-vpn-priv start-tun`. Поэтому исполняемый tun2socks — это
отдельная, скопированная под root копия, до которой обычный пользователь
дотянуться на запись не может:

```sh
# посмотреть исходник перед сборкой
clang -Wall -Wextra -Werror -O2 lisp-vpn-priv.c -o lisp-vpn-priv
sudo install -d -o root -g wheel -m 0755 /usr/local/libexec
sudo install -o root -g wheel -m 0755 lisp-vpn-priv /usr/local/libexec/lisp-vpn-priv
# копия tun2socks под root — путь-источник свой, путь назначения фиксирован
sudo install -o root -g wheel -m 0755 /usr/local/bin/tun2socks \
  /usr/local/libexec/lisp-vpn-tun2socks
```

Если обновишь `tun2socks` вручную (новым бинарником с GitHub Releases,
как в разделе «Зависимости» выше) — нужно **повторить последнюю команду
`install`**, чтобы root-копия в `/usr/local/libexec/lisp-vpn-tun2socks`
подхватила новую версию. Homebrew тут ни при чём — сам `tun2socks` в его
core-репозитории не поставляется, только `setsid`/`sing-box` ставятся через
`brew`; root-копия не следит за исходным файлом автоматически в любом
случае.

## sudo без пароля

Создание TUN-интерфейса и изменение таблицы маршрутизации требует root.
Весь privileged-код в этом репозитории идёт через одну точку —
`/usr/local/libexec/lisp-vpn-priv` (`*priv-helper-bin*` в `tun-ctl.lisp`),
вызываемую как `sudo -n lisp-vpn-priv <subcommand> ...`. Хелпер сам
проверяет `geteuid() == 0`, принимает жёстко заданный набор сабкоманд,
валидирует все аргументы (`inet_pton` для IP, `utun[0-9]+` для имени
интерфейса) и никогда не вызывает шелл — так что в sudoers достаточно
разрешить без пароля именно его:

```sudoers
твой_username ALL=(root) NOPASSWD: /usr/local/libexec/lisp-vpn-priv
```

Если раньше стояли отдельные записи на `setsid`/`route`/`ifconfig`/`kill` —
их нужно **удалить** (`sudo visudo`): `NOPASSWD` на голый `setsid` эквивалентен
разрешению запускать под root что угодно.

`route`/`ifconfig`/`tun2socks` хелпер вызывает уже сам, будучи root — им
отдельная строка в sudoers не нужна. `sing-box` (в `singbox-ctl.lisp`) и
`kill` (при остановке sing-box) вообще не идут через sudo — sing-box
намеренно запускается непривилегированным, от текущего пользователя.

`install -o root -g wheel -m 0755` на шаге сборки уже делает хелпер
непригодным для правки обычным пользователем — отдельно `chown`/`chmod`
после этого делать не нужно, если ставили именно так.

Проверка, что sudo-правило сработало (не должно просить пароль,
`unknown action` в выводе — это нормально, значит хелпер запустился):
```bash
sudo -n /usr/local/libexec/lisp-vpn-priv 2>&1
```

### Осознанные ограничения хелпера

Из README самого `lisp-vpn-priv`:

- Хелпер может менять только default route и один IPv4 host-route — этого
  достаточно для его задачи, но не более: он не умеет исполнять произвольные
  программы от root.
- Оригинальный gateway (`*original-gateway*`) по-прежнему захватывает и
  хранит **Lisp** (`capture-original-route` в `tun-ctl.lisp`), не хелпер —
  это не atomic-транзакция на уровне сети. Следующий шаг hardening'а (пока
  не сделан) — чтобы хелпер сам захватывал и переживал исходный gateway,
  и сам делал setup/rollback.

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
  есть, будет `File exists`, нужно сначала `route delete default`. Это
  относится к ручному вмешательству (см. троблшутинг ниже) — сам хелпер
  `enable-tun-default`/`restore-default` этой проблемы не имеет, он делает
  `route change default ...` одной атомарной командой, а не delete+add, так
  что окна "default route вообще отсутствует" между шагами нет.
- **`*tun-ip*` в `tun-ctl.lisp` сейчас ни на что не влияет** — реальный IP
  TUN-интерфейса зашит в `lisp-vpn-priv.c` как `TUN_IP` (`198.18.0.1`,
  используется и в `assign-tun`, и в `enable-tun-default`/`restore-default`).
  `assign-tun-ip` передаёт хелперу только имя интерфейса (`*tun-name*`), не
  IP. Поменять `*tun-ip*` в Lisp — ничего не изменит; чтобы реально сменить
  подсеть, нужно менять `TUN_IP` в C-файле и пересобирать хелпер.
- **`sudo`-обёрнутый процесс без `:input nil` в `run-program`** может зависать
  в статусе `T` (Stopped) — задаётся терминалом/tty-хендшейком. Всегда
  указывай `:input nil` для фоновых sudo-процессов.
- **Перезагрузка `singbox-ctl.lisp` через `(load ...)` сбрасывает
  `*process*` обратно в `nil`** — если sing-box уже был запущен, Lisp
  "теряет" его PID, и `stop` перестаёт видеть его через прямой хендл (хотя
  `find-and-kill-by-name`-фоллбэк по `pgrep -f` при этом всё равно отработает
  корректно). tun2socks эта проблема не касается — им управляет
  `lisp-vpn-priv`, а не Lisp-переменная, так что перезагрузка `tun-ctl.lisp`
  на него не влияет. Если после `(stop-full)` `curl` всё ещё идёт через
  старый IP, проверяй `ps aux | grep -E "sing-box|tun2socks"` вручную.
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
- **`stop` в `singbox-ctl.lisp` намеренно не использует `sudo`** — sing-box
  запускается от текущего пользователя, поэтому и убивается как текущий
  пользователь, обычным `/bin/kill`. Если когда-нибудь понадобится звать
  `sudo kill`/что-то ещё через sudo напрямую (в обход `lisp-vpn-priv`), не
  забыть `sudo -n` (non-interactive) — иначе REPL молча зависнет на запросе
  пароля из недр `run-program`, где ввести его негде.
- **`sudo -n` к хелперу тоже может зависнуть, если строка в sudoers не
  сработала** — например, из-за опечатки в пути к `lisp-vpn-priv` или если
  `visudo` не сохранил правило. `-n` должен превращать это в мгновенную
  ошибку вместо запроса пароля — если вместо этого REPL висит, значит
  `-n` где-то потерялся.
- **PID tun2socks хелпер хранит в `/var/run/lisp-vpn-tun2socks.pid`, а не в
  Lisp** — если машина перезагрузилась или tun2socks упал сам, PID-файл
  остаётся, и следующий `start-tun` откажется стартовать (`pid file already
  exists`) до ручной проверки/удаления файла. Это осознанное решение
  хелпера — он не убивает "что-то по этому PID" не глядя: перед `SIGTERM`
  проверяет через `proc_pidpath`, что процесс с этим PID — действительно
  `/usr/local/libexec/lisp-vpn-tun2socks`, а не случайно переиспользованный
  тем же PID посторонний процесс.
- **`stop-tun` шлёт tun2socks `SIGTERM`, не `SIGKILL`** — даёт процессу
  корректно завершиться. Если он не отвечает на `SIGTERM` (завис), хелпер
  всё равно удалит PID-файл и вернёт успех — реального "мёртв ли процесс"
  после этого нужно проверять вручную (`ps aux | grep tun2socks`).
- **Лог tun2socks теперь идёт не в stdout Lisp-процесса, а в
  `/var/log/lisp-vpn-tun2socks.log`** — потому что `tun2socks` запускается
  через `setsid` внутри хелпера и продолжает жить после того, как сам
  хелпер (и его временный stdout/stderr-pipe от `sudo -n`) уже завершился;
  если бы он писал в унаследованный pipe, первая же запись в лог после
  этого могла бы упасть по `SIGPIPE` и убить процесс — поэтому хелпер сразу
  переоткрывает stdout/stderr на этот файл, прежде чем exec'нуть tun2socks.