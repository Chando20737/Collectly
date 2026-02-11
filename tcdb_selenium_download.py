#!/usr/bin/env python3
"""
TCDB Image Downloader avec Selenium
Utilise ton navigateur Chrome pour télécharger les images
"""

import os
import re
import time
from pathlib import Path
from selenium import webdriver
from selenium.webdriver.chrome.service import Service
from selenium.webdriver.chrome.options import Options
from selenium.webdriver.common.by import By
import base64

def extract_cids_from_checklist(html_file):
    """Extrait les CIDs depuis un checklist HTML"""
    with open(html_file, 'r', encoding='utf-8') as f:
        content = f.read()
    
    pattern = r'ViewCard\.cfm/sid/(\d+)/cid/(\d+)'
    matches = re.findall(pattern, content)
    
    unique = {}
    for sid, cid in matches:
        unique[cid] = sid
    
    return unique

def generate_image_urls(sid, cid):
    """Génère les URLs front et back pour une carte"""
    base = f"https://www.tcdb.com/Images/Cards/Hockey/{sid}/{sid}-{cid}"
    return {
        'front': f"{base}Fr.jpg",
        'back': f"{base}Bk.jpg"
    }

def download_image_with_selenium(driver, url, output_path):
    """Télécharge une image via Selenium"""
    try:
        # Charge l'image dans le navigateur
        driver.get(url)
        time.sleep(0.5)
        
        # Vérifie si c'est une vraie image
        if "404" in driver.title or "Error" in driver.title:
            return False, "404"
        
        # Execute JavaScript pour récupérer l'image en base64
        script = """
        var img = document.querySelector('img');
        if (!img) {
            var imgs = document.getElementsByTagName('img');
            img = imgs.length > 0 ? imgs[0] : null;
        }
        if (img) {
            var canvas = document.createElement('canvas');
            canvas.width = img.naturalWidth;
            canvas.height = img.naturalHeight;
            var ctx = canvas.getContext('2d');
            ctx.drawImage(img, 0, 0);
            return canvas.toDataURL('image/jpeg');
        }
        return null;
        """
        
        image_data = driver.execute_script(script)
        
        if not image_data:
            return False, "No image found"
        
        # Décode base64 et sauvegarde
        image_bytes = base64.b64decode(image_data.split(',')[1])
        with open(output_path, 'wb') as f:
            f.write(image_bytes)
        
        return True, "OK"
        
    except Exception as e:
        return False, str(e)

def download_all_cards_selenium(cids_dict, output_dir="images", delay=1):
    """Télécharge toutes les cartes avec Selenium"""
    
    print("🎯 TCDB Selenium Image Downloader\n")
    print(f"📋 {len(cids_dict)} cartes à télécharger")
    print(f"📁 Dossier: {output_dir}/")
    print(f"⏱️  Délai: {delay}s entre téléchargements\n")
    print("🌐 Lancement de Chrome...\n")
    
    # Configure Chrome
    chrome_options = Options()
    # chrome_options.add_argument('--headless')  # Décommente pour invisible
    chrome_options.add_argument('--disable-gpu')
    chrome_options.add_argument('--no-sandbox')
    
    # Lance le navigateur
    driver = webdriver.Chrome(options=chrome_options)
    
    Path(output_dir).mkdir(parents=True, exist_ok=True)
    
    stats = {
        'front_success': 0,
        'front_failed': 0,
        'front_exists': 0,
        'back_success': 0,
        'back_failed': 0,
        'back_exists': 0
    }
    
    failed_cards = []
    
    print("="*60)
    
    try:
        for i, (cid, sid) in enumerate(cids_dict.items(), 1):
            print(f"\n[{i}/{len(cids_dict)}] Card ID: {cid}")
            
            urls = generate_image_urls(sid, cid)
            card_failed = True
            
            for img_type, url in urls.items():
                filename = os.path.basename(url)
                output_path = os.path.join(output_dir, filename)
                
                # Skip si déjà téléchargé
                if os.path.exists(output_path):
                    print(f"   ⏭️  {img_type.capitalize()}: déjà téléchargé")
                    stats[f'{img_type}_exists'] += 1
                    card_failed = False
                    continue
                
                success, message = download_image_with_selenium(driver, url, output_path)
                
                if success:
                    print(f"   ✅ {img_type.capitalize()}: {filename}")
                    stats[f'{img_type}_success'] += 1
                    card_failed = False
                else:
                    print(f"   ❌ {img_type.capitalize()}: {message}")
                    stats[f'{img_type}_failed'] += 1
                
                time.sleep(delay)
            
            if card_failed:
                failed_cards.append((cid, sid))
    
    finally:
        driver.quit()
    
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
    
    total_images = stats['front_success'] + stats['back_success']
    print(f"\n🎉 Total images téléchargées: {total_images}")
    
    if failed_cards:
        print(f"\n⚠️  {len(failed_cards)} cartes complètement échouées")
    
    return stats

if __name__ == "__main__":
    import sys
    
    print("""
╔════════════════════════════════════════════════════════════╗
║         TCDB Selenium Image Downloader                     ║
╚════════════════════════════════════════════════════════════╝

Utilise Chrome avec tes cookies pour télécharger les images.

USAGE:
  python3 tcdb_selenium_download.py <checklist.html> [--delay <seconds>]

INSTALLATION:
  pip install selenium
  
  Pour Chrome:
  brew install chromedriver

EXEMPLE:
  python3 tcdb_selenium_download.py 2025-26_series1.html --delay 1
""")
    
    if len(sys.argv) < 2:
        sys.exit(1)
    
    checklist_file = sys.argv[1]
    delay = 1
    
    if '--delay' in sys.argv:
        idx = sys.argv.index('--delay')
        if idx + 1 < len(sys.argv):
            delay = float(sys.argv[idx + 1])
    
    print(f"📋 Lecture du checklist: {checklist_file}")
    cids_dict = extract_cids_from_checklist(checklist_file)
    
    if not cids_dict:
        print("❌ Aucun CID trouvé!")
        sys.exit(1)
    
    download_all_cards_selenium(cids_dict, delay=delay)
    
    print("\n✅ Terminé!")
