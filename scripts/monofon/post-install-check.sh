#!/usr/bin/env bash

FREEPBXPACKAGENAME="freepbx17"

if ! fwconsole ma upgradeall; then
    echo "Hata: Framework ve modüller güncellenemedi."
    echo "Lütfen önce internet bağlantısını kontrol edin."
    exit 1
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

if ! fwconsole ma upgradeall; then
    echo "Hata: Framework ve modüller güncellenemedi."
    echo "Lütfen önce internet bağlantısını kontrol edin."
    exit 1
fi

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

echo "Commercial modüller kaldırıldıktan sonra veritabanı eşitleniyor..."
fwconsole reload

HOSTNAME=$(hostname)
if ! fwconsole setting FREEPBX_SYSTEM_IDENT "$HOSTNAME"; then
    echo "Hata: Hostname "$HOSTNAME" değerine güncellenirken hata oluştu."
    exit 1
fi

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
