#!/usr/bin/env python3
"""
Nexus OSS Cleanup Script
========================
Kural:
  - Her repoda en az 2 component HER ZAMAN korunur (tarihe bakmaksızın)
  - 3+ component varsa, en yeni 2'si korunur, geri kalanlardan 90 günden
    eskiler silinir.

Kullanım:
  python3 nexus_cleanup.py [--dry-run]

  --dry-run : Silme işlemi yapmaz, sadece ne yapılacağını loglar.
"""

import requests
import argparse
from datetime import datetime, timezone, timedelta

# ─── YAPILANDIRMA ─────────────────────────────────────────────────────────────
NEXUS_URL      = "https://nexus.domain.com" # <-- Gerçek domaininizle değiştirin
USERNAME       = "admin"
PASSWORD       = "admin123"                 # <-- Gerçek şifrenizle değiştirin
MIN_KEEP       = 2                          # Her repoda minimum korunacak paket sayısı
RETENTION_DAYS = 90                         # Gün eşiği
# ──────────────────────────────────────────────────────────────────────────────

session = requests.Session()
session.auth = (USERNAME, PASSWORD)
session.verify = False               # Self-signed cert varsa False bırakın
session.headers.update({"Accept": "application/json"})

cutoff = datetime.now(timezone.utc) - timedelta(days=RETENTION_DAYS)

def get_all_repos():
    """Tüm hosted repoları döner."""
    r = session.get(f"{NEXUS_URL}/service/rest/v1/repositories")
    r.raise_for_status()
    return [repo for repo in r.json() if repo.get("type") == "hosted"]

def get_components(repo_name):
    """Bir repodaki tüm componentleri sayfalayarak çeker."""
    components = []
    continuation_token = None
    while True:
        params = {"repository": repo_name}
        if continuation_token:
            params["continuationToken"] = continuation_token
        r = session.get(f"{NEXUS_URL}/service/rest/v1/components", params=params)
        r.raise_for_status()
        data = r.json()
        components.extend(data.get("items", []))
        continuation_token = data.get("continuationToken")
        if not continuation_token:
            break
    return components

def parse_date(date_str):
    """ISO 8601 tarih stringini datetime objesine çevirir."""
    if not date_str:
        return datetime.min.replace(tzinfo=timezone.utc)
    # Farklı format varyantlarını destekle
    for fmt in ("%Y-%m-%dT%H:%M:%S.%f%z", "%Y-%m-%dT%H:%M:%S%z"):
        try:
            return datetime.strptime(date_str, fmt)
        except ValueError:
            continue
    return datetime.min.replace(tzinfo=timezone.utc)

def delete_component(component_id, dry_run):
    """Bir componenti siler."""
    if dry_run:
        return True
    r = session.delete(f"{NEXUS_URL}/service/rest/v1/components/{component_id}")
    return r.status_code in (200, 204)

def get_component_date(component):
    """Component için en güncel tarihi döner (assets içindeki blobCreated kullanılır)."""
    dates = []
    for asset in component.get("assets", []):
        blob_created = asset.get("blobCreated")
        if blob_created:
            dates.append(parse_date(blob_created))
    if not dates:
        # Fallback: component düzeyindeki lastModified
        last_modified = component.get("lastModified")
        return parse_date(last_modified)
    return max(dates)

def process_repo(repo, dry_run):
    repo_name = repo["name"]
    print(f"\n{'─'*60}")
    print(f"Repo: {repo_name} ({repo.get('format', '?')})")

    try:
        components = get_components(repo_name)
    except Exception as e:
        print(f"  [HATA] Componentler alınamadı: {e}")
        return

    total = len(components)
    print(f"  Toplam component: {total}")

    if total <= MIN_KEEP:
        print(f"  → {total} component var, minimum {MIN_KEEP} eşiğinde. HİÇBİR ŞEY SİLİNMEDİ.")
        return

    # En yeni tarihten eskiye sırala
    components.sort(key=lambda c: get_component_date(c), reverse=True)

    kept    = components[:MIN_KEEP]
    candidates = components[MIN_KEEP:]

    print(f"  Korunan (ilk {MIN_KEEP}):")
    for c in kept:
        d = get_component_date(c)
        print(f"    ✔ {c.get('name')}:{c.get('version')}  [{d.strftime('%Y-%m-%d')}]")

    deleted_count = 0
    skipped_count = 0

    for c in candidates:
        comp_date = get_component_date(c)
        name_ver  = f"{c.get('name')}:{c.get('version')}"
        date_str  = comp_date.strftime('%Y-%m-%d')

        if comp_date < cutoff:
            tag = "[DRY-RUN] SİLİNECEK" if dry_run else "SİLİNDİ"
            ok  = delete_component(c["id"], dry_run)
            if ok:
                print(f"    ✗ {tag}: {name_ver}  [{date_str}]  (90 günden eski)")
                deleted_count += 1
            else:
                print(f"    ! SİLME BAŞARISIZ: {name_ver}")
        else:
            print(f"    ~ Korundu (90 gün içinde): {name_ver}  [{date_str}]")
            skipped_count += 1

    print(f"  Özet → Silinen: {deleted_count} | 90 gün içinde korunan: {skipped_count} | Min. korunan: {MIN_KEEP}")

def main():
    parser = argparse.ArgumentParser(description="Nexus OSS Cleanup Script")
    parser.add_argument("--dry-run", action="store_true",
                        help="Silme yapmadan sadece ne yapılacağını göster")
    args = parser.parse_args()

    if args.dry_run:
        print("=" * 60)
        print("  DRY-RUN MODU — HİÇBİR ŞEY SİLİNMEYECEK")
        print("=" * 60)

    print(f"Bağlanılıyor: {NEXUS_URL}")
    print(f"Eşik: {RETENTION_DAYS} gün | Min. koruma: {MIN_KEEP} component")
    print(f"Silme tarihi eşiği: {cutoff.strftime('%Y-%m-%d')}")

    try:
        repos = get_all_repos()
    except Exception as e:
        print(f"[HATA] Repolar alınamadı: {e}")
        return

    print(f"\nToplam {len(repos)} hosted repo bulundu.")

    for repo in repos:
        process_repo(repo, args.dry_run)

    print(f"\n{'='*60}")
    print("Cleanup tamamlandı.")

if __name__ == "__main__":
    import urllib3
    urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)
    main()
