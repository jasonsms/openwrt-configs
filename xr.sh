#!/bin/sh
# xray-mini: single-file Xray VLESS+Reality installer for Alpine/OpenRC.
# Tuned for 64MB cgroup VPS: no extra deps, downloads go to /var/tmp (disk),
# not /tmp (tmpfs counted into the cgroup limit).
set -eu

BIN=/usr/local/bin/xray
DIR=/usr/local/etc/xray
CONF=$DIR/config.json
META=$DIR/meta.env
SVC=/etc/init.d/xray
LOGF=/var/log/xray.log
MEMLIMIT=${MEMLIMIT:-24MiB}

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
info() { printf '%s\n' "$*"; }

usage() {
	cat <<'EOF'
xray-mini - minimal Xray VLESS+Reality for Alpine/OpenRC (64MB friendly)

usage: xray-mini <command> [options]

commands:
  install     install, configure and start
  info        show status, memory and node link
  link        print share link and Clash node
  status      service status
  restart     restart service
  logs        tail service log
  uninstall   stop and remove everything

install options:
  --port N       listen port inside the container (default 8443)
  --ext-port N   public port mapped by the provider (default: same as --port)
  --host H       public IP/domain used in the link (default: auto-detect)
  --dest HOST    REALITY camouflage target (default: www.python.org)
  --force        overwrite an existing install
  --yes          skip uninstall confirmation

environment:
  MEMLIMIT       Go heap soft limit written to the service (default 24MiB)
  XRAY_VERSION   pin a release tag, e.g. v26.10.31 (default: latest)
  SELF_URL       raw URL of this script, used to keep the command when run via pipe
EOF
}

fetch() {
	if command -v curl >/dev/null 2>&1; then
		curl -fsSL --retry 3 --connect-timeout 10 -o "$2" "$1"
	elif command -v wget >/dev/null 2>&1; then
		wget -q -O "$2" "$1"
	else
		die "need curl or wget"
	fi
}

public_ip() {
	ip=
	if command -v curl >/dev/null 2>&1; then
		ip=$(curl -fsS --max-time 6 https://icanhazip.com 2>/dev/null || true)
	fi
	if [ -z "$ip" ] && command -v wget >/dev/null 2>&1; then
		ip=$(wget -qO- --timeout=6 https://icanhazip.com 2>/dev/null || true)
	fi
	printf '%s' "$ip" | tr -d ' \r\n'
}

cgroup_mb() {	v=
	if [ -r /sys/fs/cgroup/memory.max ]; then
		v=$(cat /sys/fs/cgroup/memory.max 2>/dev/null)
	fi
	case ${v:-} in
	'' | max | *[!0-9]*) v= ;;
	esac
	if [ -z "$v" ] && [ -r /sys/fs/cgroup/memory/memory.limit_in_bytes ]; then
		v=$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes 2>/dev/null)
		case ${v:-} in
		'' | *[!0-9]*) v= ;;
		esac
	fi
	if [ -z "$v" ]; then
		echo 0
	else
		echo $((v / 1048576))
	fi
}

install_self() {
	target=/usr/local/bin/xray-mini
	if [ "$0" = "$target" ]; then
		return 0
	fi
	mkdir -p /usr/local/bin
	if [ -f "$0" ] && [ -r "$0" ] && sed -n '1p' "$0" 2>/dev/null | grep -q '^#!/bin/sh'; then
		cp "$0" "$target.tmp" 2>/dev/null || return 0
	elif [ -n "${SELF_URL:-}" ]; then
		fetch "$SELF_URL" "$target.tmp" || return 0
	else
		return 0
	fi
	chmod 0755 "$target.tmp"
	mv -f "$target.tmp" "$target"
	info "command installed: $target"
}

load_meta() {
	[ -f "$META" ] || die "not installed ($META missing)"
	. "$META"
}

print_link() {
	load_meta
	printf 'vless://%s@%s:%s?encryption=none&flow=xtls-rprx-vision&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp&headerType=none&support-x25519mlkem768=true#Xray-Reality\n' \
		"$UUID" "$HOST" "$EXT_PORT" "$DEST" "$PUB" "$SHORT"
	cat <<EOF

# Clash / mihomo node
- name: Xray-Reality
  type: vless
  server: $HOST
  port: $EXT_PORT
  uuid: $UUID
  network: tcp
  udp: true
  tls: true
  flow: xtls-rprx-vision
  servername: $DEST
  client-fingerprint: chrome
  reality-opts:
    public-key: $PUB
    short-id: $SHORT
    support-x25519mlkem768: true
EOF
}

print_info() {
	load_meta
	pid=$(pidof xray 2>/dev/null | awk '{print $1}')
	rss=n/a
	if [ -n "$pid" ]; then
		rss=$(awk '/^VmRSS:/{print $2" "$3}' "/proc/$pid/status" 2>/dev/null || true)
	fi
	cur=$(cat /sys/fs/cgroup/memory.current 2>/dev/null || echo '?')
	max=$(cat /sys/fs/cgroup/memory.max 2>/dev/null || echo '?')
	info "service : $(rc-service xray status 2>&1 | head -n1)"
	info "listen  : 0.0.0.0:$PORT (inside container)"
	info "public  : $HOST:$EXT_PORT"
	info "reality : dest=$DEST:443"
	info "memory  : xray=$rss  cgroup=$cur/$max"
	info ""
	print_link
}

do_install() {
	case $PORT in '' | *[!0-9]*) die "--port must be a number" ;; esac
	[ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ] || die "--port out of range"
	if [ -z "$EXT_PORT" ]; then EXT_PORT=$PORT; fi
	case $EXT_PORT in '' | *[!0-9]*) die "--ext-port must be a number" ;; esac
	[ "$EXT_PORT" -ge 1 ] && [ "$EXT_PORT" -le 65535 ] || die "--ext-port out of range"
	case $DEST in '' | *[!A-Za-z0-9.-]*) die "--dest contains invalid characters" ;; esac

	if [ -f "$CONF" ] && [ "$FORCE" -ne 1 ]; then
		die "already installed; use --force to rebuild"
	fi

	if [ -z "$HOST" ]; then HOST=$(public_ip); fi
	[ -n "$HOST" ] || die "cannot detect public IP; pass --host"
	case $HOST in *[!A-Za-z0-9.:-]*) die "--host contains invalid characters" ;; esac

	command -v unzip >/dev/null 2>&1 || command -v busybox >/dev/null 2>&1 || die "need unzip"

	tmp=$(mktemp -d /var/tmp/xray-mini.XXXXXX) || die "mktemp failed"
	trap 'rm -rf "$tmp"' EXIT INT TERM HUP

	case $(uname -m) in
	x86_64 | amd64) asset=Xray-linux-64.zip ;;
	aarch64 | arm64) asset=Xray-linux-arm64-v8a.zip ;;
	armv7l | armv7) asset=Xray-linux-arm32-v7a.zip ;;
	*) die "unsupported arch: $(uname -m)" ;;
	esac

	url=https://github.com/XTLS/Xray-core/releases/latest/download/$asset
	if [ -n "${XRAY_VERSION:-}" ]; then
		url=https://github.com/XTLS/Xray-core/releases/download/$XRAY_VERSION/$asset
	fi

	info "downloading $asset ..."
	fetch "$url" "$tmp/x.zip" || die "download failed"

	mkdir -p /usr/local/bin
	unzip_cmd=unzip
	if ! command -v unzip >/dev/null 2>&1; then unzip_cmd="busybox unzip"; fi
	if ! $unzip_cmd -p "$tmp/x.zip" xray >"$BIN.tmp" 2>/dev/null || [ ! -s "$BIN.tmp" ]; then
		mkdir -p "$tmp/u"
		$unzip_cmd -q -o "$tmp/x.zip" -d "$tmp/u" || die "unzip failed"
		src=$(find "$tmp/u" -type f -name xray | head -n1)
		[ -n "$src" ] || die "xray binary not found in archive"
		mv -f "$src" "$BIN.tmp" 2>/dev/null || cp "$src" "$BIN.tmp"
	fi
	chmod 0755 "$BIN.tmp"
	mv -f "$BIN.tmp" "$BIN"

	UUID=$("$BIN" uuid) || die "xray uuid failed"
	keys=$("$BIN" x25519 2>/dev/null) || die "xray x25519 failed"
	PRIV=$(printf '%s\n' "$keys" | sed -n '/[Pp]rivate[[:space:]]*[Kk]ey/ s/.*:[[:space:]]*//p' | head -n1)
	PUB=$(printf '%s\n' "$keys" | sed -n '/[Pp]ublic[[:space:]]*[Kk]ey/ s/.*:[[:space:]]*//p; /[Pp]assword/ s/.*:[[:space:]]*//p' | head -n1)
	if [ -z "$PRIV" ] || [ -z "$PUB" ]; then
		printf '%s\n' "$keys" >&2
		die "cannot parse x25519 output"
	fi
	SHORT=$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')
	[ "${#SHORT}" -eq 8 ] || die "short id generation failed"

	mkdir -p "$DIR"
	cat >"$CONF" <<EOF
{
  "log": { "loglevel": "warning", "access": "none" },
  "inbounds": [
    {
      "tag": "vless-in",
      "listen": "0.0.0.0",
      "port": $PORT,
      "protocol": "vless",
      "settings": {
        "clients": [{ "id": "$UUID", "flow": "xtls-rprx-vision" }],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "$DEST:443",
          "xver": 0,
          "serverNames": ["$DEST"],
          "privateKey": "$PRIV",
          "shortIds": ["$SHORT"]
        }
      }
    }
  ],
  "outbounds": [{ "tag": "direct", "protocol": "freedom" }]
}
EOF
	chmod 600 "$CONF"

	if ! "$BIN" run -test -c "$CONF" >"$tmp/t.log" 2>&1; then
		if ! "$BIN" -test -c "$CONF" >>"$tmp/t.log" 2>&1; then
			cat "$tmp/t.log" >&2
			die "config test failed"
		fi
	fi

	{
		echo "PORT=$PORT"
		echo "EXT_PORT=$EXT_PORT"
		echo "HOST=$HOST"
		echo "DEST=$DEST"
		echo "UUID=$UUID"
		echo "PUB=$PUB"
		echo "SHORT=$SHORT"
	} >"$META"
	chmod 600 "$META"

	cat >"$SVC" <<EOF
#!/sbin/openrc-run
description="Xray VLESS Reality"

command="$BIN"
command_args="run -c $CONF"
pidfile="/run/xray.pid"

supervisor="supervise-daemon"
respawn_delay=5
respawn_max=0

export GOMEMLIMIT="$MEMLIMIT"
export GOGC="20"
export GOMAXPROCS="1"

output_log="$LOGF"
error_log="$LOGF"

start_pre() {
	mkdir -p /run
	: >> "$LOGF"
}
EOF
	chmod 0755 "$SVC"

	: >"$LOGF"
	rc-update add xray default >/dev/null 2>&1 || true
	if ! rc-service xray restart >/dev/null 2>&1; then
		rc-service xray start >/dev/null 2>&1 || true
	fi
	sleep 1
	pid=$(pidof xray 2>/dev/null | awk '{print $1}')
	if [ -z "$pid" ]; then
		tail -n 20 "$LOGF" >&2 2>/dev/null || true
		die "xray did not start"
	fi

	install_self

	limit=$(cgroup_mb)
	if [ "$limit" -gt 0 ] && [ "$limit" -lt 96 ]; then
		info "NOTE: cgroup limit is ${limit}MB; GOMEMLIMIT=$MEMLIMIT, GOGC=20"
	fi
	if ! awk 'NR>1{found=1} END{exit !found}' /proc/swaps 2>/dev/null; then
		info "NOTE: no swap detected; consider asking the provider for zram/swap"
	fi
	if [ "$EXT_PORT_SET" -ne 1 ] && { [ -f /.dockerenv ] || [ -f /run/.containerenv ]; }; then
		info "NOTE: NAT/container detected and --ext-port not set."
		info "      the provider must map an external port to $PORT,"
		info "      otherwise the node is unreachable from outside."
	fi
	info ""
	print_info
}

do_status() {
	rc-service xray status 2>&1 || true
	pid=$(pidof xray 2>/dev/null | awk '{print $1}')
	if [ -n "$pid" ]; then
		awk '/^VmRSS:/{print "RSS: "$2" "$3}' "/proc/$pid/status" 2>/dev/null || true
	fi
}

do_uninstall() {
	if [ "$YES" -ne 1 ]; then
		printf 'remove xray, config and service? [y/N] '
		read -r ans || ans=
		case $ans in
		y | Y) ;;
		*) info "cancelled"; return ;;
		esac
	fi
	rc-service xray stop >/dev/null 2>&1 || true
	rc-update del xray default >/dev/null 2>&1 || true
	rm -f "$SVC" "$BIN" "$LOGF"
	rm -rf "$DIR"
	info "removed"
}

cmd=${1:-help}
if [ $# -gt 0 ]; then shift; fi
PORT=8443
EXT_PORT=
EXT_PORT_SET=0
HOST=
DEST=www.python.org
FORCE=0
YES=0

while [ $# -gt 0 ]; do
	case $1 in
	--port)
		PORT=${2:?missing value for --port}
		shift 2
		;;
	--ext-port)
		EXT_PORT=${2:?missing value for --ext-port}
		EXT_PORT_SET=1
		shift 2
		;;
	--host)
		HOST=${2:?missing value for --host}
		shift 2
		;;
	--dest)
		DEST=${2:?missing value for --dest}
		shift 2
		;;
	--force)
		FORCE=1
		shift
		;;
	--yes | -y)
		YES=1
		shift
		;;
	-h | --help)
		usage
		exit 0
		;;
	*) die "unknown option: $1" ;;
	esac
done

case $cmd in
install) do_install ;;
info) print_info ;;
link) print_link ;;
status) do_status ;;
restart) rc-service xray restart ;;
logs) tail -n 50 "$LOGF" ;;
uninstall) do_uninstall ;;
help | -h | --help) usage ;;
*)
	usage
	exit 1
	;;
esac
