#!/usr/bin/env python3
"""
TCDB Direct Image Downloader
Génère les URLs d'images directement depuis les CIDs sans scraping
"""

import os
import re
import requests
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor, as_completed
import time

def extract_cids_from_checklist(html_file):
    """Extrait les CIDs depuis un checklist HTML"""
    with open(html_file, 'r', encoding='utf-8') as f:
        content = f.read()
    
    # Pattern: ViewCard.cfm/sid/SETID/cid/CID
    pattern = r'ViewCard\.cfm/sid/(\d+)/cid/(\d+)'
    matches = re.findall(pattern, content)
    
    # Déduplique
    unique = {}
    for sid, cid in matches:
        unique[cid] = sid
    
    return unique

def extract_cids_from_url_file(url_file):
    """Extrait les CIDs depuis un fichier d'URLs"""
    cids = {}
    with open(url_file, 'r') as f:
        for line in f:
            match = re.search(r'/sid/(\d+)/cid/(\d+)', line)
            if match:
                sid, cid = match.groups()
                cids[cid] = sid
    return cids

def generate_image_urls(sid, cid):
    """Génère les URLs front et back pour une carte"""
    base = f"https://www.tcdb.com/Images/Cards/Hockey/{sid}/{sid}-{cid}"
    return {
        'front': f"{base}Fr.jpg",
        'back': f"{base}Bk.jpg"
    }

def download_image(url, output_path, max_retries=3):
    """Télécharge une image avec retry"""
    headers = {
        'User-Agent': 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
        'Referer': 'https://www.tcdb.com/',
        'Accept': 'image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8',
    }
    
    cookies = {
        'CFID': '482174795',
        'CFTOKEN': 'fbbd9288d60da2ad-D4AE74B4-08DA-AFF3-CBF5DEE7C31B6A42',
        'SID': 'g.a0006AhOtX3iULiSXhrbarRuZ9qUbte7te9KCwL1uZpYiaebiqe5qQ6Q9yH3PknRlL8E4U6RlQACgYKAZASARISFQHGX2MinDmWwyszagx3CvfEqyc5sxoVAUF8yKos4aSDyvQGl7wKrGQNWKkv0076'
    }
    
    for attempt in range(max_retries):
        try:
            response = requests.get(url, headers=headers, cookies=cookies, timeout=15)
            if response.status_code == 200:
                with open(output_path, 'wb') as f:
                    f.write(response.content)
                return True, "OK"
            elif response.status_code == 404:
                return False, "404 Not Found"
            else:
                return False, f"HTTP {response.status_code}"
        except Exception as e:
            if attempt < max_retries - 1:
                time.sleep(1)
                continue
            return False, str(e)
    return False, "Max retries exceeded"

def download_card_images(sid, cid, output_dir, delay=0.1):
    """Télécharge les images front et back d'une carte"""
    urls = generate_image_urls(sid, cid)
    
    Path(output_dir).mkdir(parents=True, exist_ok=True)
    
    results = {'front': None, 'back': None}
    
    for img_type, url in urls.items():
        filename = os.path.basename(url)
        output_path = os.path.join(output_dir, filename)
        
        # Skip si déjà téléchargé
        if os.path.exists(output_path):
            results[img_type] = ('exists', output_path)
            continue
        
        success, message = download_image(url, output_path)
        
        if success:
            results[img_type] = ('success', output_path)
        else:
            results[img_type] = ('failed', message)
        
        # Petit délai pour ne pas surcharger le serveur
        time.sleep(delay)
    
    return results

def download_all_cards(cids_dict, output_dir="images", delay=0.1, max_workers=3):
    """
    Télécharge toutes les cartes
    
    Args:
        cids_dict: {cid: sid}
        output_dir: dossier de sortie
        delay: délai entre téléchargements (secondes)
        max_workers: nombre de threads parallèles
    """
    print("🎯 TCDB Direct Image Downloader\n")
    print(f"📋 {len(cids_dict)} cartes à télécharger")
    print(f"📁 Dossier: {output_dir}/")
    print(f"🧵 Threads: {max_workers}")
    print(f"⏱️  Délai: {delay}s entre téléchargements\n")
    print("="*60)
    
    stats = {
        'front_success': 0,
        'front_failed': 0,
        'front_exists': 0,
        'back_success': 0,
        'back_failed': 0,
        'back_exists': 0
    }
    
    failed_cards = []
    
    # Téléchargement séquentiel (pour respecter le rate limiting)
    for i, (cid, sid) in enumerate(cids_dict.items(), 1):
        print(f"\n[{i}/{len(cids_dict)}] Card ID: {cid}")
        
        results = download_card_images(sid, cid, output_dir, delay)
        
        for img_type, (status, info) in results.items():
            if status == 'success':
                print(f"   ✅ {img_type.capitalize()}: {os.path.basename(info)}")
                stats[f'{img_type}_success'] += 1
            elif status == 'exists':
                print(f"   ⏭️  {img_type.capitalize()}: déjà téléchargé")
                stats[f'{img_type}_exists'] += 1
            else:
                print(f"   ❌ {img_type.capitalize()}: {info}")
                stats[f'{img_type}_failed'] += 1
        
        # Si les deux ont échoué, ajoute à la liste
        if (results['front'][0] == 'failed' and 
            results['back'][0] == 'failed'):
            failed_cards.append((cid, sid))
    
    # Résumé
    print("\n" + "="*60)
    print("📊 RÉSUMÉ")
    print("="*60)
    print(f"✅ Front réussis:      {stats['front_success']}")
    print(f"✅ Back réussis:       {stats['back_success']}")
    print(f"⏭️  Front déjà présents: {stats['front_exists']}")
    print(f"⏭️  Back déjà présents:  {stats['back_exists']}")
    print(f"❌ Front échoués:      {stats['front_failed']}")
    print(f"❌ Back échoués:       {stats['back_failed']}")
    print(f"📁 Dossier: {output_dir}/")
    
    total_images = stats['front_success'] + stats['back_success']
    print(f"\n🎉 Total images téléchargées: {total_images}")
    
    if failed_cards:
        print(f"\n⚠️  {len(failed_cards)} cartes complètement échouées:")
        for cid, sid in failed_cards[:10]:
            print(f"   - CID {cid}")
        if len(failed_cards) > 10:
            print(f"   ... et {len(failed_cards) - 10} autres")
    
    return stats

if __name__ == "__main__":
    import sys
    
    print("""
╔════════════════════════════════════════════════════════════╗
║       TCDB Direct Image Downloader (No Scraping)           ║
╚════════════════════════════════════════════════════════════╝

USAGE:
  python3 tcdb_direct_download.py <checklist.html> [options]
  python3 tcdb_direct_download.py urls <url_file.txt> [options]

OPTIONS:
  --delay <seconds>     Délai entre téléchargements (défaut: 0.1)
  --output <dir>        Dossier de sortie (défaut: images/)

EXEMPLES:
  # Depuis un checklist HTML
  python3 tcdb_direct_download.py 2025-26_series1.html
  
  # Depuis un fichier d'URLs
  python3 tcdb_direct_download.py urls card_urls_to_visit.txt
  
  # Avec délai personnalisé
  python3 tcdb_direct_download.py 2025-26_series1.html --delay 0.5
""")
    
    if len(sys.argv) < 2:
        sys.exit(1)
    
    # Parse arguments
    input_file = sys.argv[1]
    mode = "checklist"
    
    if input_file == "urls" and len(sys.argv) > 2:
        mode = "urls"
        input_file = sys.argv[2]
        start_idx = 3
    else:
        start_idx = 2
    
    # Options
    delay = 0.1
    output_dir = "images"
    
    i = start_idx
    while i < len(sys.argv):
        if sys.argv[i] == "--delay" and i + 1 < len(sys.argv):
            delay = float(sys.argv[i + 1])
            i += 2
        elif sys.argv[i] == "--output" and i + 1 < len(sys.argv):
            output_dir = sys.argv[i + 1]
            i += 2
        else:
            i += 1
    
    # Extrait les CIDs
    if mode == "urls":
        print(f"📋 Lecture du fichier d'URLs: {input_file}")
        cids_dict = extract_cids_from_url_file(input_file)
    else:
        print(f"📋 Lecture du checklist: {input_file}")
        cids_dict = extract_cids_from_checklist(input_file)
    
    if not cids_dict:
        print("❌ Aucun CID trouvé!")
        sys.exit(1)
    
    # Lance le téléchargement
    download_all_cards(cids_dict, output_dir, delay)
    
    print("\n✅ Terminé!")
