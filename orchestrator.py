#!/usr/bin/env python3
"""
Image Collection Orchestrator
Lance eBay downloader puis TCDB scraper pour maximiser la couverture
"""

import subprocess
import sys
import os

def run_script(script_name, description):
    """Lance un script Python et affiche le résultat"""
    print("\n" + "═" * 70)
    print(f"🚀 LANCEMENT: {description}")
    print("═" * 70 + "\n")
    
    try:
        result = subprocess.run(
            [sys.executable, script_name],
            check=True,
            capture_output=False
        )
        
        print(f"\n✅ {description} - TERMINÉ")
        return True
        
    except subprocess.CalledProcessError as e:
        print(f"\n❌ {description} - ÉCHEC")
        return False
    except FileNotFoundError:
        print(f"\n❌ Script introuvable: {script_name}")
        return False

def main():
    print("""
╔══════════════════════════════════════════════════════════════════════╗
║                   IMAGE COLLECTION ORCHESTRATOR                      ║
║                  Téléchargement massif d'images                      ║
╚══════════════════════════════════════════════════════════════════════╝

📋 PLAN D'EXÉCUTION:
   1️⃣  eBay API Download (rapide, légal, ~30-40K images)
   2️⃣  TCDB Scraping (lent, poli, comble les trous)

⚠️  IMPORTANT:
   - Configure EBAY_APP_ID dans ebay_downloader.py
   - Le script TCDB nécessite un mapping des Set IDs
   - Temps total estimé: 2-10 jours selon volume

""")
    
    response = input("▶️  Continuer? (y/n): ")
    if response.lower() != 'y':
        print("❌ Annulé")
        return
    
    # PHASE 1: eBay Download
    print("\n" + "🎯" * 35)
    print("PHASE 1: eBay API Download")
    print("🎯" * 35)
    
    ebay_success = run_script("ebay_downloader.py", "eBay API Download")
    
    if not ebay_success:
        print("\n⚠️  eBay download a échoué. Vérifier:")
        print("   1. EBAY_APP_ID est configuré")
        print("   2. tcdb_sets.json existe")
        print("   3. Connexion internet active")
        
        response = input("\n▶️  Continuer avec TCDB scraping quand même? (y/n): ")
        if response.lower() != 'y':
            print("❌ Arrêt")
            return
    
    # PHASE 2: TCDB Scraping (pour combler les trous)
    print("\n" + "🕷️ " * 35)
    print("PHASE 2: TCDB Scraping (Complétion)")
    print("🕷️ " * 35)
    
    print("\n⚠️  NOTE IMPORTANTE:")
    print("   Le scraper TCDB nécessite un mapping des Set IDs TCDB")
    print("   Sans ce mapping, il ne pourra pas fonctionner")
    print("   Recommandation: Utiliser UNIQUEMENT eBay pour l'instant")
    
    response = input("\n▶️  Lancer TCDB scraping? (y/n): ")
    if response.lower() == 'y':
        tcdb_success = run_script("tcdb_scraper.py", "TCDB Scraping")
    else:
        print("⏭️  TCDB scraping ignoré")
        tcdb_success = None
    
    # RÉSUMÉ FINAL
    print("\n" + "═" * 70)
    print("📊 RÉSUMÉ FINAL DE L'ORCHESTRATION")
    print("═" * 70)
    
    if ebay_success:
        print("✅ Phase 1 (eBay): SUCCÈS")
    else:
        print("❌ Phase 1 (eBay): ÉCHEC")
    
    if tcdb_success is True:
        print("✅ Phase 2 (TCDB): SUCCÈS")
    elif tcdb_success is False:
        print("❌ Phase 2 (TCDB): ÉCHEC")
    else:
        print("⏭️  Phase 2 (TCDB): IGNORÉ")
    
    print("\n📁 Vérifier le dossier: card_images/")
    print("📄 Vérifier le fichier: downloaded_cards.csv")
    print("\n🎯 PROCHAINES ÉTAPES:")
    print("   1. Vérifier la qualité des images téléchargées")
    print("   2. Upload vers Firebase Storage")
    print("   3. Générer les feature prints (VisionMatcher)")
    print("   4. Créer la base Firestore avec métadonnées")
    print("=" * 70)

if __name__ == "__main__":
    main()
