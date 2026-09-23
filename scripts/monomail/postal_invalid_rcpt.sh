#!/bin/bash

# --- Yapılandırma ---
DB_BIN="mariadb"          # Sistemdeki mariadb binary adı
DB_MAIN="postal"          # Ana veritabanı adı
DEFAULT_DAYS=30           # Varsayılan geriye dönük gün sayısı
SUPPRESS_DAYS=90          # Suppression listesine eklenenlerin tutulma süresi (gün)

# "Alıcı yok" anlamına gelen SMTP cevapları (büyük/küçük harf duyarsız)
# İhtiyaca göre genişletilebilir / daraltılabilir
RCPT_PATTERN='(?i)(5[.]1[.]1|5[.]1[.]10|5[.]1[.]6|user unknown|unknown user|no such user|user not found|does not exist|doesn.t exist|unknown recipient|recipient not found|invalid recipient|recipient address rejected|mailbox not found|mailbox unavailable|no mailbox|no such mailbox|address not found|account.*(disabled|inactive|not exist))'

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

server_names=()
server_dbs=()
i=1

echo "--- [Monomail] Postal Geçersiz Alıcı Raporu ---"
echo "Lütfen işlem yapacağınız sunucuyu seçin:"
echo "----------------------------------------"

# --batch çıktısı TAB ile ayrılır; boşluklu sunucu adları korunur
while IFS=$'\t' read -r id name; do
    db_name="postal-server-$id"
    server_names+=("$name")
    server_dbs+=("$db_name")
    printf "%2d) %-20s (%s)\n" "$i" "$name" "$db_name"
    ((i++))
done <<< "$SERVER_DATA"

echo "----------------------------------------"
read -p "Seçiminiz [1-$((i-1))]: " selection

if [[ ! "$selection" =~ ^[0-9]+$ ]] || [ "$selection" -lt 1 ] || [ "$selection" -ge "$i" ]; then
    echo "Hata: Geçersiz seçim."
    exit 1
fi

index=$((selection-1))
SELECTED_DB="${server_dbs[$index]}"
SELECTED_NAME="${server_names[$index]}"

if ! $DB_BIN -e "USE \`$SELECTED_DB\`" &>/dev/null; then
    echo "Hata: '$SELECTED_DB' veritabanı sistemde bulunamadı."
    exit 1
fi

# Gün sayısı sor
ask_days() {
    read -p "Kaç gün geriye bakılsın? [$DEFAULT_DAYS]: " DAYS
    DAYS=${DAYS:-$DEFAULT_DAYS}
    if [[ ! "$DAYS" =~ ^[0-9]+$ ]] || [ "$DAYS" -lt 1 ]; then
        echo "Hata: Geçersiz gün sayısı."
        return 1
    fi
    return 0
}

# Ortak filtre (outgoing + HardFail + alıcı yok cevabı + tarih aralığı)
base_filter() {
    echo "m.scope = 'outgoing'
      AND d.status = 'HardFail'
      AND d.output REGEXP '$RCPT_PATTERN'
      AND d.timestamp >= UNIX_TIMESTAMP(NOW() - INTERVAL $DAYS DAY)"
}

# Adres bazında tekilleştirilmiş sorgu
grouped_query() {
    echo "SELECT m.rcpt_to AS alici,
                 COUNT(*) AS deneme,
                 FROM_UNIXTIME(MIN(d.timestamp)) AS ilk,
                 FROM_UNIXTIME(MAX(d.timestamp)) AS son,
                 LEFT(REPLACE(REPLACE(SUBSTRING_INDEX(GROUP_CONCAT(d.output ORDER BY d.timestamp DESC SEPARATOR '||'), '||', 1), '\n', ' '), '\r', ''), 150) AS son_cevap
          FROM deliveries d
          JOIN messages m ON m.id = d.message_id
          WHERE $(base_filter)
          GROUP BY m.rcpt_to
          ORDER BY deneme DESC, son DESC"
}

# 2. İşlem Döngüsü
while true; do
    echo -e "\nAktif Sunucu: $SELECTED_NAME ($SELECTED_DB)"
    echo "-----------------------------------"
    echo "1) Geçersiz Alıcıları Listele (tekil adres)"
    echo "2) Detaylı Liste (her teslimat denemesi)"
    echo "3) E-posta Adresine Göre Ara"
    echo "4) Tekil Listeyi CSV Olarak Dışa Aktar"
    echo "5) Listeyi Suppression Tablosuna Ekle"
    echo "6) Sunucu Değiştir"
    echo "7) Çıkış"
    read -p "İşlem Seçiniz [1-7]: " action

    case $action in
        1)
            ask_days || continue
            COUNT=$($DB_BIN -D "$SELECTED_DB" --batch --skip-column-names -e "SELECT COUNT(*) FROM ($(grouped_query)) x;")
            echo "Son $DAYS günde alıcısı bulunmayan tekil adres sayısı: $COUNT"
            [[ "$COUNT" -gt 0 ]] && $DB_BIN -t -D "$SELECTED_DB" -e "$(grouped_query);" | less -S
            ;;
        2)
            ask_days || continue
            QUERY="SELECT d.id, m.id AS msg_id, m.mail_from, m.rcpt_to, LEFT(m.subject, 40) AS konu,
                          FROM_UNIXTIME(d.timestamp) AS zaman,
                          LEFT(REPLACE(REPLACE(d.output, '\n', ' '), '\r', ''), 150) AS cevap
                   FROM deliveries d
                   JOIN messages m ON m.id = d.message_id
                   WHERE $(base_filter)
                   ORDER BY d.timestamp DESC;"
            $DB_BIN -t -D "$SELECTED_DB" -e "$QUERY" | less -S
            ;;
        3)
            read -p "Aranacak e-posta adresi (veya parçası, örn: @firma.com): " MAIL_ADDR
            if [[ -z "$MAIL_ADDR" ]]; then
                echo "Hata: Adres boş olamaz."
                continue
            fi
            ask_days || continue
            SAFE_ADDR=$(printf '%s' "$MAIL_ADDR" | sed "s/'/''/g")
            QUERY="SELECT m.rcpt_to, m.mail_from, FROM_UNIXTIME(d.timestamp) AS zaman, d.status,
                          LEFT(REPLACE(REPLACE(d.output, '\n', ' '), '\r', ''), 150) AS cevap
                   FROM deliveries d
                   JOIN messages m ON m.id = d.message_id
                   WHERE $(base_filter)
                     AND m.rcpt_to LIKE '%$SAFE_ADDR%'
                   ORDER BY d.timestamp DESC;"
            RESULT=$($DB_BIN -t -D "$SELECTED_DB" -e "$QUERY")
            if [[ -z "$RESULT" ]]; then
                echo "Bilgi: '$MAIL_ADDR' için geçersiz alıcı kaydı bulunamadı."
            else
                echo "$RESULT" | less -S
            fi
            ;;
        4)
            ask_days || continue
            OUT_FILE="invalid-rcpt_${SELECTED_DB}_$(date +%Y%m%d_%H%M%S).csv"
            {
                echo "alici;deneme;ilk;son;son_cevap"
                $DB_BIN -D "$SELECTED_DB" --batch --skip-column-names -e "$(grouped_query);" \
                    | sed 's/;/,/g' | tr '\t' ';'
            } > "$OUT_FILE"
            echo "Dışa aktarıldı: $(realpath "$OUT_FILE") ($(($(wc -l < "$OUT_FILE")-1)) kayıt)"
            ;;
        5)
            ask_days || continue
            NEW_COUNT=$($DB_BIN -D "$SELECTED_DB" --batch --skip-column-names -e "
                SELECT COUNT(*) FROM ($(grouped_query)) x
                WHERE NOT EXISTS (SELECT 1 FROM suppressions s WHERE s.type='recipient' AND s.address = x.alici);")
            if [[ "$NEW_COUNT" -eq 0 ]]; then
                echo "Bilgi: Eklenecek yeni adres yok (hepsi zaten suppression listesinde)."
                continue
            fi
            echo "UYARI: $NEW_COUNT adres $SUPPRESS_DAYS gün süreyle suppression listesine EKLENECEK."
            read -p "Onaylamak için EKLE yazın: " CONFIRM
            if [[ "$CONFIRM" == "EKLE" ]]; then
                $DB_BIN -D "$SELECTED_DB" -e "
                    INSERT INTO suppressions (type, address, reason, timestamp, keep_until)
                    SELECT 'recipient', x.alici, 'Recipient does not exist (script)',
                           UNIX_TIMESTAMP(), UNIX_TIMESTAMP(NOW() + INTERVAL $SUPPRESS_DAYS DAY)
                    FROM ($(grouped_query)) x
                    WHERE NOT EXISTS (SELECT 1 FROM suppressions s WHERE s.type='recipient' AND s.address = x.alici);"
                if [ $? -eq 0 ]; then
                    echo "İşlem başarılı: $NEW_COUNT adres eklendi."
                else
                    echo "Hata: Ekleme işlemi başarısız."
                fi
            else
                echo "İşlem iptal edildi."
            fi
            ;;
        6)
            exec "$0"
            ;;
        7)
            echo "Çıkılıyor..."
            exit 0
            ;;
        *)
            echo "Geçersiz işlem."
            ;;
    esac
done
