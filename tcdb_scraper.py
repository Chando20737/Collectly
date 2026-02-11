#!/usr/bin/env python3
"""
TCDB Image Scraper (Poli)
Complète les images manquantes depuis TCDB.com
Rate limiting + rotation User-Agent pour éviter les blocages
"""

import json
import requests
import os
import time
from pathlib import Path
import csv
import random
from bs4 import BeautifulSoup

# CONFIG
TCDB_JSON = "tcdb_sets.json"
CSV_INPUT = "downloaded_cards.csv"  # Généré par eBay script
OUTPUT_DIR = "card_images"
DELAY_MIN = 2  # secondes minimum entre requêtes
DELAY_MAX = 5  # secondes maximum (randomisé)
MAX_RETRIES = 3

# User-Agents pour rotation
USER_AGENTS = [
    'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36',
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
    'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36'
]

Path(OUTPUT_DIR).mkdir(exist_ok=True)

def load_tcdb_sets(filepath):
    with open(filepath, 'r', encoding='utf-8') as f:
        return json.load(f)['sets']

def load_downloaded_cards(csv_path):
    """Charge la liste des cartes déjà téléchargées via eBay"""
    downloaded = set()
    if not os.path.exists(csv_path):
        return downloaded
    
    with open(csv_path, 'r', encoding='utf-8') as f:
        reader = csv.DictReader(f)
        for row in reader:
            if int(row['image_count']) > 0:
                key = f"{row['set']}_{row['number']}"
                downloaded.add(key)
    
    return downloaded

def get_tcdb_set_id(set_name):
    """
    Cherche l'ID TCDB d'un set
    Ex: "2025-26 Upper Deck Series 1" → ID du set sur TCDB
    """
    # TCDB utilise des URLs comme: /ViewSet.cfm/sid/XXXX
    # On devrait faire une recherche, mais pour simplifier,
    # on va utiliser une approche basée sur le nom
    
    # Cette fonction nécessiterait d'avoir mappé les noms de sets
    # à leurs IDs TCDB. Pour l'instant, retourne None
    # TODO: Implémenter recherche TCDB ou mapping manuel
    return None

def scrape_tcdb_card_image(set_id, card_number):
    """
    Scrape l'image d'une carte depuis TCDB
    """
    if not set_id:
        return None
    
    # URL pattern TCDB: /ViewCard.cfm?s=SETID&c=CARDNUMBER
    url = f"https://www.tcdb.com/ViewCard.cfm?s={set_id}&c={card_number}"
    
    headers = {
        'User-Agent': random.choice(USER_AGENTS),
        'Accept': 'text/html,application/xhtml+xml',
        'Accept-Language': 'en-US,en;q=0.9',
        'Referer': 'https://www.tcdb.com/'
    }
    
    try:
        time.sleep(random.uniform(DELAY_MIN, DELAY_MAX))
        
        response = requests.get(url, headers=headers, timeout=15)
        response.raise_for_status()
        
        soup = BeautifulSoup(response.text, 'html.parser')
        
        # TCDB affiche les images dans des tags <img> avec class="card-image" (à vérifier)
        # Cette sélection peut nécessiter des ajustements selon la structure HTML actuelle
        img_tag = soup.find('img', {'class': 'card-front'}) or soup.find('img', {'id': 'cardImage'})
        
        if img_tag and img_tag.get('src'):
            img_url = img_tag['src']
            if not img_url.startswith('http'):
                img_url = f"https://www.tcdb.com{img_url}"
            return img_url
        
        return None
        
    except requests.exceptions.HTTPError as e:
        if e.response.status_code == 429:
            print("      ⚠️  Rate limited! Attente 60 secondes...")
            time.sleep(60)
        return None
    except Exception as e:
        print(f"      ❌ Erreur: {e}")
        return None

def download_image(url, filepath):
    """Télécharge une image"""
    try:
        headers = {'User-Agent': random.choice(USER_AGENTS)}
        response = requests.get(url, headers=headers, timeout=10, stream=True)
        response.raise_for_status()
        
        with open(filepath, 'wb') as f:
            for chunk in response.iter_content(8192):
                f.write(chunk)
        
        return True
    except Exception as e:
        print(f"      ❌ Download failed: {e}")
        return False

def safe_name(text):
    for c in '<>:"/\\|?*':
        text = text.replace(c, '-')
    return text[:100]

def main():
    print("🕷️  TCDB Scraper (Poli)")
    print("═" * 60)
    print("⚠️  ATTENTION: Scraping avec rate limiting")
    print("   Temps estimé: 5-10 jours pour 50K cartes")
    print("   Utiliser UNIQUEMENT pour compléter les trous eBay")
    print("═" * 60)
    
    # Charger les sets
    print(f"\n📂 Chargement {TCDB_JSON}...")
    sets = load_tcdb_sets(TCDB_JSON)
    print(f"✅ {len(sets)} sets")
    
    # Charger les cartes déjà téléchargées
    print(f"📂 Chargement {CSV_INPUT}...")
    already_downloaded = load_downloaded_cards(CSV_INPUT)
    print(f"✅ {len(already_downloaded)} cartes déjà téléchargées")
    
    # Statistiques
    total_cards = 0
    missing_cards = 0
    scraped = 0
    failed = 0
    
    # Parcourir les sets
    for set_name, data in sets.items():
        print(f"\n📦 {set_name}")
        cards = data.get('cards', {})
        
        for num, player in cards.items():
            total_cards += 1
            key = f"{set_name}_{num}"
            
            # Skip si déjà téléchargé via eBay
            if key in already_downloaded:
                continue
            
            missing_cards += 1
            print(f"  🔍 [{total_cards}] {player} #{num}...", end=' ')
            
            # TODO: Obtenir set_id depuis mapping
            # Pour l'instant, on ne peut pas scraper sans les IDs
            set_id = get_tcdb_set_id(set_name)
            
            if not set_id:
                print("❌ Set ID inconnu")
                failed += 1
                continue
            
            # Scraper l'image
            img_url = scrape_tcdb_card_image(set_id, num)
            
            if not img_url:
                print("❌ Pas trouvé")
                failed += 1
                continue
            
            # Télécharger
            year = set_name.split()[0] if '-' in set_name else ""
            filename = f"{year}_{safe_name(set_name)}_{safe_name(num)}_tcdb.jpg"
            filepath = os.path.join(OUTPUT_DIR, filename)
            
            if download_image(img_url, filepath):
                print(f"✅")
                scraped += 1
            else:
                print(f"❌")
                failed += 1
            
            # Progress
            if total_cards % 50 == 0:
                print(f"\n📊 Progress: {scraped} scrapées, {failed} échecs")
    
    # Résumé
    print("\n" + "═" * 60)
    print("📊 RÉSUMÉ FINAL")
    print("═" * 60)
    print(f"✅ Cartes totales: {total_cards}")
    print(f"📊 Manquantes après eBay: {missing_cards}")
    print(f"✅ Scrapées TCDB: {scraped}")
    print(f"❌ Échecs: {failed}")
    print(f"📁 Dossier: {OUTPUT_DIR}/")
    print("═" * 60)
    
    print("\n⚠️  NOTE: Ce script nécessite un mapping des Set IDs TCDB")
    print("   Pour l'instant, il ne peut pas fonctionner sans ce mapping")

if __name__ == "__main__":
    main()
