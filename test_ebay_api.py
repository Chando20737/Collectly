#!/usr/bin/env python3
"""
Test de l'API eBay - Debug
"""

import requests
import json

# ========================================
# CONFIGURE TON APP ID ICI
# ========================================
EBAY_APP_ID = "EricChan-Collectl-PRD-db452d056-616d69ca"  # ← Remplace ici !

def test_ebay_api():
    """
    Test simple de l'API eBay avec une recherche basique
    """
    
    print("=" * 80)
    print("TEST DE L'API EBAY")
    print("=" * 80)
    
    # Test 1 : Recherche simple
    print("\n📋 Test 1: Recherche simple 'Connor McDavid'")
    print("-" * 80)
    
    url = "https://svcs.ebay.com/services/search/FindingService/v1"
    
    params = {
        "OPERATION-NAME": "findItemsByKeywords",
        "SERVICE-VERSION": "1.0.0",
        "SECURITY-APPNAME": EBAY_APP_ID,
        "RESPONSE-DATA-FORMAT": "JSON",
        "REST-PAYLOAD": "",
        "keywords": "Connor McDavid hockey card",
        "paginationInput.entriesPerPage": "1",
    }
    
    try:
        print(f"🔗 URL: {url}")
        print(f"🔑 App ID: {EBAY_APP_ID[:20]}..." if len(EBAY_APP_ID) > 20 else f"🔑 App ID: {EBAY_APP_ID}")
        print("\n⏳ Envoi de la requête...")
        
        response = requests.get(url, params=params, timeout=10)
        
        print(f"📊 Status Code: {response.status_code}")
        
        if response.status_code == 200:
            print("✅ Requête réussie !")
            
            data = response.json()
            
            # Afficher la réponse (prettified)
            print("\n📄 Réponse JSON (extrait):")
            print(json.dumps(data, indent=2)[:500])
            
            # Vérifier s'il y a des erreurs
            if "errorMessage" in data:
                print("\n❌ ERREUR DANS LA RÉPONSE:")
                print(json.dumps(data["errorMessage"], indent=2))
                return False
            
            # Vérifier s'il y a des résultats
            try:
                search_result = data["findItemsByKeywordsResponse"][0]["searchResult"][0]
                count = search_result.get("@count", "0")
                
                print(f"\n✅ Résultats trouvés: {count}")
                
                if int(count) > 0:
                    items = search_result.get("item", [])
                    if items and len(items) > 0:
                        item = items[0]
                        title = item.get("title", ["N/A"])[0]
                        image_url = item.get("galleryURL", ["N/A"])[0]
                        
                        print(f"\n🎴 Premier résultat:")
                        print(f"  Titre: {title}")
                        print(f"  Image: {image_url}")
                        
                        return True
                else:
                    print("\n⚠️  Aucun résultat trouvé (mais l'API fonctionne)")
                    return True
                    
            except (KeyError, IndexError) as e:
                print(f"\n❌ Erreur de parsing: {e}")
                print("Structure inattendue de la réponse")
                return False
        
        else:
            print(f"❌ Erreur HTTP: {response.status_code}")
            print(f"📄 Réponse: {response.text[:500]}")
            return False
            
    except requests.exceptions.Timeout:
        print("❌ Timeout - L'API eBay ne répond pas")
        return False
    except requests.exceptions.RequestException as e:
        print(f"❌ Erreur de connexion: {e}")
        return False
    except Exception as e:
        print(f"❌ Erreur inattendue: {e}")
        return False

def test_image_download():
    """
    Test 2: Télécharger une image de test
    """
    print("\n" + "=" * 80)
    print("TEST 2: TÉLÉCHARGEMENT D'IMAGE")
    print("=" * 80)
    
    # URL d'image de test
    test_image_url = "https://i.ebayimg.com/images/g/test/s-l1600.jpg"
    
    try:
        print(f"\n🔗 Test image URL: {test_image_url}")
        print("⏳ Téléchargement...")
        
        response = requests.get(test_image_url, timeout=10)
        
        if response.status_code == 200:
            print(f"✅ Image téléchargée ! Taille: {len(response.content)} bytes")
            
            # Sauvegarder pour vérifier
            with open("test_image.jpg", "wb") as f:
                f.write(response.content)
            print("💾 Sauvegardée dans: test_image.jpg")
            
            return True
        else:
            print(f"❌ Erreur: {response.status_code}")
            return False
            
    except Exception as e:
        print(f"❌ Erreur: {e}")
        return False

def diagnose_app_id():
    """
    Diagnostiquer les problèmes possibles avec l'App ID
    """
    print("\n" + "=" * 80)
    print("DIAGNOSTIC DE L'APP ID")
    print("=" * 80)
    
    if EBAY_APP_ID == "YOUR_EBAY_APP_ID":
        print("\n❌ PROBLÈME: Tu n'as pas configuré ton EBAY_APP_ID !")
        print("\n📝 Comment le trouver:")
        print("  1. Va dans ton code Swift (EbayImageSearch.swift)")
        print("  2. Cherche 'SECURITY-APPNAME' ou 'appId'")
        print("  3. Copie la valeur ici")
        print("\n  Exemple: 'EricChan-Collectly-PRD-a1b2c3d4'")
        return False
    
    print(f"\n✅ App ID configuré: {EBAY_APP_ID}")
    
    # Vérifier le format
    if len(EBAY_APP_ID) < 10:
        print("⚠️  Warning: App ID semble trop court")
        return False
    
    if not any(char in EBAY_APP_ID for char in ['-', '_']):
        print("⚠️  Warning: App ID ne contient pas de tirets (format inhabituel)")
    
    return True

# ============================================================================
# MAIN
# ============================================================================

if __name__ == "__main__":
    print("\n🔍 OUTIL DE DEBUG POUR L'API EBAY\n")
    
    # Étape 1: Vérifier l'App ID
    if not diagnose_app_id():
        print("\n❌ Configure ton EBAY_APP_ID dans le script avant de continuer!")
        exit(1)
    
    # Étape 2: Tester l'API
    api_works = test_ebay_api()
    
    # Étape 3: Tester le téléchargement d'images
    download_works = test_image_download()
    
    # Résumé
    print("\n" + "=" * 80)
    print("RÉSUMÉ")
    print("=" * 80)
    
    if api_works and download_works:
        print("✅ Tout fonctionne ! Tu peux lancer download_reference_images.py")
    elif api_works:
        print("✅ API fonctionne")
        print("❌ Téléchargement d'images échoue")
        print("\n💡 Suggestion: Vérifie ta connexion internet")
    else:
        print("❌ API ne fonctionne pas")
        print("\n💡 Suggestions:")
        print("  1. Vérifie que ton EBAY_APP_ID est correct")
        print("  2. Va sur https://developer.ebay.com pour vérifier ton compte")
        print("  3. Vérifie que ton App ID n'a pas expiré")
        print("  4. Essaie de régénérer un nouveau App ID")
