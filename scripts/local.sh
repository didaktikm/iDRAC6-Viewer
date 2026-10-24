#!/usr/bin/env bash
# Local build + run helper (optional). For normal use pull the prebuilt image instead - see README.
# Builds the image from this checkout (picking the fastest Debian mirror) and starts it with docker compose.
#
#   ./scripts/local.sh                 # asks for host, ports, user and ISO folder (Enter = default)
#   ./scripts/local.sh ~/isos          # ISO folder as an argument (not asked)
#   ./scripts/local.sh -y              # no questions: everything from the environment / .env
#   ./scripts/local.sh --bench         # re-run the Debian mirror benchmark
#   ./scripts/local.sh --no-bench      # skip the benchmark (mirror.yandex.ru or DEB_MIRROR)
#
# Defaults come from environment variables, then from .env:
#   IDRAC_HOST IDRAC_HTTPS_PORT IDRAC_KVM_PORT IDRAC_USER ISO_DIR DEB_MIRROR IDRAC_PASSWORD
# The password is asked by the container itself (or taken from IDRAC_PASSWORD).
# Compatible with bash 3.2 (the stock bash on macOS).
set -euo pipefail
cd "$(dirname "$0")/.."

ASSUME_YES=0
BENCH=auto
ISO_ARG=""
DEFAULT_MIRROR="mirror.yandex.ru"
# deb.debian.org (Fastly) is deliberately excluded: some ISPs cut .deb downloads there ("unexpected EOF")
MIRROR_CANDIDATES="${MIRROR_CANDIDATES:-mirror.yandex.ru ftp.ru.debian.org ftp.de.debian.org ftp.nl.debian.org}"

usage() { sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

while [ $# -gt 0 ]; do
  case "$1" in
    -y|--yes)    ASSUME_YES=1 ;;
    --bench)     BENCH=force ;;
    --no-bench)  BENCH=never ;;
    -h|--help)   usage ;;
    -*)          echo "Unknown option: $1"; exit 2 ;;
    *)           ISO_ARG="$1" ;;
  esac
  shift
done

# --- .env: values never override what is already set in the environment ---
load_env() {
  [ -f .env ] || return 0
  local line k v
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    case "$line" in ''|\#*) continue ;; esac
    case "$line" in *=*) ;; *) continue ;; esac
    k="${line%%=*}"; v="${line#*=}"
    case "$k" in ''|*[!A-Za-z0-9_]*) continue ;; esac
    v="${v%\"}"; v="${v#\"}"; v="${v%\'}"; v="${v#\'}"
    v="${v/#\~/$HOME}"
    if [ -z "${!k+x}" ]; then export "$k=$v"; fi
  done < .env
}
load_env

# ask VAR "Question" "default"
ask() {
  local var="$1" prompt="$2" def="${3:-}" ans=""
  if [ "$ASSUME_YES" = 1 ] || [ ! -t 0 ]; then
    ans=""
  else
    read -erp "${prompt}${def:+ [$def]}: " ans || ans=""
  fi
  export "$var=${ans:-$def}"
}

# --- connection ---
ask IDRAC_HOST "iDRAC host" "${IDRAC_HOST:-}"
[ -n "${IDRAC_HOST}" ] || { echo "No host: set IDRAC_HOST in .env or enter it when asked."; exit 1; }
ask IDRAC_HTTPS_PORT "iDRAC web (HTTPS) port" "${IDRAC_HTTPS_PORT:-443}"
ask IDRAC_KVM_PORT   "iDRAC KVM port"         "${IDRAC_KVM_PORT:-5900}"
ask IDRAC_USER       "iDRAC user"             "${IDRAC_USER:-root}"

# --- ISO folder ---
if [ -n "$ISO_ARG" ]; then
  iso="$ISO_ARG"
else
  ask ISO_DIR "Folder with ISO images" "${ISO_DIR:-./iso}"
  iso="$ISO_DIR"
fi
iso="${iso/#\~/$HOME}"
mkdir -p "$iso"
iso="$(cd "$iso" && pwd)"
export ISO_DIR="$iso"

echo "ISO folder: $iso (mounted at /iso, read-only)"
shopt -s nullglob nocaseglob
isos=("$iso"/*.iso "$iso"/*.img)
shopt -u nullglob nocaseglob
if [ ${#isos[@]} -eq 0 ]; then
  echo "WARNING: no .iso/.img files in that folder."
else
  printf '  - %s\n' "${isos[@]##*/}"
fi

# --- Debian mirror for the image build ---
# Measures the download speed of a real package index; mirrors that fail or lack debian-security are skipped.
bench_mirrors() {
  local h url out rc code size speed sec best="" best_speed=0 line
  echo "Benchmarking Debian mirrors (up to 8 s each)..." >&2
  for h in $MIRROR_CANDIDATES; do
    url="http://$h/debian/dists/bookworm/main/binary-amd64/Packages.xz"
    rc=0
    out="$(curl -sSL -o /dev/null --connect-timeout 4 --max-time 8 \
           -w '%{http_code} %{size_download} %{speed_download}' "$url" 2>/dev/null)" || rc=$?
    # shellcheck disable=SC2086
    set -- $out
    code="${1:-0}"; size="${2:-0}"; speed="${3:-0}"
    sec="$(curl -sS -o /dev/null --connect-timeout 4 --max-time 8 -w '%{http_code}' \
           "http://$h/debian-security/dists/bookworm-security/InRelease" 2>/dev/null)" || sec=000
    if [ "$sec" != 200 ]; then
      printf '  %-22s skipped: no debian-security (http=%s)\n' "$h" "$sec" >&2
      continue
    fi
    # rc 0 = downloaded completely; rc 28 = did not finish in 8 s (slow but alive); anything else = failure
    if [ "$code" = 200 ] && { [ "$rc" = 0 ] || [ "$rc" = 28 ]; } && [ "${size%.*}" -gt 500000 ]; then
      line="$(awk -v s="$speed" 'BEGIN{printf "%.1f MB/s", s/1048576}')"
      printf '  %-22s %s\n' "$h" "$line" >&2
      if awk -v a="$speed" -v b="$best_speed" 'BEGIN{exit !(a>b)}'; then best="$h"; best_speed="$speed"; fi
    else
      printf '  %-22s unavailable (http=%s, curl=%s)\n' "$h" "$code" "$rc" >&2
    fi
  done
  echo "$best"
}

choose_mirror() {
  local fresh=""
  if [ -n "${DEB_MIRROR:-}" ]; then
    echo "Debian mirror: $DEB_MIRROR (from environment/.env)"; return
  fi
  if [ "$BENCH" != force ] && [ -s .mirror ] && [ "$(cat .mirror)" != deb.debian.org ]; then
    DEB_MIRROR="$(cat .mirror)"; export DEB_MIRROR
    echo "Debian mirror: $DEB_MIRROR (remembered; use --bench to re-run the benchmark)"; return
  fi
  if [ "$BENCH" = never ]; then
    export DEB_MIRROR="$DEFAULT_MIRROR"; echo "Debian mirror: $DEB_MIRROR"; return
  fi
  fresh="$(bench_mirrors)"
  fresh="${fresh:-$DEFAULT_MIRROR}"
  ask DEB_MIRROR "Debian mirror" "$fresh"
  printf '%s\n' "$DEB_MIRROR" > .mirror
}
choose_mirror

docker compose build
exec docker compose run --rm --service-ports idrac
