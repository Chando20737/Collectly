#!/usr/bin/env python3
"""
Importe les images TCDB dans l'app Collectly
Renomme au format: [année_]setName_cardNumber.jpg
"""

import os
import json
import shutil
from pathlib import Path

def load_tcdb_json(json_file):
    """Charge le JSON TCDB"""
    with open(json_file, 'r', encoding='utf-8') as f:
        return json.load(f)

def find_card_info(cid, tcdb_data, cid_mapping=None):
    """Trouve les infos d'une carte depuis son CID"""
    
    # Si on a un mapping CID → card_number, l'utiliser
    if cid_mapping and str(cid) in cid_mapping:
        card_number = cid_mapping[str(cid)]
        
        # Cherche dans tcdb_data par card_number
        for set_name, set_data in tcdb_data.get('sets', {}).items():
            cards = set_data.get('cards', {})
            if card_number in cards:
                return {
                    'set_name': set_name,
                    'card_number': card_number,
                    'year': ''  # Extraire de set_name si besoin
                }
    
    # Fallback: cherche par CID (ancien format)
    for set_data in tcdb_data.values():
        for card in set_data.get('cards', []):
            if str(card.get('cid')) == str(cid):
                return {
                    'set_name': set_data.get('set_name', ''),
                    'card_number': card.get('card_number', ''),
                    'year': set_data.get('year', '')
                }
    return None

def format_for_app(set_name, card_number, year):
    """Formate le nom de fichier pour l'app"""
    # Nettoie le nom du set
    safe_set = set_name.replace('/', '-').replace(' ', '_')
    
    # Format: [année_]setName_cardNumber.jpg
    if year and year.strip():
        return f"{year}_{safe_set}_{card_number}.jpg"
    else:
        return f"{safe_set}_{card_number}.jpg"

def import_tcdb_images(images_dir, tcdb_json, output_dir, simulator_path=None, cid_mapping_file=None):
    """
    Importe les images TCDB dans l'app
    
    Args:
        images_dir: dossier avec les images TCDB (ex: images/)
        tcdb_json: fichier JSON TCDB (ex: tcdb_sets.json)
        output_dir: dossier temporaire de sortie
        simulator_path: chemin vers Documents du simulateur (optionnel)
        cid_mapping_file: fichier JSON avec mapping CID → card_number (optionnel)
    """
    
    print("🎯 Import d'images TCDB dans Collectly\n")
    
    # Charge le JSON
    print(f"📋 Chargement du JSON: {tcdb_json}")
    tcdb_data = load_tcdb_json(tcdb_json)
    print(f"✅ {len(tcdb_data)} sets chargés\n")
    
    # Charge le mapping CID si fourni
    cid_mapping = None
    if cid_mapping_file:
        print(f"🔗 Chargement du mapping CID: {cid_mapping_file}")
        with open(cid_mapping_file, 'r') as f:
            cid_mapping = json.load(f)
        print(f"✅ {len(cid_mapping)} mappings chargés\n")
    
    # Crée le dossier de sortie
    Path(output_dir).mkdir(parents=True, exist_ok=True)
    
    # Liste les images
    image_files = list(Path(images_dir).glob("*.jpg"))
    print(f"📸 {len(image_files)} images trouvées\n")
    print("="*60)
    
    stats = {
        'success': 0,
        'no_match': 0,
        'skipped': 0
    }
    
    for img_path in image_files:
        filename = img_path.stem  # Sans extension
        
        # Parse le nom: 515638-31940327Fr.jpg
        if '-' not in filename:
            print(f"⏭️  Skip (format invalide): {img_path.name}")
            stats['skipped'] += 1
            continue
        
        parts = filename.split('-')
        if len(parts) < 2:
            print(f"⏭️  Skip (format invalide): {img_path.name}")
            stats['skipped'] += 1
            continue
        
        # Extrait le CID (enlève Fr/Bk à la fin)
        cid = parts[1].replace('Fr', '').replace('Bk', '')
        is_back = 'Bk' in filename
        
        # Cherche les infos dans le JSON
        card_info = find_card_info(cid, tcdb_data, cid_mapping)
        
        if not card_info:
            print(f"❌ No match: {img_path.name} (CID: {cid})")
            stats['no_match'] += 1
            continue
        
        # Génère le nouveau nom
        new_filename = format_for_app(
            card_info['set_name'],
            card_info['card_number'],
            card_info['year']
        )
        
        # Ajoute _back si c'est le verso
        if is_back:
            new_filename = new_filename.replace('.jpg', '_back.jpg')
        
        new_path = Path(output_dir) / new_filename
        
        # Copie l'image
        try:
            shutil.copy2(img_path, new_path)
            print(f"✅ {img_path.name}")
            print(f"   → {new_filename}")
            stats['success'] += 1
        except Exception as e:
            print(f"❌ Erreur: {e}")
            continue
    
    # Résumé
    print("\n" + "="*60)
    print("📊 RÉSUMÉ")
    print("="*60)
    print(f"✅ Importées:     {stats['success']}")
    print(f"❌ Non matchées:  {stats['no_match']}")
    print(f"⏭️  Skipped:       {stats['skipped']}")
    print(f"📁 Dossier:       {output_dir}/")
    
    # Instructions pour le simulateur
    if simulator_path:
        print(f"\n📱 COPIE VERS LE SIMULATEUR:")
        print(f"cp {output_dir}/*.jpg \"{simulator_path}/reference_images/\"")
    else:
        print(f"\n📱 POUR COPIER VERS TON APP:")
        print(f"1. Lance ton app dans le simulateur")
        print(f"2. Trouve le chemin Documents (visible dans les logs de debug)")
        print(f"3. Copie les images:")
        print(f"   cp {output_dir}/*.jpg /path/to/simulator/Documents/reference_images/")
        print(f"\n   Ou relance ce script avec --simulator-path")

if __name__ == "__main__":
    import sys
    
    print("""
╔════════════════════════════════════════════════════════════╗
║         Import TCDB Images → Collectly App                 ║
╚════════════════════════════════════════════════════════════╝

Renomme les images TCDB au format de l'app et les copie.

USAGE:
  python3 import_tcdb_to_app.py <images_dir> <tcdb_json> [options]

OPTIONS:
  --output <dir>         Dossier de sortie (défaut: imported_images/)
  --simulator-path <path> Copie directement vers le simulateur
  --cid-mapping <file>   Fichier JSON avec mapping CID → card_number

EXEMPLE:
  python3 import_tcdb_to_app.py images/ tcdb_sets.json
  
  python3 import_tcdb_to_app.py images/ tcdb_sets.json \\
    --cid-mapping cid_mapping.json \\
    --simulator-path ~/Library/Developer/CoreSimulator/Devices/.../Documents/
""")
    
    if len(sys.argv) < 3:
        sys.exit(1)
    
    images_dir = sys.argv[1]
    tcdb_json = sys.argv[2]
    
    # Options
    output_dir = "imported_images"
    simulator_path = None
    cid_mapping_file = None
    
    i = 3
    while i < len(sys.argv):
        if sys.argv[i] == "--output" and i + 1 < len(sys.argv):
            output_dir = sys.argv[i + 1]
            i += 2
        elif sys.argv[i] == "--simulator-path" and i + 1 < len(sys.argv):
            simulator_path = sys.argv[i + 1]
            i += 2
        elif sys.argv[i] == "--cid-mapping" and i + 1 < len(sys.argv):
            cid_mapping_file = sys.argv[i + 1]
            i += 2
        else:
            i += 1
    
    import_tcdb_images(images_dir, tcdb_json, output_dir, simulator_path, cid_mapping_file)
    
    print("\n✅ Terminé!")
