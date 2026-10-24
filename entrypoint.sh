#!/usr/bin/env bash
# idrac6-viewer entrypoint: Xvfb + openbox + x11vnc + noVNC, then the Avocent KVM client from the iDRAC itself.
#
# The client jars and native libraries are downloaded from YOUR iDRAC at start-up (exactly what the
# JNLP does), so the client/library versions always match the firmware and nothing proprietary is
# redistributed in this image.
set -euo pipefail

VERSION="${IDRAC6_KVM_VERSION:-dev}"

usage() {
  cat <<EOF
idrac6-viewer ${VERSION} - Dell iDRAC6 Virtual Console + Virtual Media in a container

Usage: docker run --rm -it --platform linux/amd64 -p 127.0.0.1:6080:6080 -v ~/isos:/iso:ro \\
         IMAGE [options]

Options (each also available as an environment variable; flags win over env):
  --host HOST            iDRAC address                 IDRAC_HOST        (prompted if empty and a TTY is attached)
  --https-port PORT      iDRAC web port                IDRAC_HTTPS_PORT  (default 443)
  --kvm-port PORT        iDRAC KVM/Virtual Media port  IDRAC_KVM_PORT    (default 5900)
  --user USER            iDRAC user                    IDRAC_USER        (default root)
  --password PASS        iDRAC password                IDRAC_PASSWORD    (visible in 'docker inspect'; prefer the prompt or a file)
  --password-file FILE   read the password from FILE   IDRAC_PASSWORD_FILE
  --resolution WxHxD     virtual screen                RESOLUTION        (default 1280x800x24)
  --selftest             check that all tools are present, then exit
  --version              print version and exit
  -h, --help             this help

Then open http://localhost:6080/vnc.html?autoconnect=1&resize=scale
Mount a folder with ISO images at /iso (read-only) and pick a file in Virtual Media -> Map CD/DVD.
EOF
}

log() { printf '[idrac6-viewer] %s\n' "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

IDRAC_HOST="${IDRAC_HOST:-}"
IDRAC_USER="${IDRAC_USER:-root}"
IDRAC_HTTPS_PORT="${IDRAC_HTTPS_PORT:-443}"
IDRAC_KVM_PORT="${IDRAC_KVM_PORT:-5900}"
IDRAC_PASSWORD="${IDRAC_PASSWORD:-}"
IDRAC_PASSWORD_FILE="${IDRAC_PASSWORD_FILE:-}"
RESOLUTION="${RESOLUTION:-1280x800x24}"
JAVA_OPTS="${JAVA_OPTS:--Xmx256m}"
SELFTEST=0

need_value() { [ "$#" -ge 2 ] && [ -n "$2" ] || { log "Option $1 needs a value"; exit 2; }; }

while [ $# -gt 0 ]; do
  case "$1" in
    --host)            need_value "$@"; IDRAC_HOST="$2"; shift 2 ;;
    --host=*)          IDRAC_HOST="${1#*=}"; shift ;;
    --https-port)      need_value "$@"; IDRAC_HTTPS_PORT="$2"; shift 2 ;;
    --https-port=*)    IDRAC_HTTPS_PORT="${1#*=}"; shift ;;
    --kvm-port)        need_value "$@"; IDRAC_KVM_PORT="$2"; shift 2 ;;
    --kvm-port=*)      IDRAC_KVM_PORT="${1#*=}"; shift ;;
    --user)            need_value "$@"; IDRAC_USER="$2"; shift 2 ;;
    --user=*)          IDRAC_USER="${1#*=}"; shift ;;
    --password)        need_value "$@"; IDRAC_PASSWORD="$2"; shift 2 ;;
    --password=*)      IDRAC_PASSWORD="${1#*=}"; shift ;;
    --password-file)   need_value "$@"; IDRAC_PASSWORD_FILE="$2"; shift 2 ;;
    --password-file=*) IDRAC_PASSWORD_FILE="${1#*=}"; shift ;;
    --resolution)      need_value "$@"; RESOLUTION="$2"; shift 2 ;;
    --resolution=*)    RESOLUTION="${1#*=}"; shift ;;
    --selftest)        SELFTEST=1; shift ;;
    --version)         echo "idrac6-viewer ${VERSION}"; exit 0 ;;
    -h|--help)         usage; exit 0 ;;
    *)                 log "Unknown option: $1 (see --help)"; exit 2 ;;
  esac
done

if [ "$SELFTEST" = 1 ]; then
  fail=0
  for b in java Xvfb openbox x11vnc websockify curl unzip; do
    if command -v "$b" >/dev/null 2>&1; then echo "ok       $b"; else echo "MISSING  $b"; fail=1; fi
  done
  if [ -d /usr/share/novnc ]; then echo "ok       novnc"; else echo "MISSING  novnc"; fail=1; fi
  java -version 2>&1 || fail=1
  exit "$fail"
fi

WORK=/work
NATIVE="$WORK/native"
BASE="https://${IDRAC_HOST}:${IDRAC_HTTPS_PORT}/software"

# --- interactive input only where a TTY is attached ---
if [ -z "$IDRAC_HOST" ]; then
  [ -t 0 ] || die "IDRAC_HOST is not set (use -e IDRAC_HOST=... or --host ...)"
  read -rp "iDRAC host: " IDRAC_HOST
  [ -n "$IDRAC_HOST" ] || die "No host given"
  BASE="https://${IDRAC_HOST}:${IDRAC_HTTPS_PORT}/software"
fi

if [ -z "$IDRAC_PASSWORD" ] && [ -n "$IDRAC_PASSWORD_FILE" ]; then
  [ -r "$IDRAC_PASSWORD_FILE" ] || die "Cannot read password file: $IDRAC_PASSWORD_FILE"
  IDRAC_PASSWORD="$(head -n1 "$IDRAC_PASSWORD_FILE")"
fi
if [ -z "$IDRAC_PASSWORD" ]; then
  [ -t 0 ] || die "No password: use -it for a prompt, or IDRAC_PASSWORD / --password-file"
  read -rsp "iDRAC password (${IDRAC_USER}@${IDRAC_HOST}): " IDRAC_PASSWORD
  echo
fi

# --- reachability check before starting anything ---
check_port() {
  if ! timeout 5 bash -c "exec 3<>/dev/tcp/${IDRAC_HOST}/$1" 2>/dev/null; then
    log "Port ${IDRAC_HOST}:$1 is unreachable (check port forwarding / VPN / firewall)."
    return 1
  fi
}
check_port "$IDRAC_HTTPS_PORT" || exit 1
check_port "$IDRAC_KVM_PORT" || exit 1

# --- client + native libraries straight from the iDRAC ---
# iDRAC6 speaks only legacy TLS with a short DH key, which OpenSSL 3 rejects ("dh key too small").
# Security level is lowered for these curl calls only.
CURL_LEGACY=(--tlsv1.0 --ciphers 'ALL:@SECLEVEL=0')
mkdir -p "$WORK" "$NATIVE"
cd "$WORK"
for f in avctKVM.jar avctKVMIOLinux64.jar avctVMLinux64.jar; do
  log "Downloading $f"
  curl -fsSk "${CURL_LEGACY[@]}" --retry 2 -o "$f" "${BASE}/${f}" \
    || die "Could not download ${BASE}/${f}"
done
# the native .so files are inside the jars (plain zip archives)
for f in avctKVMIOLinux64.jar avctVMLinux64.jar; do
  unzip -o -q "$f" -d "$NATIVE"
done
rm -rf "$NATIVE/META-INF"
log "Native libraries:"
find "$NATIVE" -maxdepth 1 -type f | sort | sed 's/^/  /' >&2
if ! find "$NATIVE" -maxdepth 1 -name '*.so' | grep -q .; then
  log "WARNING: no .so files in the jars. Please open an issue with the output of 'unzip -l' for both jars."
fi

# --- display stack ---
Xvfb "$DISPLAY" -screen 0 "$RESOLUTION" -nolisten tcp >/dev/null 2>&1 &
for _ in $(seq 1 50); do
  [ -S "/tmp/.X11-unix/X${DISPLAY#:}" ] && break
  sleep 0.2
done
openbox >/dev/null 2>&1 &
x11vnc -display "$DISPLAY" -forever -shared -nopw -localhost -rfbport 5901 -quiet >/dev/null 2>&1 &
websockify --web /usr/share/novnc 6080 localhost:5901 >/dev/null 2>&1 &

cleanup() { jobs -p | xargs -r kill 2>/dev/null || true; }
trap cleanup EXIT INT TERM

log "Open in your browser: http://localhost:6080/vnc.html?autoconnect=1&resize=scale"
log "Virtual Media -> Map CD/DVD: images are in /iso"

JRE_LIB="$JAVA_HOME/jre/lib/amd64"
export LD_LIBRARY_PATH="$NATIVE:$JRE_LIB:$JRE_LIB/xawt:${LD_LIBRARY_PATH:-}"

# user.home=/iso makes the Map CD/DVD file dialog open in the images folder
# shellcheck disable=SC2086
java $JAVA_OPTS \
  -Djava.security.properties=/opt/idrac/idrac.java.security \
  -Djava.library.path="$NATIVE" \
  -Duser.home=/iso \
  -cp "avctKVM.jar:avctKVMIOLinux64.jar:avctVMLinux64.jar" \
  com.avocent.idrac.kvm.Main \
  "ip=${IDRAC_HOST}" "kmport=${IDRAC_KVM_PORT}" "vport=${IDRAC_KVM_PORT}" \
  "user=${IDRAC_USER}" "passwd=${IDRAC_PASSWORD}" \
  apcp=1 version=2 vmprivilege=true \
  "helpurl=https://${IDRAC_HOST}:${IDRAC_HTTPS_PORT}/help/contents.html" \
  || log "Java exited with code $?"
