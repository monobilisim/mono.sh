#!/bin/bash

# Parametre kontrolu
if [ -z "$1" ]; then
    echo "Usage: $0 email@example.com"
    exit 1
fi

SEARCH_EMAIL="$1"

# Ciktinin yazilacagi dosya
OUTPUT_FILE="/srv/sent_emails_results.txt"

# Cikti dosyasini kontrol et
if [ ! -e "$OUTPUT_FILE" ]; then
    touch "$OUTPUT_FILE"
    chown zimbra:zimbra "$OUTPUT_FILE"
    chmod 640 "$OUTPUT_FILE"
fi

# Dosyayi bastan temizle
echo "Email Check Results for $SEARCH_EMAIL - $(date)" > "$OUTPUT_FILE"

# Donguyle tum kullanicilari kontrol et
for USER in $(zmprov -l gaa); do
    echo "Checking Sent emails for $USER to $SEARCH_EMAIL" | tee -a "$OUTPUT_FILE"
    
    # Zimbra zmmailbox sorgusu ile detaylari al ve dosyaya ekle
    zmmailbox -z -m "$USER" s -t message "in:Sent TO:$SEARCH_EMAIL" >> "$OUTPUT_FILE"
    
    echo "----------------------------------------" >> "$OUTPUT_FILE"
done
