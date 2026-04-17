#!/usr/bin/env python3
"""
Nexus OSS Cleanup Script
========================
Kural (image/artifact adı bazında):
  - Her bir image/artifact adı için en yeni 2 tag/versiyon HER ZAMAN korunur
  - 3+ tag varsa, en yeni 2'si korunur, geri kalanlardan 90 günden eskiler silinir

Örnekler:
  pioneer/jsure-partner-manager-test:1521  → korunur (en yeni 1)
  pioneer/jsure-partner-manager-test:1520  → korunur (en yeni 2)
  pioneer/jsure-partner-manager-test:1519  → 90 günden eskiyse SİLİNİR

Kullanım:
  python3 nexus_cleanup.py [--dry-run]
"""

import requests
import argparse
from datetime import datetime, timezone, timedelta
from collections import defaultdict

# ─── YAPILANDIRMA ─────────────────────────────────────────────────────────────
NEXUS_URL      = "https://nexus.domain.com" # <-- Gerçek URL'inizle değiştirin
USERNAME       = "admin"             
PASSWORD       = "admin123"                 # <-- Gerçek şifrenizle değiştirin
MIN_KEEP       = 2                          # Her image adı için minimum korunacak tag sayısı
RETENTION_DAYS = 90
# ──────────────────────────────────────────────────────────────────────────────

session = requests.Session()
session.auth = (USERNAME, PASSWORD)
session.verify = False
session.headers.update({"Accept": "application/json"})

cutoff = datetime.now(timezone.utc) - timedelta(days=RETENTION_DAYS)


def get_all_repos():
    r = session.get(f"{NEXUS_URL}/service/rest/v1/repositories")
    r.raise_for_status()
    return [repo for repo in r.json() if repo.get("type") == "hosted"]


def get_components(repo_name):
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
    if not date_str:
        return datetime.min.replace(tzinfo=timezone.utc)
    for fmt in ("%Y-%m-%dT%H:%M:%S.%f%z", "%Y-%m-%dT%H:%M:%S%z"):
        try:
            return datetime.strptime(date_str, fmt)
        except ValueError:
            continue
    return datetime.min.replace(tzinfo=timezone.utc)


def get_component_date(component):
    dates = []
    for asset in component.get("assets", []):
        blob_created = asset.get("blobCreated")
        if blob_created:
            dates.append(parse_date(blob_created))
    if not dates:
        return parse_date(component.get("lastModified"))
    return max(dates)


def delete_component(component_id, dry_run):
    if dry_run:
        return True
    r = session.delete(f"{NEXUS_URL}/service/rest/v1/components/{component_id}")
    return r.status_code in (200, 204)


def process_repo(repo, dry_run):
    repo_name = repo["name"]
    print(f"\n{'─'*60}")
    print(f"Repo: {repo_name} ({repo.get('format', '?')})")

    try:
        components = get_components(repo_name)
    except Exception as e:
        print(f"  [HATA] Componentler alınamadı: {e}")
        return

    # Her image adı için tag'leri grupla
    # Docker: name="pioneer/jsure-partner-manager-test", version="1521"
    # Maven:  name="medisa-collection-ws",               version="1.2.0.0-prod"
    groups = defaultdict(list)
    for c in components:
        groups[c.get("name", "unknown")].append(c)

    total_deleted = 0
    total_skipped = 0
    total_protected = 0

    for image_name, tags in sorted(groups.items()):
        # En yeniden eskiye sırala
        tags.sort(key=lambda c: get_component_date(c), reverse=True)

        kept = tags[:MIN_KEEP]
        candidates = tags[MIN_KEEP:]

        total_protected += len(kept)

        if not candidates:
            continue  # 1-2 tag var, dokunma

        deleted_this = 0
        skipped_this = 0

        for c in candidates:
            comp_date = get_component_date(c)
            if comp_date < cutoff:
                label = "[DRY-RUN] SİLİNECEK" if dry_run else "SİLİNDİ"
                ok = delete_component(c["id"], dry_run)
                if ok:
                    print(f"  ✗ {label}: {image_name}:{c.get('version')}  [{comp_date.strftime('%Y-%m-%d')}]")
                    deleted_this += 1
                else:
                    print(f"  ! BAŞARISIZ: {image_name}:{c.get('version')}")
            else:
                skipped_this += 1

        if deleted_this > 0:
            kept_str = ", ".join(c.get("version", "?") for c in kept)
            print(f"    └─ Korunan → {image_name}: [{kept_str}]")

        total_deleted += deleted_this
        total_skipped += skipped_this

    print(f"\n  Özet → Silinen: {total_deleted} | 90 gün içinde korunan: {total_skipped} | Min. korunan (image başına 2): {total_protected}")


def main():
    parser = argparse.ArgumentParser(description="Nexus OSS Cleanup - Per Image Name")
    parser.add_argument("--dry-run", action="store_true",
                        help="Silme yapmadan sadece ne yapılacağını göster")
    args = parser.parse_args()

    if args.dry_run:
        print("=" * 60)
        print("  DRY-RUN MODU — HİÇBİR ŞEY SİLİNMEYECEK")
        print("=" * 60)

    print(f"Bağlanılıyor: {NEXUS_URL}")
    print(f"Eşik: {RETENTION_DAYS} gün | Her image için min. koruma: {MIN_KEEP} tag")
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
