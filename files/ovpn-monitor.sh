#!/bin/bash
# ovpn-monitor.sh — pencatat log OpenVPN untuk troubleshooting.
#
# SIFAT: hanya MENCATAT, tidak me-restart, tidak memperbaiki, tidak
# mengubah konfigurasi apa pun. Tujuannya satu: saat OpenVPN bermasalah
# lagi, penyebabnya bisa dibaca dari log tanpa harus pas kejadiannya.
#
# CARA PAKAI (dijalankan sendiri oleh pemilik VPS, setelah instalasi):
#   wget -q https://raw.githubusercontent.com/ajijainalganteng-wq/WendyVpn/main/files/ovpn-monitor.sh
#   chmod +x ovpn-monitor.sh
#   ./ovpn-monitor.sh install
#
# Setelah itu cron menjalankan script ini tiap 2 menit dan menulis ke
# /var/log/openvpn-monitor.log. AX / teknisi tinggal membaca file itu.
#
# Mode tanpa argumen: satu kali pemeriksaan + catat bila perlu.
# Mode "install": pasang script ke /usr/local/sbin + cron tiap 2 menit.
# Variabel uji (opsional): OVPN_MONITOR_LOG, OVPN_MONITOR_STATE.

LOG="${OVPN_MONITOR_LOG:-/var/log/openvpn-monitor.log}"
STATE="${OVPN_MONITOR_STATE:-/var/lib/ovpn-monitor.state}"
MAX_BYTES=5242880

log_line() {
    echo "$(date '+%Y-%m-%d %H:%M:%S %Z') $*" >> "$LOG"
}

rotate_log() {
    [ -f "$LOG" ] || return 0
    size=$(stat -c%s "$LOG" 2>/dev/null || echo 0)
    if [ "$size" -gt "$MAX_BYTES" ]; then
        tmp="$LOG.tmp"
        tail -n 2000 "$LOG" > "$tmp" 2>/dev/null && mv "$tmp" "$LOG"
    fi
}

# --- Mode install: hanya menyalin diri sendiri + cron, tanpa ubah service ---
if [ "${1:-}" = "install" ]; then
    if [ "$(id -u)" -ne 0 ]; then
        echo "install harus dijalankan sebagai root." >&2
        exit 1
    fi
    cp "$0" /usr/local/sbin/ovpn-monitor.sh
    chmod +x /usr/local/sbin/ovpn-monitor.sh
    mkdir -p /var/lib
    touch "$LOG"
    (crontab -l 2>/dev/null | grep -v 'ovpn-monitor.sh'; echo '*/2 * * * * /usr/local/sbin/ovpn-monitor.sh') | crontab -
    echo "ovpn-monitor terpasang. Log: $LOG (cron tiap 2 menit)."
    exit 0
fi

mkdir -p "$(dirname "$LOG")" 2>/dev/null || true
mkdir -p "$(dirname "$STATE")" 2>/dev/null || true
rotate_log

# --- Kumpulkan status ---
UNITS=""
if command -v systemctl >/dev/null 2>&1; then
    UNITS=$(systemctl list-units --all --no-legend 2>/dev/null | grep -E 'openvpn' | awk '{print $1" "$3" "$4}' || true)
fi
if [ -z "$UNITS" ]; then
    UNITS="(tidak ada unit openvpn yang ditemukan / systemctl tidak tersedia)"
fi

RESTARTS=""
if command -v systemctl >/dev/null 2>&1; then
    for u in $(echo "$UNITS" | awk '{print $1}' | grep -E '^openvpn' || true); do
        n=$(systemctl show "$u" -p NRestarts 2>/dev/null | cut -d= -f2)
        RESTARTS="$RESTARTS $u:NRestarts=${n:-?}"
    done
fi
[ -z "$RESTARTS" ] && RESTARTS="(restart count tidak tersedia)"

PORTS=""
if command -v ss >/dev/null 2>&1; then
    PORTS=$(ss -tln 2>/dev/null | awk '{print $4}' | grep -E ':(1194|2200)$' | tr '\n' ' ' || true)
fi
[ -z "$PORTS" ] && PORTS="(port 1194/2200 tidak ada yang mendengarkan / ss tidak tersedia)"

SUMMARY="UNITS[${UNITS} ] RESTARTS[${RESTARTS} ] PORTS[${PORTS} ]"
SIG=$(printf '%s' "$SUMMARY" | cksum 2>/dev/null | awk '{print $1}')
HOUR=$(date +%Y%m%d%H)

LAST_SIG=""
LAST_HOUR=""
if [ -f "$STATE" ]; then
    LAST_SIG=$(grep '^SIG=' "$STATE" 2>/dev/null | cut -d= -f2)
    LAST_HOUR=$(grep '^HOUR=' "$STATE" 2>/dev/null | cut -d= -f2)
fi

BAD=0
case "$SUMMARY" in
    *" failed "*|*" inactive "*|*" dead "*|*"tidak ada unit openvpn"*)
        BAD=1
        ;;
esac

if [ "$BAD" -eq 1 ] || [ "$SIG" != "$LAST_SIG" ]; then
    # Keadaan berubah atau buruk: catat detail + ekor journal.
    log_line "STATUS-BERUBAH/GAGAL $SUMMARY"
    if command -v journalctl >/dev/null 2>&1; then
        for u in $(echo "$UNITS" | awk '{print $1}' | grep -E '^openvpn' | head -4 || true); do
            log_line "--- journal $u (20 baris terakhir, 15 menit terakhir) ---"
            journalctl -u "$u" --since "15 minutes ago" --no-pager 2>/dev/null | tail -n 20 >> "$LOG" || true
        done
    fi
elif [ "$HOUR" != "$LAST_HOUR" ]; then
    # Normal dan tidak berubah: cukup satu baris heartbeat per jam.
    log_line "HEARTBEAT-NORMAL $SUMMARY"
fi

{
    echo "SIG=$SIG"
    echo "HOUR=$HOUR"
} > "$STATE"
exit 0
