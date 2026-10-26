#!/bin/sh
# station-link: переключение uniProxyUrl колонки на свой сервер и откат.
# Запуск на колонке: yam run station-link check|apply|rollback|set-url <url>.
# Окружение — BusyBox: без timeout, jq и awk-арифметики; test -w на ro-разделе
# врёт, поэтому режим монтирования берётся из /proc/mounts.
set -eu
umask 077

package=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
state=${STATION_LINK_DATA_DIR:-/data/opt/station-link}
cfg=${STATION_LINK_DEVICE_CONFIG:-/system/vendor/quasar/quasar.cfg}
conf=$state/station-link.conf
backup=$state/endpoint-backup.json
logfile=$state/station-link.log
# Только для проверки логики на стенде, не на колонке: не трогать mount.
no_remount=${STATION_LINK_NO_REMOUNT:-0}

remounted=''
tmpfile=''
locked=''

say() { printf '%s\n' "$*"; }
log() {
	say "$*"
	printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || echo -)" "$*" >>"$logfile" 2>/dev/null || true
}
die() {
	log "ОШИБКА: $*"
	exit 1
}

cleanup() {
	status=$?
	if [ -n "$tmpfile" ]; then rm -f "$tmpfile"; fi
	if [ -n "$remounted" ]; then
		sync
		if mount -o remount,ro "$remounted"; then
			if ! mount_is_ro "$remounted"; then
				log "ВНИМАНИЕ: $remounted не вернулся в ro, проверьте вручную"
			fi
		else
			log "ВНИМАНИЕ: не удалось вернуть $remounted в ro, проверьте вручную"
		fi
		remounted=''
	fi
	if [ -n "$locked" ]; then rmdir "$locked" 2>/dev/null || true; fi
	exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

usage() {
	cat <<'EOF'
usage: control.sh <команда>
  check            показать текущий endpoint, бэкап и настройки (ничего не меняет)
  apply [--force]  переключить колонку на SERVER_URL из конфига (--force — без проверки /healthz)
  rollback         вернуть endpoint из бэкапа
  set-url <url>    записать SERVER_URL в конфиг пакета
EOF
}

# --- Конфиг пакета ---------------------------------------------------------

ensure_state() {
	mkdir -p "$state"
	chmod 0700 "$state"
	if [ ! -f "$conf" ]; then
		cp "$package/station-link.conf.example" "$conf"
		chmod 0600 "$conf"
	fi
}

# Конфиг читается, а не исполняется: последнее значение KEY=... побеждает.
conf_get() {
	sed -n "s/^[[:space:]]*$1=//p" "$conf" | tail -n 1 | sed 's/[[:space:]]*$//'
}

# ws(s)://хост[:порт]/путь из безопасных символов: значение попадает в sed и JSON.
valid_url() {
	printf '%s\n' "$1" | grep -q '^wss\{0,1\}://[]A-Za-z0-9._~%:[-]\{1,\}/[]A-Za-z0-9._~%:/?=[-]*$'
}

load_conf() {
	ensure_state
	server_url=$(conf_get SERVER_URL)
	health_check=$(conf_get HEALTH_CHECK)
	[ -n "$health_check" ] || health_check=1
}

require_server_url() {
	[ -n "$server_url" ] || die "SERVER_URL не задан: yam run station-link set-url ws://<сервер>:8443/uni.ws"
	valid_url "$server_url" || die "SERVER_URL некорректен: '$server_url' (ожидается ws://<сервер>:<порт>/uni.ws)"
}

# --- Разбор quasar.cfg -------------------------------------------------------
# Правим ровно одно вхождение ключа со строковым значением без экранирования.
# Состояние ключа: "A" — ключа нет, "P:<значение>" — есть.

key_count() {
	grep -o "\"$1\"[[:space:]]*:" "$2" | wc -l | tr -d ' '
}

# Печатает состояние ключа или завершает скрипт, если разобрать нельзя.
read_key() {
	n=$(key_count "$1" "$2")
	case "$n" in
	0) say A ;;
	1)
		v=$(sed -n 's|.*"'"$1"'"[[:space:]]*:[[:space:]]*"\([^"\\]*\)".*|=\1|p' "$2")
		case "$v" in
		=*) say "P:${v#=}" ;;
		*) return 2 ;;
		esac
		;;
	*) return 3 ;;
	esac
}

read_endpoint() {
	f=$1
	grep -q '"aliced"' "$f" || die "в $f нет секции aliced"
	if ! cur_url=$(read_key uniProxyUrl "$f"); then
		die "в $f не разобрать uniProxyUrl (ключ встречается не один раз или значение не строка)"
	fi
	if ! cur_quic=$(read_key uniProxyQuicUrl "$f"); then
		die "в $f не разобрать uniProxyQuicUrl (ключ встречается не один раз или значение не строка)"
	fi
	[ "$cur_url" != A ] || die "в $f нет aliced.uniProxyUrl"
}

show() {
	case "$1" in
	A) say '(нет ключа)' ;;
	P:) say '""' ;;
	*) say "${1#P:}" ;;
	esac
}

sed_escape() {
	printf '%s\n' "$1" | sed 's/[\\&|]/\\&/g'
}

# patch_cfg <src> <dst> <url-state> <quic-state>: заменить значения; отсутствующий
# ключ не добавляется (у ключа "A" значение не трогаем).
patch_cfg() {
	u=$(sed_escape "${3#P:}")
	set -- "$1" "$2" "$3" "$4" -e 's|\("uniProxyUrl"[[:space:]]*:[[:space:]]*\)"[^"\\]*"|\1"'"$u"'"|'
	if [ "$4" != A ]; then
		q=$(sed_escape "${4#P:}")
		set -- "$@" -e 's|\("uniProxyQuicUrl"[[:space:]]*:[[:space:]]*\)"[^"\\]*"|\1"'"$q"'"|'
	fi
	src=$1 dst=$2
	shift 4
	sed "$@" "$src" >"$dst"
}

# --- Бэкап -------------------------------------------------------------------

backup_field() {
	v=$(sed -n 's|^  "'"$1"'": "\([^"\\]*\)",\{0,1\}$|=\1|p' "$backup")
	case "$v" in
	=*) say "P:${v#=}" ;;
	*)
		if grep -q '^  "'"$1"'": null,\{0,1\}$' "$backup"; then say A; else return 1; fi
		;;
	esac
}

load_backup() {
	b_config=$(backup_field config) || die "бэкап $backup повреждён (config)"
	b_applied=$(backup_field applied) || die "бэкап $backup повреждён (applied)"
	b_url=$(backup_field uniProxyUrl) || die "бэкап $backup повреждён (uniProxyUrl)"
	b_quic=$(backup_field uniProxyQuicUrl) || die "бэкап $backup повреждён (uniProxyQuicUrl)"
	[ "$b_url" != A ] && [ "$b_url" != P: ] || die "в бэкапе $backup нет исходного uniProxyUrl"
	[ "$b_config" = "P:$cfg" ] || die "бэкап $backup сделан для $(show "$b_config"), а не для $cfg"
}

json_value() {
	case "$1" in
	A) say null ;;
	*) say "\"${1#P:}\"" ;;
	esac
}

# Существующий бэкап не перезаписывается никогда.
write_backup() {
	[ ! -e "$backup" ] || die "бэкап $backup уже существует"
	t=$backup.tmp.$$
	cat >"$t" <<EOF
{
  "config": "$cfg",
  "applied": "$server_url",
  "uniProxyUrl": $(json_value "$cur_url"),
  "uniProxyQuicUrl": $(json_value "$cur_quic"),
  "created": "$(date '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null || echo unknown)"
}
EOF
	chmod 0600 "$t"
	# ln не перезаписывает цель: защита от гонки с параллельным apply.
	if ! ln "$t" "$backup" 2>/dev/null; then
		rm -f "$t"
		die "не удалось создать бэкап $backup"
	fi
	rm -f "$t"
	sync
	load_backup
	[ "$b_url" = "$cur_url" ] && [ "$b_quic" = "$cur_quic" ] || die "бэкап $backup записался неверно, cfg не тронут"
}

# --- Монтирование ---------------------------------------------------------------

# Точка монтирования, содержащая путь: самое длинное совпадение, при равенстве — последнее.
mount_point() {
	best='' best_opts=''
	while read -r _dev mnt _fs opts _rest; do
		case "$mnt" in
		/) ok=1 ;;
		*) case "$1/" in "$mnt"/*) ok=1 ;; *) ok='' ;; esac ;;
		esac
		if [ -n "$ok" ] && [ "${#mnt}" -ge "${#best}" ]; then
			best=$mnt best_opts=$opts
		fi
	done </proc/mounts
	[ -n "$best" ] || return 1
	say "$best $best_opts"
}

mount_is_ro() {
	set -- $(mount_point "$1")
	case ",${2:-}," in *,ro,*) return 0 ;; *) return 1 ;; esac
}

make_writable() {
	if [ "$no_remount" = 1 ]; then return 0; fi
	mp=$(mount_point "$1") || die "не найти точку монтирования для $1"
	set -- $mp
	mnt=$1
	case ",${2:-}," in
	*,ro,*)
		log "remount rw $mnt"
		mount -o remount,rw "$mnt" || die "не удалось перемонтировать $mnt в rw"
		remounted=$mnt
		! mount_is_ro "$mnt" || die "$mnt всё ещё ro по /proc/mounts"
		;;
	esac
}

restore_ro() {
	if [ -n "$remounted" ]; then
		mnt=$remounted
		sync
		log "remount ro $mnt"
		mount -o remount,ro "$mnt" || die "не удалось вернуть $mnt в ro"
		remounted=''
		mount_is_ro "$mnt" || log "ВНИМАНИЕ: $mnt не ro по /proc/mounts, проверьте вручную"
	fi
}

# --- Запись cfg ------------------------------------------------------------------

# Пишет новые значения во временный файл рядом с cfg, проверяет его и подменяет
# cfg переименованием. Проверка: новые значения на месте, а обратная замена
# даёт исходный файл байт в байт — значит, больше ничего не изменилось.
write_cfg() {
	new_url=$1 new_quic=$2
	tmpfile=$(dirname -- "$cfg")/.station-link.cfg.$$
	cp -p "$cfg" "$tmpfile" || die "не удалось создать $tmpfile"
	patch_cfg "$cfg" "$tmpfile" "$new_url" "$new_quic" || die "не удалось подготовить новый cfg"
	got_url=$(read_key uniProxyUrl "$tmpfile") || die "новый cfg не разбирается"
	got_quic=$(read_key uniProxyQuicUrl "$tmpfile") || die "новый cfg не разбирается"
	[ "$got_url" = "$new_url" ] && [ "$got_quic" = "$new_quic" ] || die "новый cfg не содержит ожидаемых значений, cfg не тронут"
	if ! patch_cfg "$tmpfile" /dev/stdout "$cur_url" "$cur_quic" | cmp -s - "$cfg"; then
		die "проверка обратной заменой не прошла, cfg не тронут"
	fi
	mv -f "$tmpfile" "$cfg" || die "не удалось заменить $cfg"
	tmpfile=''
	sync
	read_endpoint "$cfg"
	[ "$cur_url" = "$new_url" ] && [ "$cur_quic" = "$new_quic" ] || die "после записи $cfg содержит неожиданные значения"
}

lock() {
	mkdir "$state/.lock" 2>/dev/null || die "уже идёт другой запуск (или остался $state/.lock — удалите, если это не так)"
	locked=$state/.lock
}

resolve_cfg() {
	real=$(readlink -f "$cfg" 2>/dev/null) && [ -n "$real" ] && cfg=$real
	[ -f "$cfg" ] && [ -r "$cfg" ] || die "нет файла $cfg"
}

# После apply QUIC выключен (""), если ключ был; если ключа не было — его и нет.
applied_quic() {
	case "$1" in A) say A ;; *) say P: ;; esac
}

health_url() {
	case "$1" in
	ws://*) hp=${1#ws://} && say "http://${hp%%/*}/healthz" ;;
	*) return 1 ;;
	esac
}

# --- Команды ---------------------------------------------------------------------

cmd_check() {
	load_conf
	say "конфиг пакета: $conf"
	if [ -z "$server_url" ]; then
		say "SERVER_URL:    (не задан)"
	elif valid_url "$server_url"; then
		say "SERVER_URL:    $server_url"
	else
		say "SERVER_URL:    $server_url (НЕКОРРЕКТЕН)"
	fi
	resolve_cfg
	read_endpoint "$cfg"
	say "quasar.cfg:    $cfg"
	if [ "$no_remount" != 1 ] && mp=$(mount_point "$cfg"); then
		say "раздел:        $mp"
	fi
	say "uniProxyUrl:     $(show "$cur_url")"
	say "uniProxyQuicUrl: $(show "$cur_quic")"
	verdict=0
	if [ -e "$backup" ]; then
		load_backup
		say "бэкап:         $backup"
		say "  исходный uniProxyUrl:     $(show "$b_url")"
		say "  исходный uniProxyQuicUrl: $(show "$b_quic")"
		say "  применён адрес:           $(show "$b_applied")"
		if [ "$cur_url" = "$b_applied" ] && [ "$cur_quic" = "$(applied_quic "$b_quic")" ]; then
			say "состояние:     ПЕРЕКЛЮЧЕНО на свой сервер (rollback доступен)"
		elif [ "$cur_url" = "$b_url" ] && [ "$cur_quic" = "$b_quic" ]; then
			say "состояние:     ОРИГИНАЛ, но бэкап остался (apply его переиспользует)"
		else
			say "состояние:     ИЗМЕНЕНО ИЗВНЕ — не совпадает ни с бэкапом, ни с применённым адресом"
			verdict=1
		fi
	else
		say "бэкап:         нет"
		if [ -n "$server_url" ] && [ "$cur_url" = "P:$server_url" ]; then
			say "состояние:     указывает на SERVER_URL, но бэкапа нет — оригинал неизвестен"
			verdict=1
		else
			say "состояние:     ОРИГИНАЛ (не переключено)"
		fi
	fi
	if [ -n "$server_url" ] && hu=$(health_url "$server_url"); then
		if wget -q -T 5 -O /dev/null "$hu" 2>/dev/null; then
			say "сервер:        $hu отвечает"
		else
			say "сервер:        $hu НЕ отвечает"
		fi
	fi
	return "$verdict"
}

cmd_apply() {
	force=''
	case "${1:-}" in
	'') ;;
	--force) force=1 ;;
	*) die "неизвестный аргумент apply: $1" ;;
	esac
	load_conf
	require_server_url
	lock
	resolve_cfg
	read_endpoint "$cfg"
	target_url=P:$server_url
	if [ -e "$backup" ]; then
		load_backup
		if [ "$cur_url" = "$b_applied" ] && [ "$cur_quic" = "$(applied_quic "$b_quic")" ]; then
			if [ "$b_applied" = "$target_url" ]; then
				die "уже переключено на $server_url (бэкап: $backup); повторный apply не нужен"
			fi
			die "колонка переключена на $(show "$b_applied"), а в конфиге $server_url: сначала rollback, потом apply"
		fi
		if [ "$cur_url" != "$b_url" ] || [ "$cur_quic" != "$b_quic" ]; then
			die "endpoint изменён извне: сейчас uniProxyUrl=$(show "$cur_url") uniProxyQuicUrl=$(show "$cur_quic"), в бэкапе $(show "$b_url") / $(show "$b_quic"); проверьте $cfg и $backup вручную"
		fi
		[ "$b_applied" = "$target_url" ] || die "бэкап $backup сделан для адреса $(show "$b_applied"), а в конфиге $server_url; проверьте и уберите бэкап вручную"
		log "cfg в исходном состоянии, бэкап уже есть — переиспользую $backup"
	else
		if [ "$cur_url" = "$target_url" ]; then
			die "uniProxyUrl уже $server_url, но бэкапа нет — исходный адрес неизвестен, apply не нужен"
		fi
	fi
	if [ -z "$force" ] && [ "$health_check" = 1 ] && hu=$(health_url "$server_url"); then
		wget -q -T 5 -O /dev/null "$hu" 2>/dev/null || die "сервер не отвечает на $hu (apply --force — без проверки)"
	fi
	[ -e "$backup" ] || {
		write_backup
		log "бэкап сохранён: $backup"
	}
	make_writable "$cfg"
	write_cfg "$target_url" "$(applied_quic "$cur_quic")"
	restore_ro
	log "apply: uniProxyUrl=$server_url, uniProxyQuicUrl=$(show "$cur_quic")"
	say "Готово. Чтобы колонка подхватила адрес, перезапустите quasar (/etc/init.d/S99quasar restart) или колонку."
}

cmd_rollback() {
	[ $# -eq 0 ] || die "rollback не принимает аргументов"
	ensure_state
	lock
	resolve_cfg
	[ -e "$backup" ] || die "нет бэкапа $backup — откатывать нечего"
	load_backup
	read_endpoint "$cfg"
	exp_quic=$(applied_quic "$b_quic")
	if [ "$cur_url" != "$b_applied" ] || [ "$cur_quic" != "$exp_quic" ]; then
		if [ "$cur_url" = "$b_url" ] && [ "$cur_quic" = "$b_quic" ]; then
			die "cfg уже в исходном состоянии (как в бэкапе); ничего не меняю, бэкап оставлен: $backup"
		fi
		die "endpoint не совпадает с ожидаемым: сейчас uniProxyUrl=$(show "$cur_url") uniProxyQuicUrl=$(show "$cur_quic"), ожидалось $(show "$b_applied") / $(show "$exp_quic"); проверьте $cfg и $backup вручную"
	fi
	make_writable "$cfg"
	write_cfg "$b_url" "$b_quic"
	restore_ro
	mv -f "$backup" "$backup.restored"
	sync
	log "rollback: uniProxyUrl=$(show "$b_url"), uniProxyQuicUrl=$(show "$b_quic"); бэкап перенесён в $backup.restored"
	say "Готово. Перезапустите quasar (/etc/init.d/S99quasar restart) или колонку."
}

cmd_set_url() {
	[ $# -eq 1 ] || die "usage: set-url ws://<сервер>:8443/uni.ws"
	valid_url "$1" || die "некорректный адрес: '$1' (ожидается ws://<сервер>:<порт>/uni.ws)"
	ensure_state
	lock
	t=$conf.tmp.$$
	if grep -q '^[[:space:]]*SERVER_URL=' "$conf"; then
		sed "s|^[[:space:]]*SERVER_URL=.*|SERVER_URL=$(sed_escape "$1")|" "$conf" >"$t"
	else
		{ cat "$conf"; say "SERVER_URL=$1"; } >"$t"
	fi
	chmod 0600 "$t"
	mv -f "$t" "$conf"
	log "SERVER_URL=$1 записан в $conf"
}

action=${1:-}
[ $# -eq 0 ] || shift
case "$action" in
check) cmd_check "$@" ;;
apply) cmd_apply "$@" ;;
rollback) cmd_rollback "$@" ;;
set-url) cmd_set_url "$@" ;;
help | -h | --help) usage ;;
*)
	usage >&2
	exit 2
	;;
esac
