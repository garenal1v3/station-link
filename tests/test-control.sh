#!/bin/sh
# Проверка логики control.sh на поддельном quasar.cfg, без колонки и без mount.
# Запуск: sh tests/test-control.sh  (оболочка для control.sh — $SH, по умолчанию busybox sh).
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SH=${SH:-busybox sh}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fail=0
# Закрытый локальный порт: проверка /healthz в check отказывает сразу.
url=ws://127.0.0.1:1/uni.ws

setup() {
	rm -rf "$work/case"
	mkdir -p "$work/case/cfg"
	printf '%s' "$1" >"$work/case/cfg/quasar.cfg"
	cp "$work/case/cfg/quasar.cfg" "$work/case/orig.cfg"
	export STATION_LINK_DATA_DIR="$work/case/state"
	export STATION_LINK_DEVICE_CONFIG="$work/case/cfg/quasar.cfg"
	export STATION_LINK_NO_REMOUNT=1
}
run() { $SH "$root/package/control.sh" "$@" >"$work/case/out" 2>&1; }
ok() { printf 'ok   %s\n' "$1"; }
bad() {
	printf 'FAIL %s\n' "$1"
	sed 's/^/     | /' "$work/case/out" 2>/dev/null || true
	fail=1
}
expect_ok() { if run "$@"; then ok "$desc"; else bad "$desc"; fi; }
expect_fail() { if run "$@"; then bad "$desc (ожидался отказ)"; else ok "$desc"; fi; }
same_as_orig() { if cmp -s "$work/case/cfg/quasar.cfg" "$work/case/orig.cfg"; then ok "$1"; else bad "$1"; fi; }
has() { if grep -q "$1" "$work/case/cfg/quasar.cfg"; then ok "$2"; else bad "$2"; fi; }

pretty='{
    "aliced": {
        "uniProxyUrl": "wss://uniproxy.alice.yandex.net/uni.ws?a=1&b=2",
        "uniProxyQuicUrl" : "quic://uniproxy.alice.yandex.net:443",
        "other": 3
    },
    "unknown": {"keep": true}
}
'

# 1. Полный цикл: настройка, apply, повторный apply, rollback.
setup "$pretty"
desc='check без бэкапа — оригинал'; expect_ok check
desc='apply без SERVER_URL — отказ'; expect_fail apply --force
desc='set-url с мусором — отказ'; expect_fail set-url 'ws://x"y/uni.ws'
desc='set-url'; expect_ok set-url "$url"
desc='apply'; expect_ok apply --force
has "\"uniProxyUrl\": \"$url\"" 'uniProxyUrl переключён'
has '"uniProxyQuicUrl" : ""' 'uniProxyQuicUrl обнулён'
has '"keep": true' 'остальной cfg на месте'
if grep -q 'a=1&b=2' "$STATION_LINK_DATA_DIR/endpoint-backup.json"; then ok 'бэкап содержит оригинал'; else bad 'бэкап содержит оригинал'; fi
desc='check после apply'; expect_ok check
cp "$work/case/cfg/quasar.cfg" "$work/case/applied.cfg"
cp "$STATION_LINK_DATA_DIR/endpoint-backup.json" "$work/case/backup.json"
desc='повторный apply — отказ'; expect_fail apply --force
if cmp -s "$work/case/cfg/quasar.cfg" "$work/case/applied.cfg" && cmp -s "$STATION_LINK_DATA_DIR/endpoint-backup.json" "$work/case/backup.json"; then
	ok 'повторный apply ничего не тронул'
else bad 'повторный apply ничего не тронул'; fi
desc='rollback'; expect_ok rollback
same_as_orig 'rollback вернул cfg байт в байт'
if [ ! -e "$STATION_LINK_DATA_DIR/endpoint-backup.json" ] && [ -e "$STATION_LINK_DATA_DIR/endpoint-backup.json.restored" ]; then
	ok 'бэкап перенесён в .restored'
else bad 'бэкап перенесён в .restored'; fi
desc='повторный rollback — отказ'; expect_fail rollback

# 2. Однострочный cfg без uniProxyQuicUrl: ключ не добавляется.
setup '{"aliced":{"uniProxyUrl":"wss://uniproxy.alice.yandex.net/uni.ws","x":1},"y":2}'
run set-url "$url"
desc='apply без QUIC-ключа'; expect_ok apply --force
if grep -q uniProxyQuicUrl "$work/case/cfg/quasar.cfg"; then bad 'QUIC-ключ не добавлен'; else ok 'QUIC-ключ не добавлен'; fi
desc='rollback без QUIC-ключа'; expect_ok rollback
same_as_orig 'rollback однострочного cfg байт в байт'

# 3. Изменение извне после apply: оба направления отказываются и не пишут.
setup "$pretty"
run set-url "$url"
run apply --force
sed 's|"uniProxyQuicUrl" : ""|"uniProxyQuicUrl" : "quic://changed"|' "$work/case/cfg/quasar.cfg" >"$work/case/x" && cat "$work/case/x" >"$work/case/cfg/quasar.cfg"
cp "$work/case/cfg/quasar.cfg" "$work/case/changed.cfg"
desc='rollback при чужом QUIC — отказ'; expect_fail rollback
desc='apply при чужом QUIC — отказ'; expect_fail apply --force
desc='check при чужом QUIC — ненулевой код'; expect_fail check
if cmp -s "$work/case/cfg/quasar.cfg" "$work/case/changed.cfg"; then ok 'cfg не тронут при отказах'; else bad 'cfg не тронут при отказах'; fi

# 4. Бэкап есть, cfg вернулся к оригиналу (например, обновление прошивки): apply переиспользует бэкап.
setup "$pretty"
run set-url "$url"
run apply --force
cp "$STATION_LINK_DATA_DIR/endpoint-backup.json" "$work/case/backup.json"
cp "$work/case/orig.cfg" "$work/case/cfg/quasar.cfg"
desc='apply с оставшимся бэкапом'; expect_ok apply --force
if cmp -s "$STATION_LINK_DATA_DIR/endpoint-backup.json" "$work/case/backup.json"; then ok 'бэкап не перезаписан'; else bad 'бэкап не перезаписан'; fi
desc='rollback после переиспользования'; expect_ok rollback
same_as_orig 'cfg снова исходный'

# 5. Смена адреса без rollback — отказ.
setup "$pretty"
run set-url "$url"
run apply --force
run set-url ws://10.0.0.2:8443/uni.ws
desc='apply на другой адрес без rollback — отказ'; expect_fail apply --force

# 6. Неоднозначный cfg: два uniProxyUrl.
setup '{"aliced":{"uniProxyUrl":"wss://a/uni.ws"},"other":{"uniProxyUrl":"wss://b/uni.ws"}}'
run set-url "$url"
desc='два uniProxyUrl — отказ'; expect_fail apply --force
same_as_orig 'cfg не тронут'

# 7. Уже указывает на сервер, бэкапа нет — оригинал неизвестен.
setup "{\"aliced\":{\"uniProxyUrl\":\"$url\",\"uniProxyQuicUrl\":\"\"}}"
run set-url "$url"
desc='уже переключено без бэкапа — отказ'; expect_fail apply --force

# 8. Проверка /healthz: недоступный сервер без --force — отказ.
setup "$pretty"
run set-url ws://127.0.0.1:2/uni.ws
desc='apply при недоступном /healthz — отказ'; expect_fail apply
same_as_orig 'cfg не тронут'

[ "$fail" = 0 ] && echo 'все проверки прошли' || { echo 'есть ошибки'; exit 1; }
