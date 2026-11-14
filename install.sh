#!/usr/bin/env bash
# ==============================================================
#  WireGuard Manager  (Debian / Ubuntu, jalankan sebagai root)
#  Repo   : github.com/X14OC14/wireguard
#  Pakai  : bash <(curl -fsSL <link install.sh>)
#  Setelah terpasang, buka menu kapan saja dengan:  wgmenu
# ==============================================================
set -uo pipefail

VERSION="2.0"
BASE=/etc/wireguard
CLIENTS=$BASE/clients
PARAMS=$BASE/params
SELF_BIN=/usr/local/bin/wgmenu
SCRIPT_URL="https://raw.githubusercontent.com/X14OC14/wireguard/main/install.sh"

R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; C=$'\e[36m'; W=$'\e[1m'; N=$'\e[0m'

ENDPOINT=""; PORT=""; SUBNET=""; DNS="1.1.1.1"; NIC=""; MTU=""; IPV6BLOCK="n"
STATE="none"      # none | manual | managed
CHOSEN=""; RENAMED=""
NAMES=()

info() { echo "${C}[i]${N} $*"; }
ok()   { echo "${G}[✓]${N} $*"; }
warn() { echo "${Y}[!]${N} $*"; }
err()  { echo "${R}[✗]${N} $*" >&2; }
pause() { echo; read -rp "Tekan Enter untuk lanjut..." _ || exit 0; }

# ask VAR "Pertanyaan" "default"
ask() {
  local __v=$1 __p=$2 __d=${3:-} __in
  if [ -n "$__d" ]; then
    read -rp "$__p [$__d]: " __in || exit 0
    __in=${__in:-$__d}
  else
    read -rp "$__p: " __in || exit 0
  fi
  printf -v "$__v" '%s' "$__in"
}

# confirm "Pertanyaan" y|n   (default)
confirm() {
  local d=${2:-y} a hint="Y/n"
  [ "$d" = n ] && hint="y/N"
  read -rp "$1 [$hint]: " a || exit 0
  a=${a:-$d}
  [[ $a =~ ^[Yy]$ ]]
}

banner() {
  [ -t 1 ] && clear
  echo "${W}${C}"
  echo "  ╔══════════════════════════════════════════╗"
  echo "  ║          WireGuard Manager v$VERSION         ║"
  echo "  ╚══════════════════════════════════════════╝"
  echo "${N}"
}

need_root() {
  [ "$(id -u)" -eq 0 ] || { err "Jalankan sebagai root (sudo su / sudo bash $0)."; exit 1; }
}

# ---------- helper ----------
detect_ip() {
  local ip u
  for u in https://api.ipify.org https://ifconfig.me https://icanhazip.com; do
    ip=$(curl -4 -fsS --max-time 5 "$u" 2>/dev/null | tr -d '[:space:]')
    if [[ $ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then echo "$ip"; return; fi
  done
}

detect_nic() {
  ip -4 route show default 2>/dev/null | awk '{for(i=1;i<NF;i++) if($i=="dev"){print $(i+1); exit}}'
}

hum() {
  if command -v numfmt >/dev/null 2>&1; then numfmt --to=iec --suffix=B "${1:-0}"; else echo "${1:-0}B"; fi
}

ago() {
  local t=${1:-0} d
  [ "$t" -eq 0 ] && { echo "belum pernah"; return; }
  d=$(( $(date +%s) - t ))
  if   [ $d -lt 60 ];    then echo "$d dtk lalu"
  elif [ $d -lt 3600 ];  then echo "$((d/60)) mnt lalu"
  elif [ $d -lt 86400 ]; then echo "$((d/3600)) jam lalu"
  else echo "$((d/86400)) hari lalu"; fi
}

is_up() { ip link show wg0 >/dev/null 2>&1; }

ufw_active() { command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; }

save_params() {
  ( umask 077
    cat > "$PARAMS" <<EOF
ENDPOINT="$ENDPOINT"
PORT="$PORT"
SUBNET="$SUBNET"
DNS="$DNS"
NIC="$NIC"
MTU="$MTU"
IPV6BLOCK="$IPV6BLOCK"
EOF
  )
}

refresh_state() {
  if [ -f "$PARAMS" ] && [ -f "$BASE/server_private.key" ]; then
    STATE=managed
    # shellcheck disable=SC1090
    source "$PARAMS"
  elif [ -f "$BASE/wg0.conf" ]; then
    STATE=manual
  else
    STATE=none
  fi
}

require_managed() {
  [ "$STATE" = managed ] && return 0
  if [ "$STATE" = manual ]; then
    warn "Ada setup WireGuard manual. Pilih menu 2 (Impor setup yang sudah ada) dulu."
  else
    warn "WireGuard belum terpasang. Pilih menu 1 (Install) dulu."
  fi
  return 1
}

client_count() {
  local c=0 d
  for d in "$CLIENTS"/*/; do [ -f "${d}ip" ] && c=$((c+1)); done
  echo "$c"
}

load_names() {
  local d
  NAMES=()
  for d in "$CLIENTS"/*/; do
    [ -f "${d}ip" ] && NAMES+=("$(basename "$d")")
  done
  return 0
}

# ---------- server config (dibangun dari folder clients/) ----------
rebuild_server_conf() {
  local d n
  ( umask 077
    {
      echo "[Interface]"
      echo "Address = ${SUBNET}.1/24"
      echo "ListenPort = $PORT"
      echo "PrivateKey = $(cat "$BASE/server_private.key")"
      echo "PostUp = iptables -I FORWARD 1 -i wg0 -j ACCEPT; iptables -I FORWARD 1 -o wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -s ${SUBNET}.0/24 -o $NIC -j MASQUERADE"
      echo "PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -D FORWARD -o wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -s ${SUBNET}.0/24 -o $NIC -j MASQUERADE"
      for d in "$CLIENTS"/*/; do
        [ -f "${d}ip" ] || continue
        [ -f "${d}disabled" ] && continue
        n=$(basename "$d")
        echo
        echo "[Peer]"
        echo "# $n"
        echo "PublicKey = $(cat "${d}public.key")"
        [ -f "${d}psk.key" ] && echo "PresharedKey = $(cat "${d}psk.key")"
        echo "AllowedIPs = $(cat "${d}ip")/32"
      done
    } > "$BASE/wg0.conf"
  )
}

apply_conf() {
  rebuild_server_conf
  if is_up; then
    wg syncconf wg0 <(wg-quick strip wg0)
  else
    systemctl start wg-quick@wg0
  fi
}

# ---------- client ----------
next_ip() {
  local i f used
  for i in $(seq 2 254); do
    used=0
    for f in "$CLIENTS"/*/ip; do
      if [ -f "$f" ] && [ "$(cat "$f")" = "${SUBNET}.$i" ]; then used=1; break; fi
    done
    if [ $used -eq 0 ]; then echo "${SUBNET}.$i"; return 0; fi
  done
  return 1
}

write_client_conf() {
  local n=$1 d="$CLIENTS/$1" allowed="0.0.0.0/0"
  [ "$IPV6BLOCK" = y ] && allowed="0.0.0.0/0, ::/0"
  ( umask 077
    {
      echo "[Interface]"
      echo "PrivateKey = $(cat "$d/private.key")"
      echo "Address = $(cat "$d/ip")/24"
      echo "DNS = $DNS"
      [ -n "$MTU" ] && echo "MTU = $MTU"
      echo
      echo "[Peer]"
      echo "PublicKey = $(cat "$BASE/server_public.key")"
      [ -f "$d/psk.key" ] && echo "PresharedKey = $(cat "$d/psk.key")"
      echo "Endpoint = $ENDPOINT:$PORT"
      echo "AllowedIPs = $allowed"
      echo "PersistentKeepalive = 25"
    } > "$d/$n.conf"
  )
}

regen_all() {
  local d n
  for d in "$CLIENTS"/*/; do
    [ -f "${d}private.key" ] || continue
    n=$(basename "$d"); write_client_conf "$n"
  done
}

show_qr() {
  local n=$1
  if [ ! -f "$CLIENTS/$n/$n.conf" ]; then
    err "Config client '$n' tidak tersedia (user diimpor tanpa private key)."
    info "Pakai 'Buat ulang key' di menu user untuk membuat config baru."
    return 1
  fi
  echo
  qrencode -t ansiutf8 < "$CLIENTS/$n/$n.conf"
  echo
  info "File config : $CLIENTS/$n/$n.conf"
  info "Nama tunnel : ketik '$n' saat scan QR (atau pakai nama file saat import)."
  warn "QR & config berisi private key. Jangan dibagikan ke publik / grup."
}

view_conf() {
  local n=$1
  if [ ! -f "$CLIENTS/$n/$n.conf" ]; then err "Config client '$n' tidak tersedia."; return 1; fi
  echo; echo "${W}--- $CLIENTS/$n/$n.conf ---${N}"
  cat "$CLIENTS/$n/$n.conf"
  echo "${W}-----------------------------------------${N}"
  warn "Berisi private key. Jangan dibagikan ke publik."
}

add_client() {
  local n=${1:-} cip
  if [ -z "$n" ]; then ask n "Nama user (huruf/angka/-/_ , maks 15 karakter)"; fi
  [[ $n =~ ^[A-Za-z0-9_-]{1,15}$ ]] || { err "Nama tidak valid."; return 1; }
  [ -d "$CLIENTS/$n" ] && { err "User '$n' sudah ada."; return 1; }
  cip=$(next_ip) || { err "Tidak ada IP kosong di subnet."; return 1; }
  ( umask 077
    mkdir -p "$CLIENTS/$n"
    wg genkey | tee "$CLIENTS/$n/private.key" | wg pubkey > "$CLIENTS/$n/public.key"
    wg genpsk > "$CLIENTS/$n/psk.key"
    echo "$cip" > "$CLIENTS/$n/ip"
  )
  write_client_conf "$n"
  apply_conf
  ok "User '$n' dibuat dengan IP $cip"
  show_qr "$n"
}

remove_client() {
  local n=$1
  confirm "Hapus user '$n' permanen?" n || return 1
  rm -rf "${CLIENTS:?}/$n"
  apply_conf
  ok "User '$n' dihapus."
  return 0
}

toggle_client() {
  local n=$1
  if [ -f "$CLIENTS/$n/disabled" ]; then
    rm -f "$CLIENTS/$n/disabled"; apply_conf; ok "User '$n' diaktifkan."
  else
    touch "$CLIENTS/$n/disabled"; apply_conf; ok "User '$n' dinonaktifkan (config tetap tersimpan)."
  fi
}

rename_client() {
  local old=$1 new
  ask new "Nama baru (maks 15 karakter)"
  [[ $new =~ ^[A-Za-z0-9_-]{1,15}$ ]] || { err "Nama tidak valid."; return 1; }
  [ -e "$CLIENTS/$new" ] && { err "Nama '$new' sudah dipakai."; return 1; }
  mv "$CLIENTS/$old" "$CLIENTS/$new"
  [ -f "$CLIENTS/$new/$old.conf" ] && mv "$CLIENTS/$new/$old.conf" "$CLIENTS/$new/$new.conf"
  apply_conf
  RENAMED=$new
  ok "Nama diganti: $old -> $new"
}

reset_client() {
  local n=$1
  confirm "Buat ulang key '$n'? Config lama di perangkat akan berhenti bekerja." n || return 1
  ( umask 077
    wg genkey | tee "$CLIENTS/$n/private.key" | wg pubkey > "$CLIENTS/$n/public.key"
    wg genpsk > "$CLIENTS/$n/psk.key"
  )
  write_client_conf "$n"
  apply_conf
  ok "Key '$n' dibuat ulang. Pasang config baru di perangkat:"
  show_qr "$n"
}

list_clients() {
  declare -A HS RX TX
  local k t r i=0 n d pk st
  if is_up; then
    while read -r k t; do HS[$k]=$t; done < <(wg show wg0 latest-handshakes)
    while read -r k r t; do RX[$k]=$r; TX[$k]=$t; done < <(wg show wg0 transfer)
  fi
  load_names
  if [ ${#NAMES[@]} -eq 0 ]; then warn "Belum ada user."; return 0; fi
  echo "${W}No  Nama             IP              Status     Handshake      Unduh / Unggah${N}"
  for n in "${NAMES[@]}"; do
    d="$CLIENTS/$n"; pk=$(cat "$d/public.key"); i=$((i+1))
    st="aktif"; [ -f "$d/disabled" ] && st="nonaktif"
    printf '%-3s %-16s %-15s %-10s %-14s %s / %s\n' \
      "$i" "$n" "$(cat "$d/ip")" "$st" "$(ago "${HS[$pk]:-0}")" \
      "$(hum "${TX[$pk]:-0}")" "$(hum "${RX[$pk]:-0}")"
  done
}

client_by_index() {
  local i=$1
  load_names
  if [ "$i" -ge 1 ] && [ "$i" -le "${#NAMES[@]}" ]; then
    CHOSEN=${NAMES[$((i-1))]}; return 0
  fi
  err "Nomor user tidak ada."; sleep 1; return 1
}

user_actions() {
  local n=$1 a st
  while true; do
    [ -d "$CLIENTS/$n" ] || return 0
    banner
    st="aktif"; [ -f "$CLIENTS/$n/disabled" ] && st="nonaktif"
    echo "  User : ${W}$n${N}    IP: $(cat "$CLIENTS/$n/ip")    Status: $st"
    echo
    echo "  ${W}1${N}) Tampilkan QR"
    echo "  ${W}2${N}) Tampilkan config"
    echo "  ${W}3${N}) Aktifkan / nonaktifkan"
    echo "  ${W}4${N}) Ganti nama"
    echo "  ${W}5${N}) Buat ulang key (reset)"
    echo "  ${W}6${N}) Hapus user"
    echo "  ${W}0${N}) Kembali"
    echo
    read -rp "Pilih [0-6]: " a || exit 0
    echo
    case "$a" in
      1) show_qr "$n"; pause ;;
      2) view_conf "$n"; pause ;;
      3) toggle_client "$n"; pause ;;
      4) if rename_client "$n"; then n=$RENAMED; fi; pause ;;
      5) reset_client "$n"; pause ;;
      6) if remove_client "$n"; then pause; return 0; fi ;;
      0) return 0 ;;
      *) err "Pilihan tidak valid."; sleep 1 ;;
    esac
  done
}

users_menu() {
  require_managed || return 1
  local c
  while true; do
    banner
    list_clients
    echo
    echo "  Ketik ${W}nomor${N} untuk mengatur user, ${W}a${N} = tambah user, ${W}0${N} = kembali"
    read -rp "Pilihan: " c || exit 0
    case "$c" in
      0) return 0 ;;
      a|A) add_client; pause ;;
      ''|*[!0-9]*) err "Pilihan tidak valid."; sleep 1 ;;
      *) if client_by_index "$c"; then user_actions "$CHOSEN"; fi ;;
    esac
  done
}

# ---------- diagnostik ----------
diagnose() {
  local port=${PORT:-} pub_ip ep_ip n
  if [ -z "$port" ] && [ -f "$BASE/wg0.conf" ]; then
    port=$(sed -n 's/^ListenPort[[:space:]]*=[[:space:]]*//p' "$BASE/wg0.conf" | head -1 | tr -d '[:space:]')
  fi
  _ok() { echo "  ${G}✓${N} $*"; }
  _bad() { echo "  ${R}✗${N} $1"; [ -n "${2:-}" ] && echo "      → $2"; return 0; }
  _wn() { echo "  ${Y}!${N} $1"; [ -n "${2:-}" ] && echo "      → $2"; return 0; }

  echo "${W}Diagnostik WireGuard${N}"; echo

  if systemctl is-active --quiet wg-quick@wg0 2>/dev/null; then _ok "Service wg-quick@wg0 aktif"
  else _bad "Service wg-quick@wg0 tidak aktif" "systemctl enable --now wg-quick@wg0"; fi

  if is_up; then _ok "Interface wg0 ada"; else _bad "Interface wg0 belum ada" "cek: journalctl -u wg-quick@wg0"; fi

  if [ -n "$port" ]; then
    if ss -lun 2>/dev/null | grep -q ":$port "; then _ok "WireGuard mendengarkan UDP $port"
    else _bad "Tidak ada yang mendengarkan UDP $port" "restart service WireGuard"; fi
  else
    _wn "Port tidak diketahui"
  fi

  if [ "$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null)" = 1 ]; then _ok "IP forwarding aktif"
  else _bad "IP forwarding mati" "echo 'net.ipv4.ip_forward=1' > /etc/sysctl.d/99-wireguard.conf && sysctl --system"; fi

  if ufw_active; then
    if [ -n "$port" ] && ufw status | grep -qE "(^|[^0-9])$port/udp"; then _ok "UFW mengizinkan $port/udp"
    else _bad "UFW aktif tapi $port/udp belum diizinkan" "ufw allow $port/udp"; fi
  else
    _ok "UFW tidak aktif (tidak ada pemblokiran dari UFW)"
  fi

  if iptables -t nat -S POSTROUTING 2>/dev/null | grep -q MASQUERADE; then _ok "Aturan NAT (MASQUERADE) ada"
  else _bad "Aturan NAT MASQUERADE tidak ditemukan" "restart WireGuard supaya PostUp dijalankan ulang"; fi

  if iptables -S FORWARD 2>/dev/null | grep -q "wg0"; then _ok "Aturan FORWARD untuk wg0 ada"
  else _bad "Aturan FORWARD wg0 tidak ditemukan" "restart WireGuard"; fi

  if [ -n "$ENDPOINT" ] && [[ ! $ENDPOINT =~ ^[0-9.]+$ ]]; then
    ep_ip=$(getent ahostsv4 "$ENDPOINT" 2>/dev/null | awk '{print $1; exit}')
    pub_ip=$(detect_ip)
    if [ -z "$ep_ip" ]; then _bad "Domain $ENDPOINT belum resolve" "cek record A di DNS"
    elif [ -n "$pub_ip" ] && [ "$ep_ip" != "$pub_ip" ]; then _wn "Domain $ENDPOINT -> $ep_ip, tapi IP publik server $pub_ip" "update record A kalau IP server berubah"
    else _ok "Domain $ENDPOINT -> $ep_ip"; fi
  fi

  if is_up; then
    n=$(wg show wg0 latest-handshakes | awk -v now="$(date +%s)" '$2>0 && now-$2<180{c++} END{print c+0}')
    _ok "Peer terhubung (handshake < 3 menit): $n"
  fi

  echo
  info "Yang tidak bisa dicek dari server: pastikan UDP ${port:-?} terbuka di firewall cloud"
  info "(Lightsail: tab Networking > IPv4 Firewall, EC2: Security Group)."
}

status_menu() {
  echo "Service : $(systemctl is-active wg-quick@wg0 2>/dev/null)"
  echo "Boot    : $(systemctl is-enabled wg-quick@wg0 2>/dev/null)"
  echo
  if is_up; then wg show; else warn "Interface wg0 belum aktif."; fi
  echo
  diagnose
}

# ---------- pengaturan ----------
change_endpoint() {
  info "Endpoint sekarang: $ENDPOINT:$PORT"
  ask ENDPOINT "Endpoint baru (domain / IP)" "$ENDPOINT"
  save_params; regen_all
  ok "Endpoint diperbarui di semua config."
}

change_port() {
  local old=$PORT new
  while true; do
    ask new "Port UDP baru" "$PORT"
    [[ $new =~ ^[0-9]+$ ]] && [ "$new" -ge 1 ] && [ "$new" -le 65535 ] && break
    err "Port harus angka 1-65535."
  done
  [ "$new" = "$old" ] && { info "Port tidak berubah."; return 0; }
  PORT=$new
  if ufw_active; then
    ufw allow "$PORT/udp" >/dev/null && ufw delete allow "$old/udp" >/dev/null 2>&1
    ok "UFW: buka $PORT/udp, tutup $old/udp"
  fi
  save_params; regen_all; rebuild_server_conf
  systemctl restart wg-quick@wg0 && ok "Port diubah ke $PORT dan WireGuard di-restart."
  warn "Buka UDP $PORT di firewall cloud (Lightsail/Security Group) kalau belum tercakup."
}

change_dns() { ask DNS "DNS baru (contoh: 1.1.1.1, 1.0.0.1)" "$DNS"; save_params; regen_all; ok "DNS diperbarui."; }
change_mtu() { ask MTU "MTU baru (kosongkan = default, mis. 1280)" "$MTU"; save_params; regen_all; ok "MTU diperbarui."; }
toggle_ipv6() {
  if [ "$IPV6BLOCK" = y ]; then IPV6BLOCK=n; else IPV6BLOCK=y; fi
  save_params; regen_all; ok "Blok IPv6: $IPV6BLOCK"
}

settings_menu() {
  require_managed || return 1
  local m
  while true; do
    banner
    echo "  Endpoint  : $ENDPOINT:$PORT"
    echo "  DNS       : $DNS"
    echo "  MTU       : ${MTU:-default}"
    echo "  Blok IPv6 : $IPV6BLOCK"
    echo
    echo "  ${W}1${N}) Ubah endpoint (domain / IP)"
    echo "  ${W}2${N}) Ubah port"
    echo "  ${W}3${N}) Ubah DNS"
    echo "  ${W}4${N}) Ubah MTU"
    echo "  ${W}5${N}) Blok IPv6 on/off"
    echo "  ${W}0${N}) Kembali"
    echo
    read -rp "Pilih [0-5]: " m || exit 0
    echo
    case "$m" in
      1) change_endpoint ;;
      2) change_port ;;
      3) change_dns ;;
      4) change_mtu ;;
      5) toggle_ipv6 ;;
      0) return 0 ;;
      *) err "Pilihan tidak valid."; sleep 1; continue ;;
    esac
    warn "Perangkat yang sudah terpasang perlu import ulang config yang baru (atau ubah manual di app)."
    pause
  done
}

service_menu() {
  local m
  while true; do
    banner
    echo "  Service : ${W}$(systemctl is-active wg-quick@wg0 2>/dev/null)${N}    Auto-start saat boot: ${W}$(systemctl is-enabled wg-quick@wg0 2>/dev/null)${N}"
    echo
    echo "  ${W}1${N}) Start"
    echo "  ${W}2${N}) Stop"
    echo "  ${W}3${N}) Restart"
    echo "  ${W}4${N}) Aktifkan auto-start saat boot"
    echo "  ${W}5${N}) Matikan auto-start saat boot"
    echo "  ${W}0${N}) Kembali"
    echo
    read -rp "Pilih [0-5]: " m || exit 0
    case "$m" in
      1) systemctl start wg-quick@wg0 && ok "Started." ;;
      2) systemctl stop wg-quick@wg0 && ok "Stopped." ;;
      3) systemctl restart wg-quick@wg0 && ok "Restarted." ;;
      4) systemctl enable wg-quick@wg0 >/dev/null 2>&1 && ok "Auto-start aktif." ;;
      5) systemctl disable wg-quick@wg0 >/dev/null 2>&1 && ok "Auto-start dimatikan." ;;
      0) return 0 ;;
      *) err "Pilihan tidak valid." ;;
    esac
    pause
  done
}

backup_cfg() {
  local f
  [ -d "$BASE" ] || { err "$BASE tidak ada."; return 1; }
  f="/root/wireguard-backup-$(date +%Y%m%d-%H%M%S).tar.gz"
  if tar czf "$f" -C / etc/wireguard 2>/dev/null; then
    chmod 600 "$f"
    ok "Backup tersimpan: $f"
    warn "Isinya private key. Simpan di tempat aman, jangan dibagikan."
  else
    err "Backup gagal."
  fi
}

update_script() {
  local tmp
  tmp=$(mktemp)
  info "Mengunduh versi terbaru dari GitHub..."
  if curl -fsSL "$SCRIPT_URL" -o "$tmp" && bash -n "$tmp" 2>/dev/null && head -1 "$tmp" | grep -q bash; then
    install -m 755 "$tmp" "$SELF_BIN" && ok "Script diperbarui. Jalankan lagi: ${W}wgmenu${N}"
    rm -f "$tmp"
    exit 0
  fi
  rm -f "$tmp"
  err "Gagal memperbarui (cek koneksi atau SCRIPT_URL di script)."
}

uninstall_wg() {
  require_managed || return 1
  local a
  warn "Ini akan mematikan VPN dan menghapus pengaturan WireGuard."
  read -rp "Ketik HAPUS untuk lanjut: " a || exit 0
  [ "$a" = HAPUS ] || { info "Dibatalkan."; return 0; }
  systemctl disable --now wg-quick@wg0 >/dev/null 2>&1
  if command -v ufw >/dev/null 2>&1; then ufw delete allow "$PORT/udp" >/dev/null 2>&1; fi
  rm -f /etc/sysctl.d/99-wireguard.conf
  if confirm "Hapus juga semua key & data user di $BASE?" n; then
    rm -rf "${CLIENTS:?}" "$BASE/wg0.conf" "$PARAMS" "$BASE"/server_*.key
    ok "Data dihapus."
  fi
  if confirm "Hapus paket wireguard dari sistem?" n; then
    apt-get remove -y wireguard wireguard-tools >/dev/null 2>&1
  fi
  rm -f "$SELF_BIN"
  ok "Uninstall selesai."
  exit 0
}

# ---------- impor setup yang sudah ada ----------
IMP_NAME=""; IMP_PUB=""; IMP_AIP=""; IMP_PSK=""; IMP_COUNT=0

imp_flush() {
  [ -n "$IMP_PUB" ] && [ -n "$IMP_AIP" ] || return 0
  local aip=${IMP_AIP%%,*} cip n base i=1
  cip=${aip%%/*}
  n=$(printf '%s' "${IMP_NAME:-peer}" | tr -c 'A-Za-z0-9_-' '_' | cut -c1-15)
  [ -n "$n" ] || n=peer
  base=$n
  while [ -d "$CLIENTS/$n" ]; do i=$((i+1)); n="${base:0:12}-$i"; done
  ( umask 077
    mkdir -p "$CLIENTS/$n"
    echo "$IMP_PUB" > "$CLIENTS/$n/public.key"
    echo "$cip" > "$CLIENTS/$n/ip"
    if [ -n "$IMP_PSK" ]; then echo "$IMP_PSK" > "$CLIENTS/$n/psk.key"; fi
  )
  IMP_COUNT=$((IMP_COUNT+1))
  IMP_NAME=""; IMP_PUB=""; IMP_AIP=""; IMP_PSK=""
}

import_existing() {
  banner
  if [ "$STATE" = managed ]; then warn "Setup ini sudah dikelola script."; return 0; fi
  if [ ! -f "$BASE/wg0.conf" ]; then err "Tidak ada $BASE/wg0.conf untuk diimpor."; return 1; fi
  command -v wg >/dev/null 2>&1 || { err "wireguard-tools belum terpasang."; return 1; }
  if ! command -v qrencode >/dev/null 2>&1; then
    info "Memasang qrencode..."
    apt-get install -y -qq qrencode >/dev/null 2>&1 || warn "qrencode gagal dipasang (QR tidak akan tampil)."
  fi

  local conf="$BASE/wg0.conf" addr spriv nic ip4 pubip line v f privk pubk d n matched=0 bk
  PORT=$(sed -n 's/^ListenPort[[:space:]]*=[[:space:]]*//p' "$conf" | head -1 | tr -d '[:space:]')
  addr=$(sed -n 's/^Address[[:space:]]*=[[:space:]]*//p' "$conf" | head -1 | tr -d '[:space:]')
  spriv=$(sed -n 's/^PrivateKey[[:space:]]*=[[:space:]]*//p' "$conf" | head -1 | tr -d '[:space:]')
  nic=$(grep -o -- '-o [A-Za-z0-9_.-]*' "$conf" | head -1 | awk '{print $2}')
  ip4=${addr%%,*}; ip4=${ip4%%/*}
  SUBNET=${ip4%.*}

  if ! [[ $PORT =~ ^[0-9]+$ ]] || ! [[ $SUBNET =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || [ -z "$spriv" ]; then
    err "wg0.conf tidak bisa dibaca (ListenPort / Address / PrivateKey tidak lengkap)."
    return 1
  fi
  case "$addr" in */24*) ;; *) warn "Subnet bukan /24. Script ini mengasumsikan /24." ;; esac

  echo "${W}Terbaca dari $conf:${N}"
  echo "  Port      : $PORT"
  echo "  Subnet    : ${SUBNET}.0/24"
  echo "  Interface : ${nic:-?}"
  echo "  Peer      : $(grep -c '^\[Peer\]' "$conf")"
  echo
  pubip=$(detect_ip)
  ask ENDPOINT "Endpoint untuk config client (domain / IP)" "$pubip"
  ask NIC "Interface internet server" "${nic:-$(detect_nic)}"
  ask DNS "DNS client" "1.1.1.1"
  MTU=""
  IPV6BLOCK=n
  echo
  confirm "Impor dan mulai kelola setup ini? (koneksi yang berjalan tidak diputus)" y || { info "Dibatalkan."; return 0; }

  bk="$BASE/backup-pre-import-$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$bk"
  cp -a "$BASE"/*.conf "$BASE"/*.key "$bk"/ 2>/dev/null
  ok "Backup config lama: $bk"

  ( umask 077
    mkdir -p "$CLIENTS"
    printf '%s\n' "$spriv" > "$BASE/server_private.key"
    printf '%s' "$spriv" | wg pubkey > "$BASE/server_public.key"
  )
  chmod 700 "$BASE"

  # peer dari wg0.conf -> folder clients/
  IMP_COUNT=0; IMP_NAME=""; IMP_PUB=""; IMP_AIP=""; IMP_PSK=""
  local inpeer=0
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}
    line=${line#"${line%%[![:space:]]*}"}
    case "$line" in
      "[Peer]"*)      imp_flush; inpeer=1 ;;
      "[Interface]"*) imp_flush; inpeer=0 ;;
      "#"*)           if [ $inpeer -eq 1 ] && [ -z "$IMP_NAME" ]; then IMP_NAME=${line#\#}; IMP_NAME=${IMP_NAME# }; fi ;;
      PublicKey*)     v=$(echo "$line" | sed 's/^[^=]*=[[:space:]]*//; s/[[:space:]]*$//'); [ $inpeer -eq 1 ] && IMP_PUB=$v ;;
      PresharedKey*)  v=$(echo "$line" | sed 's/^[^=]*=[[:space:]]*//; s/[[:space:]]*$//'); [ $inpeer -eq 1 ] && IMP_PSK=$v ;;
      AllowedIPs*)    v=$(echo "$line" | sed 's/^[^=]*=[[:space:]]*//; s/[[:space:]]*$//'); [ $inpeer -eq 1 ] && IMP_AIP=$v ;;
    esac
  done < "$conf"
  imp_flush

  # cocokkan file config client lama (mis. phone.conf) dengan peer lewat public key
  for f in "$BASE"/*.conf; do
    [ "$(basename "$f")" = wg0.conf ] && continue
    grep -q '^\[Interface\]' "$f" && grep -q '^PrivateKey' "$f" || continue
    privk=$(sed -n 's/^PrivateKey[[:space:]]*=[[:space:]]*//p' "$f" | head -1 | tr -d '[:space:]')
    pubk=$(printf '%s' "$privk" | wg pubkey 2>/dev/null) || continue
    for d in "$CLIENTS"/*/; do
      [ -f "${d}public.key" ] || continue
      if [ "$(cat "${d}public.key")" = "$pubk" ] && [ ! -f "${d}private.key" ]; then
        n=$(basename "$d")
        ( umask 077
          printf '%s\n' "$privk" > "${d}private.key"
          cp "$f" "${d}$n.conf" )
        matched=$((matched+1)); break
      fi
    done
  done

  save_params
  refresh_state
  rebuild_server_conf
  if is_up; then wg syncconf wg0 <(wg-quick strip wg0); else systemctl start wg-quick@wg0; fi
  systemctl enable wg-quick@wg0 >/dev/null 2>&1

  ok "Impor selesai: $IMP_COUNT user dibaca, $matched config client berhasil dicocokkan."
  if [ "$matched" -lt "$IMP_COUNT" ]; then
    warn "User tanpa config tidak bisa menampilkan QR (private key HP tidak ada di server)."
    info "Gunakan 'Buat ulang key' di menu user kalau butuh config baru untuk mereka."
  fi
  info "Nama user diambil dari komentar di wg0.conf; bisa diganti lewat menu user."
}

# ---------- wizard install ----------
install_wg() {
  banner
  if [ "$STATE" = managed ]; then warn "WireGuard sudah terpasang & dikelola script ini."; pause; return 0; fi
  command -v apt-get >/dev/null 2>&1 || { err "Script ini hanya mendukung Debian/Ubuntu (apt)."; pause; return 1; }

  if [ "$STATE" = manual ]; then
    warn "Setup WireGuard manual sudah ada di $BASE."
    info "Disarankan pakai menu 2 (Impor) supaya user & koneksi yang ada tetap jalan."
    confirm "Tetap lanjut install baru (config lama akan dibackup lalu ditimpa)?" n || return 0
  fi

  echo "${W}Wizard Install WireGuard${N}"
  echo "Tekan Enter untuk memakai nilai default [dalam kurung]."
  echo

  local pubip first
  info "Mendeteksi IP publik..."
  pubip=$(detect_ip)
  if [ -n "$pubip" ]; then ok "IP publik terdeteksi: $pubip"; else warn "IP publik tidak terdeteksi, isi manual."; fi

  ENDPOINT=""
  while [ -z "$ENDPOINT" ]; do
    ask ENDPOINT "1) Endpoint server (domain atau IP publik)" "$pubip"
  done

  while true; do
    ask PORT "2) Port UDP WireGuard" "51820"
    [[ $PORT =~ ^[0-9]+$ ]] && [ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ] && break
    err "Port harus angka 1-65535."
  done
  if ss -lun 2>/dev/null | grep -q ":$PORT "; then
    warn "Port UDP $PORT sepertinya sudah dipakai proses lain."
    confirm "Tetap lanjut?" n || return 0
  fi

  while true; do
    ask SUBNET "3) Subnet VPN (3 oktet pertama, dipakai sebagai /24)" "10.8.0"
    [[ $SUBNET =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] && break
    err "Format salah. Contoh: 10.8.0"
  done

  NIC=$(detect_nic)
  ask NIC "4) Interface jaringan internet server" "${NIC:-eth0}"
  ask DNS "5) DNS untuk client" "1.1.1.1"
  if confirm "6) Cegah kebocoran IPv6 (blokir IPv6 lewat tunnel)?" y; then IPV6BLOCK=y; else IPV6BLOCK=n; fi
  ask MTU "7) MTU (kosongkan untuk default, coba 1280 jika koneksi aneh)" ""

  while true; do
    ask first "8) Nama user pertama (maks 15 karakter: huruf/angka/-/_)" "hp"
    [[ $first =~ ^[A-Za-z0-9_-]{1,15}$ ]] && break
    err "Nama tidak valid."
  done

  echo
  echo "${W}Ringkasan:${N}"
  echo "  Endpoint   : $ENDPOINT:$PORT"
  echo "  Subnet     : ${SUBNET}.0/24 (server ${SUBNET}.1)"
  echo "  Interface  : $NIC"
  echo "  DNS        : $DNS"
  echo "  Blok IPv6  : $IPV6BLOCK"
  echo "  MTU        : ${MTU:-default}"
  echo "  User awal  : $first"
  echo
  confirm "Lanjut install?" y || { info "Dibatalkan."; pause; return 0; }

  if [ -f "$BASE/wg0.conf" ]; then
    local bk
    bk="$BASE/backup-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$bk"
    systemctl disable --now wg-quick@wg0 >/dev/null 2>&1
    mv "$BASE"/*.conf "$BASE"/*.key "$bk"/ 2>/dev/null
    ok "Config lama dibackup ke $bk"
  fi

  echo
  info "Memasang paket..."
  export DEBIAN_FRONTEND=noninteractive
  if ! { apt-get update -qq && apt-get install -y -qq wireguard wireguard-tools qrencode iptables curl >/dev/null; }; then
    err "Gagal memasang paket."; pause; return 1
  fi
  ok "Paket terpasang."

  info "Mengaktifkan IP forwarding..."
  echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-wireguard.conf
  sysctl -q -p /etc/sysctl.d/99-wireguard.conf

  if ufw_active; then
    ufw allow "$PORT/udp" >/dev/null && ok "UFW aktif: port $PORT/udp dibuka."
  fi

  info "Membuat key server..."
  ( umask 077
    mkdir -p "$CLIENTS"
    wg genkey | tee "$BASE/server_private.key" | wg pubkey > "$BASE/server_public.key"
  )
  chmod 700 "$BASE"

  save_params
  refresh_state
  rebuild_server_conf
  systemctl enable --now wg-quick@wg0 >/dev/null 2>&1
  if is_up; then ok "WireGuard berjalan (wg0)."; else err "wg0 gagal start. Cek: journalctl -u wg-quick@wg0"; pause; return 1; fi

  add_client "$first"

  if [ "$(readlink -f "$0" 2>/dev/null)" != "$SELF_BIN" ]; then
    if [ -f "$0" ] && install -m 755 "$0" "$SELF_BIN" 2>/dev/null; then :
    elif curl -fsSL "$SCRIPT_URL" -o "$SELF_BIN" 2>/dev/null; then chmod 755 "$SELF_BIN"
    fi
  fi
  [ -x "$SELF_BIN" ] && ok "Menu bisa dibuka lagi dengan perintah: ${W}wgmenu${N}"

  echo
  echo "${W}${Y}PENTING - jangan lupa:${N}"
  echo "  1) Buka ${W}UDP $PORT${N} di firewall cloud (Lightsail: tab Networking > IPv4 Firewall,"
  echo "     AWS EC2: Security Group), kalau belum tercakup rule yang ada."
  echo "  2) Kalau Endpoint pakai domain, pastikan record A mengarah ke IP server"
  echo "     (Cloudflare: mode DNS only / awan abu-abu)."
  pause
}

# ---------- menu utama ----------
main_menu() {
  local m
  while true; do
    refresh_state
    banner
    case "$STATE" in
      managed)
        echo "  Status   : ${G}terpasang${N}  (service: ${W}$(systemctl is-active wg-quick@wg0 2>/dev/null)${N})"
        echo "  Endpoint : ${W}$ENDPOINT:$PORT${N}    User: ${W}$(client_count)${N}"
        ;;
      manual)
        echo "  Status   : ${Y}setup WireGuard manual terdeteksi${N} (belum dikelola script)"
        echo "  Pilih ${W}2${N} untuk mengimpor user & config yang sudah ada."
        ;;
      none)
        echo "  Status   : ${R}WireGuard belum terpasang${N}"
        ;;
    esac
    echo
    echo "  ${W} 1${N}) Install WireGuard (wizard)"
    echo "  ${W} 2${N}) Impor setup yang sudah ada"
    echo "  ${W} 3${N}) Daftar user & atur"
    echo "  ${W} 4${N}) Tambah user"
    echo "  ${W} 5${N}) Status & diagnostik"
    echo "  ${W} 6${N}) Pengaturan (endpoint, port, DNS, MTU, IPv6)"
    echo "  ${W} 7${N}) Service (start / stop / restart)"
    echo "  ${W} 8${N}) Backup config"
    echo "  ${W} 9${N}) Update script dari GitHub"
    echo "  ${W}10${N}) Uninstall"
    echo "  ${W} 0${N}) Keluar"
    echo
    read -rp "Pilih menu [0-10]: " m || exit 0
    echo
    case "$m" in
      1) install_wg ;;
      2) import_existing; pause ;;
      3) users_menu ;;
      4) if require_managed; then add_client; fi; pause ;;
      5) status_menu; pause ;;
      6) settings_menu ;;
      7) service_menu ;;
      8) backup_cfg; pause ;;
      9) update_script; pause ;;
      10) uninstall_wg; pause ;;
      0) exit 0 ;;
      *) err "Pilihan tidak valid."; sleep 1 ;;
    esac
  done
}

main() {
  need_root

  # Supaya tetap interaktif saat dijalankan lewat: curl ... | bash
  if [ ! -t 0 ] && (: </dev/tty) 2>/dev/null; then exec </dev/tty; fi

  refresh_state
  case "${1:-}" in
    add)  require_managed || exit 1; add_client "${2:-}"; exit 0 ;;
    list) require_managed || exit 1; list_clients; exit 0 ;;
  esac

  main_menu
}

main "$@"
