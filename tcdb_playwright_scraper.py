#!/usr/bin/env python3
"""
TCDB Image Scraper avec Playwright
Automatise la visite des pages de cartes et télécharge les images
"""

import os
import time
import re
from pathlib import Path
from playwright.sync_api import sync_playwright
import requests

def extract_card_links_from_html(html_file):
    """Extrait les URLs de cartes depuis un checklist HTML"""
    with open(html_file, 'r', encoding='utf-8') as f:
        content = f.read()
    
    pattern = r'ViewCard\.cfm/sid/(\d+)/cid/(\d+)/[^"?]*'
    matches = re.findall(pattern, content)
    
    unique_cards = {}
    for sid, cid in matches:
        unique_cards[cid] = (sid, cid)
    
    urls = []
    for cid, (sid, _) in unique_cards.items():
        url = f"https://www.tcdb.com/ViewCard.cfm/sid/{sid}/cid/{cid}"
        urls.append((cid, url))
    
    return urls

def download_image(url, output_path):
    """Télécharge une image"""
    try:
        response = requests.get(url, timeout=10)
        if response.status_code == 200:
            with open(output_path, 'wb') as f:
                f.write(response.content)
            return True
    except Exception as e:
        print(f"   ❌ Erreur download: {e}")
    return False

def scrape_card_images(url, output_dir, delay=3):
    """
    Scrape une page de carte avec Playwright
    Retourne les chemins des images téléchargées
    """
    with sync_playwright() as p:
        # Lance le navigateur (headless=False pour voir, True pour invisible)
        browser = p.chromium.launch(headless=True)
        context = browser.new_context(
            user_agent='Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'
        )
        page = context.new_page()
        
        try:
            # Visite la page
            page.goto(url, wait_until="domcontentloaded", timeout=60000)
            
            # Attend un peu pour être sûr que tout est chargé
            time.sleep(2)
            
            # Extrait les URLs d'images depuis les meta tags og:image
            image_urls = []
            
            # Cherche les meta property="og:image"
            meta_images = page.locator('meta[property="og:image"]').all()
            for meta in meta_images:
                content = meta.get_attribute('content')
                if content and 'Images/Cards/Hockey' in content:
                    if not content.startswith('http'):
                        content = f"https://www.tcdb.com{content}"
                    image_urls.append(content)
            
            # Fallback: cherche aussi dans les balises img
            if not image_urls:
                img_elements = page.locator('img[src*="Images/Cards/Hockey"]').all()
                for img in img_elements:
                    src = img.get_attribute('src')
                    if src:
                        if not src.startswith('http'):
                            src = f"https://www.tcdb.com{src}"
                        image_urls.append(src)
            
            # Dernier fallback: regex sur le HTML
            if not image_urls:
                pattern = r'https://www\.tcdb\.com/Images/Cards/Hockey/[^"]+\.(?:jpg|png)'
                page_content = page.content()
                matches = re.findall(pattern, page_content)
                image_urls = list(set(matches))
            
            if not image_urls:
                print(f"   ⚠️  Aucune image trouvée")
                browser.close()
                return []
            
            # Sépare front et back
            front_url = next((url for url in image_urls if 'Fr.' in url), None)
            back_url = next((url for url in image_urls if 'Bk.' in url), None)
            
            # Télécharge les images
            Path(output_dir).mkdir(parents=True, exist_ok=True)
            downloaded = []
            
            for img_url, img_type in [(front_url, 'Front'), (back_url, 'Back')]:
                if not img_url:
                    continue
                
                filename = os.path.basename(img_url)
                output_path = os.path.join(output_dir, filename)
                
                print(f"   📥 {img_type}: {filename}")
                
                if download_image(img_url, output_path):
                    print(f"   ✅ Téléchargé")
                    downloaded.append(output_path)
                else:
                    print(f"   ❌ Échec")
            
            # Délai avant la prochaine requête
            time.sleep(delay)
            
        except Exception as e:
            print(f"   ❌ Erreur: {e}")
            downloaded = []
        finally:
            browser.close()
        
        return downloaded

def scrape_from_checklist(checklist_html, output_dir="images", delay=3, max_cards=None):
    """
    Scrape toutes les cartes depuis un checklist HTML
    """
    print("🎯 TCDB Playwright Scraper\n")
    
    # Extrait les URLs
    print(f"📋 Lecture du checklist: {checklist_html}")
    card_urls = extract_card_links_from_html(checklist_html)
    
    total_cards = len(card_urls)
    if max_cards:
        card_urls = card_urls[:max_cards]
        print(f"⚠️  Limité aux {max_cards} premières cartes (pour test)\n")
    
    print(f"✅ {len(card_urls)} cartes à scraper\n")
    print(f"⏱️  Temps estimé: ~{len(card_urls) * delay // 60} minutes\n")
    print("="*60)
    
    # Scrape chaque carte
    all_downloaded = []
    failed = []
    
    for i, (cid, url) in enumerate(card_urls, 1):
        print(f"\n[{i}/{len(card_urls)}] Card ID: {cid}")
        print(f"🔗 {url}")
        
        downloaded = scrape_card_images(url, output_dir, delay)
        
        if downloaded:
            all_downloaded.extend(downloaded)
        else:
            failed.append((cid, url))
    
    # Résumé
    print("\n" + "="*60)
    print("📊 RÉSUMÉ")
    print("="*60)
    print(f"✅ Images téléchargées: {len(all_downloaded)}")
    print(f"❌ Échecs: {len(failed)}")
    print(f"📁 Dossier: {output_dir}/")
    
    if failed:
        print(f"\n⚠️  Cartes échouées:")
        for cid, url in failed[:10]:
            print(f"   - {cid}: {url}")
        if len(failed) > 10:
            print(f"   ... et {len(failed) - 10} autres")
    
    print("\n✅ Terminé!")
    return all_downloaded

def scrape_from_url_list(url_file, output_dir="images", delay=3, max_cards=None):
    """
    Scrape depuis un fichier de URLs (card_urls_to_visit.txt)
    """
    print("🎯 TCDB Playwright Scraper\n")
    
    with open(url_file, 'r') as f:
        urls = [line.strip() for line in f if line.strip()]
    
    if max_cards:
        urls = urls[:max_cards]
        print(f"⚠️  Limité aux {max_cards} premières cartes (pour test)\n")
    
    print(f"✅ {len(urls)} cartes à scraper")
    print(f"⏱️  Temps estimé: ~{len(urls) * delay // 60} minutes\n")
    print("="*60)
    
    all_downloaded = []
    failed = []
    
    for i, url in enumerate(urls, 1):
        # Extrait le cid de l'URL
        match = re.search(r'/cid/(\d+)', url)
        cid = match.group(1) if match else "unknown"
        
        print(f"\n[{i}/{len(urls)}] Card ID: {cid}")
        print(f"🔗 {url}")
        
        downloaded = scrape_card_images(url, output_dir, delay)
        
        if downloaded:
            all_downloaded.extend(downloaded)
        else:
            failed.append((cid, url))
    
    # Résumé
    print("\n" + "="*60)
    print("📊 RÉSUMÉ")
    print("="*60)
    print(f"✅ Images téléchargées: {len(all_downloaded)}")
    print(f"❌ Échecs: {len(failed)}")
    print(f"📁 Dossier: {output_dir}/")
    
    if failed:
        print(f"\n⚠️  Cartes échouées:")
        for cid, url in failed[:10]:
            print(f"   - {cid}: {url}")
    
    print("\n✅ Terminé!")
    return all_downloaded

if __name__ == "__main__":
    import sys
    
    print("""
╔════════════════════════════════════════════════════════════╗
║          TCDB Playwright Image Scraper                     ║
╚════════════════════════════════════════════════════════════╝

USAGE:
  python3 tcdb_playwright_scraper.py <checklist.html> [options]
  python3 tcdb_playwright_scraper.py urls <url_file.txt> [options]

OPTIONS:
  --delay <seconds>     Délai entre requêtes (défaut: 3)
  --max <number>        Limite le nombre de cartes (pour test)
  --output <dir>        Dossier de sortie (défaut: images/)

EXEMPLES:
  # Scraper depuis un checklist HTML
  python3 tcdb_playwright_scraper.py 2025-26_series1.html
  
  # Scraper depuis un fichier d'URLs
  python3 tcdb_playwright_scraper.py urls card_urls_to_visit.txt
  
  # Test avec 5 cartes et délai de 5 secondes
  python3 tcdb_playwright_scraper.py 2025-26_series1.html --max 5 --delay 5

INSTALLATION:
  pip install playwright requests
  playwright install chromium
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
    delay = 3
    max_cards = None
    output_dir = "images"
    
    i = start_idx
    while i < len(sys.argv):
        if sys.argv[i] == "--delay" and i + 1 < len(sys.argv):
            delay = int(sys.argv[i + 1])
            i += 2
        elif sys.argv[i] == "--max" and i + 1 < len(sys.argv):
            max_cards = int(sys.argv[i + 1])
            i += 2
        elif sys.argv[i] == "--output" and i + 1 < len(sys.argv):
            output_dir = sys.argv[i + 1]
            i += 2
        else:
            i += 1
    
    # Lance le scraping
    if mode == "urls":
        scrape_from_url_list(input_file, output_dir, delay, max_cards)
    else:
        scrape_from_checklist(input_file, output_dir, delay, max_cards)
