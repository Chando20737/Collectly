#!/usr/bin/env python3
"""
eBay Image Downloader
Télécharge les images de cartes hockey via eBay Finding API
"""

import json
import requests
import os
import time
from pathlib import Path
import csv

# CONFIG
EBAY_APP_ID = "EricChan-Collectl-PRD-db452d056-616d69ca"  # Obtenir sur https://developer.ebay.com/
TCDB_JSON = "tcdb_sets.json"
OUTPUT_DIR = "card_images"
CSV_OUTPUT = "downloaded_cards.csv"
DELAY = 0.5  # secondes entre requêtes
MAX_IMGS_PER_CARD = 3

Path(OUTPUT_DIR).mkdir(exist_ok=True)

def load_tcdb_sets(filepath):
    with open(filepath, 'r', encoding='utf-8') as f:
        return json.load(f)['sets']

def search_ebay(player, number, set_name, year=None):
    # Simplifier: juste joueur + année + numéro (set name cause trop de fails)
    if year:
        query = f"{player} {year} hockey card #{number}"
    else:
        query = f"{player} hockey card #{number}"
    
    url = "https://svcs.ebay.com/services/search/FindingService/v1"
    params = {
        'OPERATION-NAME': 'findItemsAdvanced',
        'SERVICE-VERSION': '1.0.0',
        'SECURITY-APPNAME': EBAY_APP_ID,
        'RESPONSE-DATA-FORMAT': 'JSON',
        'keywords': query,
        'categoryId': '261328',
        'paginationInput.entriesPerPage': MAX_IMGS_PER_CARD,
        'sortOrder': 'BestMatch'
    }
    
    try:
        r = requests.get(url, params=params, timeout=10)
        data = r.json()
        items = data.get('findItemsAdvancedResponse', [{}])[0].get('searchResult', [{}])[0].get('item', [])
        
        urls = []
        for item in items:
            img = item.get('galleryURL', [None])[0]
            if img:
                urls.append(img.replace('s-l80', 's-l500'))
        return urls
    except:
        return []

def download(url, path):
    try:
        r = requests.get(url, timeout=10, stream=True)
        with open(path, 'wb') as f:
            for chunk in r.iter_content(8192):
                f.write(chunk)
        return True
    except:
        return False

def safe_name(text):
    for c in '<>:"/\\|?*':
        text = text.replace(c, '-')
    return text[:100]

def main():
    print("🚀 eBay Downloader")
    
    if EBAY_APP_ID == "YOUR_EBAY_APP_ID":
        print("❌ Configure EBAY_APP_ID")
        return
    
    sets = load_tcdb_sets(TCDB_JSON)
    print(f"✅ {len(sets)} sets chargés")
    
    # FILTRER: Commencer par les sets les plus récents (plus de chances sur eBay)
    print("\n🎯 Tri des sets par année (plus récents en premier)...")
    sorted_sets = sorted(sets.items(), key=lambda x: x[0], reverse=True)
    
    # Optionnel: Limiter aux sets 2020+
    recent_sets = [(name, data) for name, data in sorted_sets if name.startswith(('202', '201'))]
    
    if recent_sets:
        print(f"✅ {len(recent_sets)} sets récents (2010+) à traiter")
        sets_to_process = recent_sets
    else:
        print("⚠️  Pas de filtre d'année, traitement de tous les sets")
        sets_to_process = sorted_sets
    
    csv_f = open(CSV_OUTPUT, 'w', newline='', encoding='utf-8')
    writer = csv.writer(csv_f)
    writer.writerow(['set', 'number', 'player', 'image_count', 'paths'])
    
    total = 0
    downloaded = 0
    found = 0
    not_found = 0
    
    for set_name, data in sets_to_process:
        print(f"\n📦 {set_name}")
        cards = data.get('cards', {})
        
        for num, player in list(cards.items())[:5]:  # TEST: Seulement 5 cartes par set au début
            total += 1
            year = set_name.split()[0] if set_name and '-' in set_name.split()[0] else None
            
            print(f"  [{total}] {player} #{num}...", end=' ', flush=True)
            
            urls = search_ebay(player, num, set_name, year)
            if not urls:
                print("❌ Pas sur eBay")
                writer.writerow([set_name, num, player, 0, ''])
                not_found += 1
                time.sleep(DELAY)
                continue
            
            found += 1
            paths = []
            for i, url in enumerate(urls):
                fname = f"{year}_{safe_name(set_name)}_{safe_name(num)}_{i+1}.jpg"
                fpath = os.path.join(OUTPUT_DIR, fname)
                if download(url, fpath):
                    paths.append(fpath)
                    downloaded += 1
            
            print(f"✅ {len(paths)} image(s)")
            writer.writerow([set_name, num, player, len(paths), '|'.join(paths)])
            time.sleep(DELAY)
            
            # Stats intermédiaires
            if total % 20 == 0:
                success_rate = (found / total * 100) if total > 0 else 0
                print(f"\n📊 Stats: {found}/{total} trouvées ({success_rate:.1f}%), {downloaded} images")
    
    csv_f.close()
    
    # Stats finales
    success_rate = (found / total * 100) if total > 0 else 0
    print(f"\n✅ FINAL: {total} cartes, {found} trouvées ({success_rate:.1f}%), {downloaded} images → {OUTPUT_DIR}/")

if __name__ == "__main__":
    main()
