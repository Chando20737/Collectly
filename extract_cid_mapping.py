#!/usr/bin/env python3
"""
Extrait les CIDs depuis les HTMLs TCDB et crée un mapping CID → card_number
"""

import re
import json
from pathlib import Path

def extract_cid_mapping_from_html(html_file):
    """
    Extrait le mapping CID → card_number depuis un HTML de checklist TCDB
    
    Cherche les patterns comme:
    ViewCard.cfm/sid/515638/cid/31940327/2025-26-Upper-Deck-1-Mason-McTavish
    
    Retourne: {cid: card_number}
    """
    
    with open(html_file, 'r', encoding='utf-8') as f:
        content = f.read()
    
    # Pattern: ViewCard.cfm/sid/SETID/cid/CID/YEAR-SET-CARDNUMBER-PLAYERNAME
    pattern = r'ViewCard\.cfm/sid/(\d+)/cid/(\d+)/[^/]+-(\d+(?:[A-Z]{2})?(?:-\d+)?)-'
    matches = re.findall(pattern, content)
    
    mapping = {}
    for sid, cid, card_num in matches:
        # Nettoie le card_number (enlève les préfixes si besoin)
        clean_num = card_num.strip()
        mapping[cid] = clean_num
    
    print(f"✅ Trouvé {len(mapping)} mappings CID → card_number")
    
    # Affiche quelques exemples
    print("\n📋 Exemples:")
    for i, (cid, num) in enumerate(list(mapping.items())[:5]):
        print(f"   CID {cid} → #{num}")
    
    return mapping

def save_mapping(mapping, output_file):
    """Sauvegarde le mapping en JSON"""
    with open(output_file, 'w') as f:
        json.dump(mapping, f, indent=2)
    print(f"\n💾 Mapping sauvegardé: {output_file}")

def process_multiple_htmls(html_files):
    """Traite plusieurs fichiers HTML et combine les mappings"""
    combined = {}
    
    for html_file in html_files:
        print(f"\n📄 Traitement: {html_file}")
        mapping = extract_cid_mapping_from_html(html_file)
        combined.update(mapping)
    
    return combined

if __name__ == "__main__":
    import sys
    
    print("""
╔════════════════════════════════════════════════════════════╗
║         TCDB CID Mapper - HTML → JSON                      ║
╚════════════════════════════════════════════════════════════╝

Extrait les mappings CID → card_number depuis les HTMLs TCDB.

USAGE:
  python3 extract_cid_mapping.py <html_file1> [html_file2 ...] [--output file.json]

EXEMPLE:
  python3 extract_cid_mapping.py 2025-26_series1.html 2025-26_Series1_suite.html
  python3 extract_cid_mapping.py *.html --output cid_mapping.json
""")
    
    if len(sys.argv) < 2:
        sys.exit(1)
    
    # Parse arguments
    html_files = []
    output_file = "cid_mapping.json"
    
    i = 1
    while i < len(sys.argv):
        if sys.argv[i] == "--output" and i + 1 < len(sys.argv):
            output_file = sys.argv[i + 1]
            i += 2
        elif sys.argv[i].endswith('.html'):
            html_files.append(sys.argv[i])
            i += 1
        else:
            i += 1
    
    if not html_files:
        print("❌ Aucun fichier HTML trouvé!")
        sys.exit(1)
    
    # Traite les fichiers
    print(f"📚 {len(html_files)} fichier(s) à traiter\n")
    print("="*60)
    
    mapping = process_multiple_htmls(html_files)
    
    print("\n" + "="*60)
    print(f"📊 TOTAL: {len(mapping)} mappings CID → card_number")
    
    # Sauvegarde
    save_mapping(mapping, output_file)
    
    print("\n✅ Terminé!")
    print(f"\nUtilise ce fichier avec import_tcdb_to_app.py:")
    print(f"  python3 import_tcdb_to_app.py images/ tcdb_sets.json --cid-mapping {output_file}")
