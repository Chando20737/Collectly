#!/usr/bin/env python3
"""Test eBay API"""
import requests

EBAY_APP_ID = "EricChan-Collectl-PRD-db452d056-616d69ca"

def test():
    print("🧪 Test eBay API\n")
    
    if EBAY_APP_ID == "YOUR_EBAY_APP_ID":
        print("❌ Configure EBAY_APP_ID d'abord")
        return
    
    print(f"🔑 App ID: {EBAY_APP_ID[:15]}...{EBAY_APP_ID[-10:]}\n")
    
    url = "https://svcs.ebay.com/services/search/FindingService/v1"
    params = {
        'OPERATION-NAME': 'findItemsAdvanced',
        'SERVICE-VERSION': '1.0.0',
        'SECURITY-APPNAME': EBAY_APP_ID,
        'RESPONSE-DATA-FORMAT': 'JSON',
        'keywords': 'Connor McDavid hockey card',
        'categoryId': '261328',
        'paginationInput.entriesPerPage': '3'
    }
    
    print("🔍 Recherche: 'Connor McDavid hockey card'")
    
    try:
        r = requests.get(url, params=params, timeout=10)
        print(f"📡 Status: {r.status_code}")
        
        if r.status_code != 200:
            print(f"❌ HTTP Error: {r.text[:200]}")
            return
        
        data = r.json()
        result = data.get('findItemsAdvancedResponse', [{}])[0]
        ack = result.get('ack', [None])[0]
        
        print(f"✅ ACK: {ack}")
        
        if ack != 'Success':
            print(f"❌ API Error: {result.get('errorMessage', 'Unknown')}")
            return
        
        items = result.get('searchResult', [{}])[0].get('item', [])
        print(f"✅ Résultats: {len(items)}\n")
        
        if items:
            print("📋 Top 3:")
            for i, item in enumerate(items[:3], 1):
                title = item.get('title', [''])[0]
                img = item.get('galleryURL', [''])[0]
                print(f"   {i}. {title[:50]}...")
                print(f"      {img}\n")
            print("✅ L'API fonctionne!")
        else:
            print("⚠️  Aucun résultat (normal si recherche trop spécifique)")
        
    except Exception as e:
        print(f"❌ Exception: {e}")

if __name__ == "__main__":
    test()
