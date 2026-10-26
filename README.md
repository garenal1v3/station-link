# station-link

YAM-пакет для рутованной Яндекс Станции: переключает колонку со штатного uniproxy
на свой прокси-сервер и умеет откатываться обратно.

Переключение — правка `/system/vendor/quasar/quasar.cfg`:

- `aliced.uniProxyUrl` → `ws://<сервер>:8443/uni.ws` (адрес из конфига пакета);
- `aliced.uniProxyQuicUrl` → `""` (выключить QUIC-обход; если ключа нет — он не добавляется).

Остальной файл не меняется: после записи скрипт проверяет, что обратная замена
даёт исходный файл байт в байт. Исходные значения сохраняются в
`/data/opt/station-link/endpoint-backup.json`; откат берёт их строго оттуда.

Фаза 0: только apply/rollback/check. Веб-морды пейринга здесь нет.

## Состав

```
package/plugin.toml                 манифест YAM (binary oneshot, permission exec)
package/control.sh                  check | apply | rollback | set-url
package/station-link.conf.example   шаблон конфига пакета
scripts/build-yap.py                сборка dist/station-link-<версия>.yap и .sha256
tests/test-control.sh               проверка логики на поддельном quasar.cfg (без колонки)
```

## Сборка

```sh
python3 scripts/build-yap.py        # → dist/station-link-0.1.0.yap и .yap.sha256
sh tests/test-control.sh            # нужен busybox; другая оболочка — SH=dash sh tests/...
```

Пакет — zip с `plugin.toml` в корне, распакованный размер в пределах 32 МиБ;
дата и права файлов фиксированы, повторная сборка даёт тот же sha256.

## Установка

Нужен установленный на колонку `yamd` (см. [YAM](https://github.com/nyakokitsu/yam),
docs/DEPLOYMENT.md) и CLI `yam` на компьютере в той же сети
(`YAM_URL=http://<колонка>:8099`, если колонку не находит сам).

Пакет запускает shell-скрипт, поэтому в настройках `yamd` должны быть разрешены
binary-пакеты: `allow_plugin_binaries = true` в `settings.toml` в каталоге данных
yamd (обычно `/data/quazar/yam/data/settings.toml`) или тот же переключатель в веб-интерфейсе.

```sh
sha256sum -c dist/station-link-0.1.0.yap.sha256
yam install dist/station-link-0.1.0.yap
yam enable station-link
```

## Настройка адреса сервера

Рабочий конфиг — `/data/opt/station-link/station-link.conf`; создаётся из шаблона
при первом запуске и переживает переустановку пакета. Проще всего задать адрес командой:

```sh
yam run station-link set-url ws://192.168.1.10:8443/uni.ws
```

или отредактировать файл на колонке (строки `KEY=value`, файл не исполняется):

- `SERVER_URL` — `ws://<сервер>:<порт>/uni.ws` или `wss://...`;
- `HEALTH_CHECK` — `1` (по умолчанию): перед apply проверить, что
  `http://<сервер>:<порт>/healthz` отвечает (только для `ws://`); `0` — не проверять.

## Применение и откат

```sh
yam run station-link check      # текущий endpoint, бэкап, состояние; ничего не меняет
yam run station-link apply      # переключить на SERVER_URL
yam run station-link apply --force   # без проверки /healthz
yam run station-link rollback   # вернуть исходный endpoint из бэкапа
```

После apply и rollback колонку нужно перезапустить (`/etc/init.d/S99quasar restart`
или перезагрузка), чтобы aliced перечитал конфиг. Скрипт сам ничего не перезапускает.

Что делает `apply`:

1. Проверяет `SERVER_URL` и `quasar.cfg`: `aliced` есть, `uniProxyUrl` и
   `uniProxyQuicUrl` встречаются не больше одного раза и являются простыми строками.
2. Отказывается, если колонка уже переключена и бэкап есть; если переключена на другой
   адрес — просит сначала rollback; если адрес уже серверный, а бэкапа нет — тоже отказ
   (оригинал неизвестен).
3. Проверяет `/healthz` сервера (если не `--force` и `HEALTH_CHECK=1`).
4. Сохраняет исходные значения в `endpoint-backup.json`. Существующий бэкап не
   перезаписывается: если cfg вернулся к оригиналу (например, после обновления прошивки),
   используется тот, что есть.
5. Перемонтирует раздел с cfg в rw — режим берётся из `/proc/mounts`, а не из `test -w`,
   который на ro-разделе врёт; пишет новый cfg во временный файл рядом, проверяет и
   подменяет переименованием; `sync`; возвращает раздел в ro (и при ошибке тоже).

`rollback` пишет значения из бэкапа, только если текущий endpoint ровно тот, что
поставил apply (`uniProxyUrl` = применённый адрес, `uniProxyQuicUrl` = `""`). Иначе —
стоп с выводом текущих, ожидаемых и исходных значений. После успешного отката бэкап
переносится в `endpoint-backup.json.restored`.

Журнал действий — `/data/opt/station-link/station-link.log`.

## Ограничения

- JSON правится средствами BusyBox (sed/grep), без разбора дерева: ключ ищется по
  всему файлу, поэтому он должен встречаться ровно один раз, а значение — быть строкой
  без экранированных символов. Иначе скрипт ничего не меняет и сообщает об этом.
- Проверка `/healthz` использует `wget -T 5`; если сборка BusyBox не знает `-T`,
  проверка не пройдёт — используйте `apply --force` после ручной проверки сервера.
- Пакет не проверялся на живой колонке; первый прогон — в задаче миграции.
