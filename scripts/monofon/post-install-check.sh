#!/usr/bin/env bash
FREEPBXPACKAGENAME="freepbx17"

# Sangoma repo GPG anahtarı süre dolumu (EXPKEYSIG) hatasını önlemek için apt update'ten önce güncelliyoruz.
if ! fwconsole util updategpgkey; then
    echo "Uyarı: GPG anahtarı güncellenemedi, apt update yine de denenecek."
fi

# Güncelleyebilmek için FreePBX paketininin dokunulmazlığını kaldırıyoruz.
# Burada hata olması bir sorun yaratmıyor.
apt-mark unhold "$FREEPBXPACKAGENAME";
# Eğer repolar 30 dakika kilitlenirse, bu kilit arka arkaya birkaç update başarısız olursa koyulmakta.
if ! apt -o Acquire::Max-FutureTime=86400 update; then
    echo "Hata: Paket listesi güncellenemedi."
    apt-mark hold "$FREEPBXPACKAGENAME";
    exit 1
fi
if ! apt upgrade -y; then
    echo "Hata: Paketler güncellenemedi."
    apt-mark hold "$FREEPBXPACKAGENAME";
    exit 1
fi
# Sistemi güncelledikten sonra FreePBX paketini geri dokunulmaz hale getiriyoruz.
if ! apt-mark hold "$FREEPBXPACKAGENAME"; then
    echo "Hata: apt-mark hold $FREEPBXPACKAGENAME işlemi gerçekleştirilemedi."
    exit 1
fi
if ! apt autoremove -y; then
    echo "Hata: Gereksiz paketler kaldırılamadı."
    exit 1
fi

# Commercial modülleri, framework/modül güncellemesinden önce kaldırıyoruz.
FAILED_MODULES=()
PREVIOUS_COUNT=-1
while true; do
    mapfile -t COMMERCIAL_MODULES < <(
        fwconsole ma list 2>/dev/null \
          | awk -F'|' 'NR>3 && /Commercial/ { gsub(/[[:space:]]/, "", $2); print $2 }' \
          | grep -v '^$'
        )
    if [ ${#COMMERCIAL_MODULES[@]} -eq 0 ]; then
        echo "Tüm Commercial modüller başarıyla kaldırıldı."
        break
    fi
    # Önceki iterasyondan beri ilerleme yoksa, kalan modüller kaldırılamıyor demektir.
    if [ "${#COMMERCIAL_MODULES[@]}" -eq "$PREVIOUS_COUNT" ]; then
        FAILED_MODULES=("${COMMERCIAL_MODULES[@]}")
        echo "Bazı Commercial modüller kaldırılamadı, döngüden çıkılıyor."
        break
    fi
    PREVIOUS_COUNT=${#COMMERCIAL_MODULES[@]}
    echo "Kaldırılacak ${#COMMERCIAL_MODULES[@]} Commercial modül kaldı..."
    for module in "${COMMERCIAL_MODULES[@]}"; do
        if fwconsole ma uninstall "$module"; then
            fwconsole ma remove "$module"
        fi
    done
done

# Gereksiz görülen ek modüller de Commercial modüllerle birlikte kaldırılıyor.
EXTRA_MODULES=(amd bulkhandler disa firewall hotelwakeup tts ttsengines ucp webrtc)
echo "Gereksiz görülen ${#EXTRA_MODULES[@]} ek modül kaldırılıyor..."
for module in "${EXTRA_MODULES[@]}"; do
    if fwconsole ma uninstall "$module" 2>/dev/null; then
        fwconsole ma remove "$module"
    else
        echo "Uyarı: $module zaten kurulu değil veya kaldırılamadı, atlanıyor."
    fi
done

if ! fwconsole ma upgradeall; then
    echo "Hata: Framework ve modüller güncellenemedi."
    echo "Lütfen önce internet bağlantısını kontrol edin."
    exit 1
fi

echo "Commercial modüller kaldırıldıktan sonra veritabanı eşitleniyor..."
fwconsole reload
HOSTNAME=$(hostname)
if ! fwconsole setting FREEPBX_SYSTEM_IDENT "$HOSTNAME"; then
    echo "Hata: Hostname "$HOSTNAME" değerine güncellenirken hata oluştu."
    exit 1
fi

# --- Swap kontrolü ve oluşturulması ---
setup_swap() {
    # Sistemde herhangi bir swap (partition, LVM, dosya) aktif mi?
    if swapon --show 2>/dev/null | grep -q .; then
        echo -e "\e[32mOK: Sistemde zaten aktif swap mevcut, kurulum atlanıyor:\e[0m"
        swapon --show
        return 0
    fi

    echo -e "\e[33mUyarı: Sistemde aktif swap bulunamadı, otomatik oluşturuluyor...\e[0m"

    local mem_kb mem_gb swap_size_gb
    mem_kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
    mem_gb=$(( mem_kb / 1024 / 1024 ))

    if   (( mem_gb >= 2 && mem_gb < 8 )); then
        swap_size_gb=2
    elif (( mem_gb >= 8 && mem_gb < 64 )); then
        swap_size_gb=4
    else
        echo -e "\e[31mBilgi: RAM boyutu (${mem_gb}GB) tanımlı aralıkların (2-64GB) dışında. Otomatik swap boyutu belirlenemedi, manuel kontrol gerekiyor.\e[0m"
        return 0
    fi

    echo "RAM: ${mem_gb}GB tespit edildi, ${swap_size_gb}GB boyutunda /swapfile oluşturuluyor..."

    if ! fallocate -l "${swap_size_gb}G" /swapfile 2>/dev/null; then
        echo "fallocate başarısız oldu, dd ile deneniyor (bu biraz zaman alabilir)..."
        if ! dd if=/dev/zero of=/swapfile bs=1M count=$(( swap_size_gb * 1024 )) status=progress; then
            echo -e "\e[31mHata: /swapfile oluşturulamadı.\e[0m"
            return 1
        fi
    fi

    chmod 600 /swapfile

    if ! mkswap /swapfile; then
        echo -e "\e[31mHata: mkswap /swapfile başarısız oldu.\e[0m"
        rm -f /swapfile
        return 1
    fi

    if ! swapon /swapfile; then
        echo -e "\e[31mHata: swapon /swapfile başarısız oldu.\e[0m"
        return 1
    fi

    if ! grep -q '^/swapfile' /etc/fstab; then
        echo '/swapfile none swap sw 0 0' >> /etc/fstab
        echo "fstab'a /swapfile girdisi eklendi."
    fi

    echo -e "\e[32mOK: ${swap_size_gb}GB swap başarıyla oluşturuldu ve aktifleştirildi.\e[0m"
}

setup_swap

FILE="/etc/asterisk/globals_custom.conf"
FOUND_OGG=false
while IFS= read -r line; do
  if [[ "$line" == "MIXMON_FORMAT = ogg" ]]; then
    FOUND_OGG=true
    break
  fi
done < "$FILE"
if [ "$FOUND_OGG" = false ]; then
  echo -e "\e[31mMIXMON_FORMAT = ogg ayarı eksik\e[0m"
  echo -e "Lütfen \e[33m$FILE\e[0m dosyasına bu satırı ekleyin: \e[33mMIXMON_FORMAT = ogg\e[0m"
else
    echo -e "\e[32mMIXMON_FORMAT = ogg ayarı mevcut\e[0m"
fi
LOGROTATEFILE="/etc/logrotate.d/asterisk"
if [[ ! -f "$LOGROTATEFILE" ]]; then
    echo -e "\e[31mError: "$LOGROTATEFILE" bulunamadı!\e[0m" >&2
    exit 1
fi
QUEUELOG_BLOCK=$(sed -n '/^\/var\/log\/asterisk\/queue_log[[:space:]]*{/,/^}/p' "$LOGROTATEFILE")
if echo "$QUEUELOG_BLOCK" | grep -q "^[[:space:]]*daily[[:space:]]*$"; then
    echo -e "\e[31mALERT: queue_log günlük (daily) modda\e[0m"
    echo -e "Lütfen \e[33m$LOGROTATEFILE\e[0m dosyasındaki queue_log bloğunda \e[33mdaily\e[0m yerine \e[33mmonthly\e[0m ayarlayın."
fi
if echo "$QUEUELOG_BLOCK" | grep -q "^[[:space:]]*monthly[[:space:]]*$"; then
    echo -e "\e[32mOK: queue_log aylık (monthly) modda\e[0m"
fi
if [ ${#FAILED_MODULES[@]} -gt 0 ]; then
    echo -e "\e[31mKaldırılamayan Commercial modüller (${#FAILED_MODULES[@]}):\e[0m"
    for module in "${FAILED_MODULES[@]}"; do
        echo -e "\e[31m  - $module\e[0m"
    done
fi
