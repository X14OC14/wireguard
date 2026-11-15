# WireGuard Manager

Script interaktif untuk memasang dan mengelola VPN [WireGuard](https://www.wireguard.com/) di VPS Debian/Ubuntu. Ada wizard install, menu atur user, QR code untuk HP, dan diagnostik. Cukup satu perintah, lalu ikuti menu.

## Fitur

- Menu utama interaktif, tidak ada yang berjalan sebelum kamu memilih
- Wizard install yang menanyakan endpoint, port, subnet, DNS, MTU, dan user pertama
- **Impor setup WireGuard manual** yang sudah ada, tanpa memutus koneksi
- Kelola user: tambah, hapus, aktif/nonaktifkan, ganti nama, reset key
- QR code dan file config per user, lengkap dengan preshared key
- Tabel status user: handshake terakhir dan pemakaian data
- Diagnostik: service, port, IP forwarding, UFW, NAT, dan DNS domain
- Pengaturan endpoint (domain atau IP), port, DNS, MTU, dan blok IPv6
- Backup config, update script dari GitHub, dan uninstall

## Kebutuhan

- VPS Debian atau Ubuntu dengan akses **root** (diuji di Ubuntu 24.04)
- Koneksi internet di server
- Port **UDP** WireGuard (default `51820`) terbuka di firewall cloud

## Cara pakai

Jalankan di VPS sebagai root:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/X14OC14/wireguard/main/install.sh)
```

Atau lewat pipe:

```bash
curl -fsSL https://raw.githubusercontent.com/X14OC14/wireguard/main/install.sh | sudo bash
```

Setelah script pertama kali dijalankan, perintah `wgmenu` terpasang otomatis, jadi menu bisa dibuka lagi kapan saja:

```bash
wgmenu
```

Perintah cepat tanpa membuka menu:

```bash
wgmenu add NAMA     # tambah user dan tampilkan QR
wgmenu list         # daftar user dan status
```

## Menu

| No | Menu | Keterangan |
|----|------|------------|
| 1 | Install WireGuard | Wizard install untuk server baru |
| 2 | Impor setup yang sudah ada | Mengambil alih `wg0.conf` hasil setup manual |
| 3 | Daftar user & atur | Tabel user, lalu pilih nomor untuk QR, config, nonaktifkan, ganti nama, reset key, hapus |
| 4 | Tambah user | Buat user baru dan tampilkan QR |
| 5 | Status & diagnostik | Cek kesehatan server beserta saran perbaikan |
| 6 | Pengaturan | Endpoint, port, DNS, MTU, blok IPv6 |
| 7 | Service | Start, stop, restart, auto-start saat boot |
| 8 | Backup config | Arsip `.tar.gz` di `/root` |
| 9 | Update script | Unduh versi terbaru dari GitHub |
| 10 | Uninstall | Matikan VPN dan hapus pengaturan |

## Alur singkat

**Server baru**

1. Jalankan script, pilih **1**, jawab pertanyaan wizard
2. Scan QR yang muncul dengan app WireGuard di HP
3. Pastikan UDP port WireGuard terbuka di firewall cloud

**Sudah punya setup WireGuard manual**

1. Jalankan script, pilih **2**
2. Script membaca `wg0.conf`, mengimpor semua peer, dan mencocokkan file config client lama lewat public key
3. Config lama dibackup otomatis dulu, dan koneksi yang sedang berjalan tidak diputus

**Membagikan ke teman**

Buat **satu user per teman** lewat menu **4**. Jangan membagikan satu config ke banyak perangkat, karena key yang sama tidak bisa dipakai di dua perangkat sekaligus. Kirim QR atau file config lewat chat pribadi, bukan grup.

## Pemasangan di HP / komputer

1. Install app **WireGuard** (Android, iOS, Windows, macOS, atau Linux)
2. Scan QR dari terminal, atau pilih **Import from file** dan pakai file config dari menu user
3. Aktifkan toggle tunnel-nya

Catatan: nama tunnel di app Android maksimal 15 karakter (huruf, angka, dan `_ = + . -`). Batas yang sama dipakai untuk nama user di script.

## Struktur file di server

```
/etc/wireguard/
├── wg0.conf              # dibuat ulang otomatis oleh script, jangan diedit manual
├── params                # pengaturan (endpoint, port, subnet, DNS, dst)
├── server_private.key
├── server_public.key
└── clients/
    └── NAMA/
        ├── private.key
        ├── public.key
        ├── psk.key
        ├── ip
        ├── NAMA.conf     # config yang dipasang di perangkat user
        └── disabled      # ada hanya kalau user dinonaktifkan
```

`wg0.conf` dibangun dari folder `clients/`. Ubah user lewat menu, bukan dengan mengedit `wg0.conf` langsung.

## Troubleshooting

Mulai dari menu **5 (Status & diagnostik)**, karena biasanya langsung menunjukkan sumber masalahnya.

**Tidak ada handshake sama sekali** (`wg show` tidak menampilkan `latest handshake`)

- Port UDP belum terbuka di firewall cloud (Lightsail: tab Networking, IPv4 Firewall. EC2: Security Group)
- UFW aktif tapi port belum diizinkan: `ufw allow 51820/udp`
- Endpoint di config salah, atau record A domain belum mengarah ke IP server
- Kalau domain lewat Cloudflare, pastikan mode **DNS only** (awan abu-abu). Proxy tidak meneruskan UDP.

**Ada handshake tapi internet tidak jalan**

- IP forwarding mati, atau aturan NAT/FORWARD tidak terpasang: restart WireGuard lewat menu **7**
- Interface internet salah: cek dengan `ip route | grep default`, lalu sesuaikan di menu **6**

**VPN mati sendiri di Android saat idle**

- Aktifkan **Always-on VPN** untuk WireGuard di pengaturan VPN Android
- Set baterai app WireGuard ke **Tanpa batasan / Unrestricted**
- Izinkan autostart dan aktivitas latar belakang (ada di menu khusus di beberapa merek HP)

## Catatan keamanan

- Script berjalan sebagai **root**. Baca isinya dulu sebelum dijalankan, dan hanya jalankan dari repo yang kamu percaya.
- QR dan file config berisi **private key**. Jangan dikirim ke grup atau diunggah ke tempat publik. Kalau bocor, pakai **Buat ulang key** di menu user.
- Semua traffic user keluar lewat IP servermu, jadi aktivitas mereka tercatat atas IP tersebut. Bagikan hanya ke orang yang kamu percaya.
- Saat ini sesama user VPN bisa saling menjangkau perangkat di dalam subnet VPN (tidak ada isolasi antar client).
- Traffic user memakai kuota transfer bulanan dari penyedia VPS-mu.

## Uninstall

Pilih menu **10** lalu ketik `HAPUS`. Script menanyakan apakah data dan paket WireGuard ikut dihapus. Gunakan menu **8** untuk backup dulu kalau masih butuh key-nya.
