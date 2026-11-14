#!/usr/bin/env bash
# ==============================================================
#  WireGuard Setup & User Manager
#  Debian / Ubuntu  |  Jalankan sebagai root
#
#  Pertama kali dijalankan  -> wizard install (ditanya-tanya)
#  Setelah terpasang        -> menu atur user
#  Setelah install, cukup ketik:  wgmenu
# ==============================================================
set -uo pipefail

BASE=/etc/wireguard
CLIENTS=$BASE/clients
PARAMS=$BASE/params
SELF_BIN=/usr/local/bin/wgmenu
SCRIPT_URL="https://raw.githubusercontent.com/X14OC14/wireguard/main/install.sh"

R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; C=$'\e[36m'; W=$'\e[1m'; N=$'\e[0m'

info() { echo "${C}[i]${N} $*"; }
ok()   { echo "${G}[✓]${N} $*"; }
warn() { echo "${Y}[!]${N} $*"; }
err()  { echo "${R}[✗]${N} $*" >&2; }
pause() { echo; read -rp "Tekan Enter untuk lanjut..." _; }

# ask VAR "Pertanyaan" "default"
ask() {
  local __v=$1 __p=$2 __d=${3:-} __in
  if [ -n "$__d" ]; then
    read -rp "$__p [$__d]: " __in
    __in=${__in:-$__d}
  else
    read -rp "$__p: " __in
  fi
  printf -v "$__v" '%s' "$__in"
}

# confirm "Pertanyaan" y|n   (default)
confirm() {
  local d=${2:-y} a hint="Y/n"
  [ "$d" = n ] && hint="y/N"
  read -rp "$1 [$hint]: " a
  a=${a:-$d}
  [[ $a =~ ^[Yy]$ ]]
}

banner() {
  [ -t 1 ] && clear
  echo "${W}${C}"
  echo "  ╔══════════════════════════════════════════╗"
  echo "  ║        WireGuard Setup & Manager         ║"
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

load_params() { [ -f "$PARAMS" ] && source "$PARAMS"; }

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

is_up() { ip link show wg0 >/dev/null 2>&1; }

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
        echo "PresharedKey = $(cat "${d}psk.key")"
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
      echo "PresharedKey = $(cat "$d/psk.key")"
      echo "Endpoint = $ENDPOINT:$PORT"
      echo "AllowedIPs = $allowed"
      echo "PersistentKeepalive = 25"
    } > "$d/$n.conf"
  )
}

show_qr() {
  local n=$1
  [ -f "$CLIENTS/$n/$n.conf" ] || { err "Config '$n' tidak ditemukan."; return 1; }
  echo
  qrencode -t ansiutf8 < "$CLIENTS/$n/$n.conf"
  echo
  info "File config : $CLIENTS/$n/$n.conf"
  info "Nama tunnel : ketik '$n' saat scan QR (atau pakai nama file saat import)."
  warn "QR & config berisi private key. Jangan dibagikan ke publik / grup."
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

pick_client() {
  CHOSEN=""
  local names=() d i=1 c x flag
  for d in "$CLIENTS"/*/; do
    [ -f "${d}ip" ] && names+=("$(basename "$d")")
  done
  if [ ${#names[@]} -eq 0 ]; then warn "Belum ada user."; return 1; fi
  for x in "${names[@]}"; do
    flag=""
    [ -f "$CLIENTS/$x/disabled" ] && flag=" (nonaktif)"
    echo "  $i) $x$flag"
    i=$((i+1))
  done
  read -rp "Pilih nomor user: " c
  if [[ $c =~ ^[0-9]+$ ]] && [ "$c" -ge 1 ] && [ "$c" -le ${#names[@]} ]; then
    CHOSEN=${names[$((c-1))]}
    return 0
  fi
  err "Pilihan tidak valid."
  return 1
}

list_clients() {
  declare -A HS RX TX
  local k t r i=0 d n pk st
  if is_up; then
    while read -r k t; do HS[$k]=$t; done < <(wg show wg0 latest-handshakes)
    while read -r k r t; do RX[$k]=$r; TX[$k]=$t; done < <(wg show wg0 transfer)
  fi
  echo "${W}No  Nama             IP              Status     Handshake      Unduh / Unggah${N}"
  for d in "$CLIENTS"/*/; do
    [ -f "${d}ip" ] || continue
    n=$(basename "$d"); pk=$(cat "${d}public.key"); i=$((i+1))
    st="aktif"; [ -f "${d}disabled" ] && st="nonaktif"
    printf '%-3s %-16s %-15s %-10s %-14s %s / %s\n' \
      "$i" "$n" "$(cat "${d}ip")" "$st" "$(ago "${HS[$pk]:-0}")" \
      "$(hum "${TX[$pk]:-0}")" "$(hum "${RX[$pk]:-0}")"
  done
  if [ $i -eq 0 ]; then warn "Belum ada user."; fi
}

remove_client() {
  pick_client || return 1
  confirm "Hapus user '$CHOSEN' permanen?" n || return 0
  rm -rf "${CLIENTS:?}/$CHOSEN"
  apply_conf
  ok "User '$CHOSEN' dihapus."
}

toggle_client() {
  pick_client || return 1
  if [ -f "$CLIENTS/$CHOSEN/disabled" ]; then
    rm -f "$CLIENTS/$CHOSEN/disabled"; apply_conf; ok "User '$CHOSEN' diaktifkan."
  else
    touch "$CLIENTS/$CHOSEN/disabled"; apply_conf; ok "User '$CHOSEN' dinonaktifkan (config tetap tersimpan)."
  fi
}

view_conf() {
  pick_client || return 1
  echo; echo "${W}--- $CLIENTS/$CHOSEN/$CHOSEN.conf ---${N}"
  cat "$CLIENTS/$CHOSEN/$CHOSEN.conf"
  echo "${W}-----------------------------------------${N}"
  warn "Berisi private key. Jangan dibagikan ke publik."
}

change_endpoint() {
  local d n
  info "Endpoint sekarang: $ENDPOINT:$PORT"
  ask ENDPOINT "Endpoint baru (domain / IP)" "$ENDPOINT"
  save_params
  for d in "$CLIENTS"/*/; do
    [ -f "${d}ip" ] || continue
    n=$(basename "$d"); write_client_conf "$n"
  done
  ok "Endpoint diperbarui di semua config."
  warn "Perangkat yang sudah terpasang perlu import ulang config / ganti Endpoint manual."
}

server_status() {
  echo "Service : $(systemctl is-active wg-quick@wg0 2>/dev/null)"
  echo "Enabled : $(systemctl is-enabled wg-quick@wg0 2>/dev/null)"
  echo
  if is_up; then wg show; else warn "Interface wg0 belum aktif."; fi
}

uninstall_wg() {
  local a
  warn "Ini akan mematikan VPN dan menghapus pengaturan WireGuard."
  read -rp "Ketik HAPUS untuk lanjut: " a
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

# ---------- wizard install ----------
install_wg() {
  banner
  command -v apt-get >/dev/null 2>&1 || { err "Script ini hanya mendukung Debian/Ubuntu (apt)."; exit 1; }

  echo "${W}Wizard Install WireGuard${N}"
  echo "Jawab pertanyaan berikut. Tekan Enter untuk memakai nilai default [dalam kurung]."
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
    confirm "Tetap lanjut?" n || exit 1
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
  confirm "Lanjut install?" y || { info "Dibatalkan."; exit 0; }

  # Backup konfigurasi lama (kalau ada setup manual sebelumnya)
  if [ -f "$BASE/wg0.conf" ] && [ ! -f "$PARAMS" ]; then
    warn "Ditemukan wg0.conf lama di $BASE (bukan dari script ini)."
    confirm "Backup lalu timpa dengan setup baru?" n || { info "Dibatalkan."; exit 0; }
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
    err "Gagal memasang paket."; exit 1
  fi
  ok "Paket terpasang."

  info "Mengaktifkan IP forwarding..."
  echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-wireguard.conf
  sysctl -q -p /etc/sysctl.d/99-wireguard.conf

  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw allow "$PORT/udp" >/dev/null && ok "UFW aktif: port $PORT/udp dibuka."
  fi

  info "Membuat key server..."
  ( umask 077
    mkdir -p "$CLIENTS"
    wg genkey | tee "$BASE/server_private.key" | wg pubkey > "$BASE/server_public.key"
  )
  chmod 700 "$BASE"

  save_params
  rebuild_server_conf
  systemctl enable --now wg-quick@wg0 >/dev/null 2>&1
  if is_up; then ok "WireGuard berjalan (wg0)."; else err "wg0 gagal start. Cek: journalctl -u wg-quick@wg0"; exit 1; fi

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

# ---------- menu ----------
main_menu() {
  local m
  while true; do
    banner
    echo "  Endpoint : ${W}$ENDPOINT:$PORT${N}   Status: ${W}$(systemctl is-active wg-quick@wg0 2>/dev/null)${N}"
    echo
    echo "  ${W}1${N}) Daftar user & status"
    echo "  ${W}2${N}) Tambah user"
    echo "  ${W}3${N}) Hapus user"
    echo "  ${W}4${N}) Aktif / nonaktifkan user"
    echo "  ${W}5${N}) Tampilkan QR user"
    echo "  ${W}6${N}) Tampilkan config user"
    echo "  ${W}7${N}) Status server (wg show)"
    echo "  ${W}8${N}) Ubah endpoint (domain / IP)"
    echo "  ${W}9${N}) Restart WireGuard"
    echo "  ${W}10${N}) Uninstall"
    echo "  ${W}0${N}) Keluar"
    echo
    read -rp "Pilih menu [0-10]: " m
    echo
    case "$m" in
      1) list_clients; pause ;;
      2) add_client; pause ;;
      3) remove_client; pause ;;
      4) toggle_client; pause ;;
      5) if pick_client; then show_qr "$CHOSEN"; fi; pause ;;
      6) view_conf; pause ;;
      7) server_status; pause ;;
      8) change_endpoint; pause ;;
      9) if systemctl restart wg-quick@wg0; then ok "WireGuard di-restart."; fi; pause ;;
      10) uninstall_wg; pause ;;
      0) exit 0 ;;
      *) err "Pilihan tidak valid."; sleep 1 ;;
    esac
  done
}

# ---------- entry ----------
main() {
  need_root

  # Supaya tetap interaktif saat dijalankan lewat: curl ... | bash
  if [ ! -t 0 ] && [ -r /dev/tty ]; then exec </dev/tty; fi

  case "${1:-}" in
    add)  load_params; add_client "${2:-}"; exit 0 ;;
    list) load_params; list_clients; exit 0 ;;
  esac

  if [ -f "$PARAMS" ] && [ -f "$BASE/server_private.key" ]; then
    load_params
  else
    install_wg
  fi
  main_menu
}

main "$@"
