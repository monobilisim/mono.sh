#!/bin/bash

# --- Yapılandırma ---
DB_BIN="mariadb" # Sistemdeki mariadb binary adı
DB_MAIN="postal" # Ana veritabanı adı

# MariaDB Binary Kontrolü
if ! command -v $DB_BIN &> /dev/null; then
    echo "Hata: '$DB_BIN' komutu bulunamadı. Lütfen binary adını kontrol edin."
    exit 1
fi

# 1. Ana veritabanından sunucu bilgilerini çek
SERVER_DATA=$($DB_BIN -D "$DB_MAIN" -e "SELECT id, name FROM servers;" --batch --skip-column-names)

if [ -z "$SERVER_DATA" ]; then
    echo "Hata: '$DB_MAIN' veritabanından sunucu listesi alınamadı."
    exit 1
fi

# Sunucu dizilerini oluştur
server_names=()
server_dbs=()
i=1

echo "--- [Monomail] Postal Suppressions Yönetimi ---"
echo "Lütfen işlem yapacağınız sunucuyu seçin:"
echo "----------------------------------------"

# Verileri işle ve dikey (alt alta) yazdır
while read -r id name; do
    # Name kolonundaki boşluklu yapıyı koru
    full_name=$(echo "$SERVER_DATA" | grep "^$id" | awk '{$1=""; print $0}' | sed 's/^ //')
    db_name="postal-server-$id"
    
    server_names+=("$full_name")
    server_dbs+=("$db_name")
    
    printf "%2d) %-20s (%s)\n" "$i" "$full_name" "$db_name"
    ((i++))
done <<< "$SERVER_DATA"

echo "----------------------------------------"
read -p "Seçiminiz [1-$((i-1))]: " selection

# Seçim doğrulaması
if [[ ! "$selection" =~ ^[0-9]+$ ]] || [ "$selection" -lt 1 ] || [ "$selection" -ge "$i" ]; then
    echo "Hata: Geçersiz seçim."
    exit 1
fi

# İndis ayarı
index=$((selection-1))
SELECTED_DB="${server_dbs[$index]}"
SELECTED_NAME="${server_names[$index]}"

# DB mevcudiyet kontrolü
if ! $DB_BIN -e "USE \`$SELECTED_DB\`" &>/dev/null; then
    echo "Hata: '$SELECTED_DB' veritabanı sistemde bulunamadı."
    exit 1
fi

# 2. İşlem Döngüsü
while true; do
    echo -e "\nAktif Sunucu: $SELECTED_NAME ($SELECTED_DB)"
    echo "-----------------------------------"
    echo "1) Tüm Suppression Kayıtlarını Listele"
    echo "2) E-posta ile Kayıt Ara ve Sil"
    echo "3) Sunucu Değiştir"
    echo "4) Çıkış"
    read -p "İşlem Seçiniz [1-4]: " action

    case $action in
        1)
            QUERY="SELECT id, type, address, reason, FROM_UNIXTIME(timestamp), FROM_UNIXTIME(keep_until) FROM suppressions;"
            $DB_BIN -t -D "$SELECTED_DB" -e "$QUERY" | less -S
            ;;
        2)
            read -p "Aranacak e-posta adresi: " MAIL_ADDR
            if [[ -z "$MAIL_ADDR" ]]; then
                echo "Hata: Mail adresi boş olamaz."
                continue
            fi

            # Kayıt sorgulama
            CHECK_QUERY="SELECT id, address, reason, FROM_UNIXTIME(timestamp) FROM suppressions WHERE address = '$MAIL_ADDR';"
            CHECK_DATA=$($DB_BIN -t -D "$SELECTED_DB" -e "$CHECK_QUERY")
            
            if [[ -z "$CHECK_DATA" ]]; then
                echo "Bilgi: '$MAIL_ADDR' için kayıt bulunamadı."
            else
                echo -e "\nKayıt Detayı:"
                echo "$CHECK_DATA"
                read -p "Bu kayıt SİLİNSİN Mİ? (y/n): " CONFIRM
                if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
                    $DB_BIN -D "$SELECTED_DB" -e "DELETE FROM suppressions WHERE address = '$MAIL_ADDR' LIMIT 1;"
                    if [ $? -eq 0 ]; then
                        echo "İşlem başarılı."
                    else
                        echo "Hata: Silme işlemi başarısız."
                    fi
                else
                    echo "İşlem iptal edildi."
                fi
            fi
            ;;
        3)
            exec "$0"
            ;;
        4)
            echo "Çıkılıyor..."
            exit 0
            ;;
        *)
            echo "Geçersiz işlem."
            ;;
    esac
done
