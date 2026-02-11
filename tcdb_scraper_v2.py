#!/usr/bin/env python3
"""
TCDB Scraper v2 - avec headers navigateur pour bypass 403
"""

import requests
from bs4 import BeautifulSoup
import time
import json
import re

# Headers qui simulent Chrome sur Mac
HEADERS = {
    'User-Agent': 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
    'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8',
    'Accept-Language': 'en-US,en;q=0.9,fr;q=0.8',
    'Accept-Encoding': 'gzip, deflate, br',
    'Connection': 'keep-alive',
    'Upgrade-Insecure-Requests': '1',
    'Sec-Fetch-Dest': 'document',
    'Sec-Fetch-Mode': 'navigate',
    'Sec-Fetch-Site': 'none',
    'Sec-Fetch-User': '?1',
    'Cache-Control': 'max-age=0',
}

def scrape_tcdb_set(set_id):
    """Scrape un set TCDB"""
    
    # Créer une session (garde les cookies)
    session = requests.Session()
    session.headers.update(HEADERS)
    
    # D'abord visiter la page d'accueil pour obtenir des cookies
    print("🔄 Visite de tcdb.com pour obtenir les cookies...")
    try:
        home = session.get('https://www.tcdb.com/', timeout=10)
        print(f"   Homepage: {home.status_code}")
        time.sleep(1)
    except Exception as e:
        print(f"   ⚠️ Homepage error: {e}")
    
    # Puis la page du set
    print(f"\n🔄 Visite de la page du set {set_id}...")
    try:
        viewset_url = f'https://www.tcdb.com/ViewSet.cfm/sid/{set_id}'
        viewset = session.get(viewset_url, timeout=10)
        print(f"   ViewSet: {viewset.status_code}")
        time.sleep(1)
    except Exception as e:
        print(f"   ⚠️ ViewSet error: {e}")
    
    # Maintenant le checklist
    url = f'https://www.tcdb.com/Checklist.cfm/sid/{set_id}'
    print(f"\n📋 Fetching checklist: {url}")
    
    try:
        response = session.get(url, timeout=15)
        print(f"   Status: {response.status_code}")
        
        if response.status_code == 403:
            print("\n❌ Toujours 403. TCDB a une protection anti-bot très stricte.")
            print("\n💡 Alternatives:")
            print("   1. Connecte-toi sur tcdb.com et exporte manuellement")
            print("   2. Copie le HTML source de la page et envoie-le moi")
            print("   3. Utilise un service comme ScrapingBee ou Browserless")
            return None
            
        if response.status_code != 200:
            print(f"❌ Erreur HTTP: {response.status_code}")
            return None
            
        # Parse HTML
        soup = BeautifulSoup(response.text, 'lxml')
        
        # Chercher la table des cartes
        cards = []
        
        # TCDB utilise souvent des tables avec class "tpointed"
        tables = soup.find_all('table')
        print(f"\n   Tables trouvées: {len(tables)}")
        
        for table in tables:
            rows = table.find_all('tr')
            for row in rows:
                cols = row.find_all(['td', 'th'])
                if len(cols) >= 2:
                    # Extraire numéro et nom
                    card_num = cols[0].get_text(strip=True)
                    card_name = cols[1].get_text(strip=True) if len(cols) > 1 else ""
                    
                    # Filtrer les headers et lignes vides
                    if card_num and card_name and not card_num.lower() in ['#', 'number', 'card']:
                        cards.append({
                            'number': card_num,
                            'name': card_name
                        })
        
        print(f"\n✅ Cartes trouvées: {len(cards)}")
        return cards
        
    except requests.exceptions.RequestException as e:
        print(f"❌ Erreur réseau: {e}")
        return None

def main():
    set_id = 431741  # 2024-25 Upper Deck
    
    print("="*60)
    print("TCDB SCRAPER v2 - avec simulation navigateur")
    print("="*60)
    
    cards = scrape_tcdb_set(set_id)
    
    if cards:
        # Sauvegarder en JSON
        output_file = f'tcdb_set_{set_id}.json'
        with open(output_file, 'w', encoding='utf-8') as f:
            json.dump(cards, f, indent=2, ensure_ascii=False)
        print(f"\n💾 Sauvegardé: {output_file}")
        
        # Afficher les premiers
        print("\n📋 Aperçu (10 premières):")
        for card in cards[:10]:
            print(f"   {card['number']}: {card['name']}")
    else:
        print("\n😔 Pas de données récupérées.")

if __name__ == '__main__':
    main()
