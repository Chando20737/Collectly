#!/usr/bin/env python3
"""
Télécharger les images de référence pour Computer Vision
Via eBay Image Search (même API que ton app utilise déjà)
"""

import json
import requests
import time
import os
from pathlib import Path

# Configuration
REFERENCE_IMAGES_DIR = "reference_images"
TCDB_SETS_FILE = "tcdb_sets.json"

# eBay API config (utilise les mêmes credentials que ton app)
EBAY_APP_ID = "EricChan-Collectl-PRD-db452d056-616d69ca"  # Remplace avec ton App ID

def download_card_image(player_name, card_number, set_name, year, output_path):
    """
    Télécharge l'image d'une carte via eBay Image Search
    """
    
    # Construire la query eBay
    query = f"{player_name} {card_number} {set_name} {year}"
    
    url = "https://svcs.ebay.com/services/search/FindingService/v1"
    params = {
        "OPERATION-NAME": "findItemsByKeywords",
        "SERVICE-VERSION": "1.0.0",
        "SECURITY-APPNAME": EBAY_APP_ID,
        "RESPONSE-DATA-FORMAT": "JSON",
        "REST-PAYLOAD": "",
        "keywords": query,
        "paginationInput.entriesPerPage": "1",
        "itemFilter(0).name": "ListingType",
        "itemFilter(0).value": "FixedPrice",
    }
    
    try:
        response = requests.get(url, params=params, timeout=10)
        data = response.json()
        
        # Extraire l'image URL
        items = data.get("findItemsByKeywordsResponse", [{}])[0].get("searchResult", [{}])[0].get("item", [])
        
        if items and len(items) > 0:
            image_url = items[0].get("galleryURL", [None])[0]
            
            if image_url:
                # Télécharger l'image
                img_response = requests.get(image_url, timeout=10)
                
                if img_response.status_code == 200:
                    with open(output_path, 'wb') as f:
                        f.write(img_response.content)
                    return True
        
        return False
        
    except Exception as e:
        print(f"  ❌ Erreur: {e}")
        return False

def download_all_reference_images():
    """
    Télécharge les images de référence pour toutes les cartes
    """
    
    # Créer le dossier
    Path(REFERENCE_IMAGES_DIR).mkdir(exist_ok=True)
    
    # Charger la base TCDB
    with open(TCDB_SETS_FILE, 'r') as f:
        data = json.load(f)
    
    sets_data = data.get('sets', {})
    
    total_cards = 0
    downloaded = 0
    skipped = 0
    failed = 0
    
    print("=" * 80)
    print("TÉLÉCHARGEMENT DES IMAGES DE RÉFÉRENCE")
    print("=" * 80)
    
    for set_name, set_info in sets_data.items():
        if not isinstance(set_info, dict) or 'cards' not in set_info:
            continue
        
        cards = set_info['cards']
        
        # Skip les inserts (moins de 50 cartes)
        if len(cards) < 50:
            continue
        
        print(f"\n📦 {set_name} ({len(cards)} cartes)")
        
        # Extraire l'année
        year = None
        for y in ['2025-26', '2024-25', '2023-24', '2022-23', '2021-22', '2020-21']:
            if y in set_name:
                year = y
                break
        
        if not year:
            print("  ⚠️  Année non trouvée, skip")
            continue
        
        for card_num, player_name in cards.items():
            total_cards += 1
            
            # Nom du fichier : set_year_number.jpg
            # Ex: "MVP_2025-26_232.jpg"
            safe_set_name = set_name.replace(" ", "_").replace("/", "-")
            filename = f"{safe_set_name}_{card_num}.jpg"
            filepath = os.path.join(REFERENCE_IMAGES_DIR, filename)
            
            # Skip si déjà téléchargé
            if os.path.exists(filepath):
                skipped += 1
                continue
            
            # Télécharger
            print(f"  📥 {player_name} #{card_num}...", end=" ")
            
            success = download_card_image(
                player_name=player_name,
                card_number=card_num,
                set_name=set_name,
                year=year,
                output_path=filepath
            )
            
            if success:
                downloaded += 1
                print("✅")
            else:
                failed += 1
                print("❌")
            
            # Rate limiting - 1 requête par seconde
            time.sleep(1)
            
            # Progress
            if total_cards % 50 == 0:
                print(f"\n  📊 Progress: {downloaded}/{total_cards} téléchargées, {failed} échecs\n")
    
    print("\n" + "=" * 80)
    print("RÉSUMÉ")
    print("=" * 80)
    print(f"Total cartes: {total_cards}")
    print(f"✅ Téléchargées: {downloaded}")
    print(f"⏭️  Skipped (déjà présentes): {skipped}")
    print(f"❌ Échecs: {failed}")
    print(f"\n📁 Images sauvegardées dans: {REFERENCE_IMAGES_DIR}/")

if __name__ == "__main__":
    print("\n⚠️  IMPORTANT: Configure ton EBAY_APP_ID dans le script avant de lancer!\n")
    
    choice = input("Continuer? (y/n): ")
    if choice.lower() == 'y':
        download_all_reference_images()
    else:
        print("Annulé")
