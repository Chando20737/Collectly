#!/usr/bin/env python3
"""Test diagnostic - voir ce que Playwright voit"""

from playwright.sync_api import sync_playwright
import time

url = "https://www.tcdb.com/ViewCard.cfm/sid/515638/cid/31940327"

with sync_playwright() as p:
    browser = p.chromium.launch(headless=False)  # Visible pour debug
    context = browser.new_context(
        user_agent='Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36'
    )
    page = context.new_page()
    
    print(f"🔗 Visite: {url}\n")
    page.goto(url, wait_until="domcontentloaded", timeout=60000)
    
    print("⏳ Attente 5 secondes...\n")
    time.sleep(5)
    
    # Cherche les meta tags
    print("📋 Meta tags og:image:")
    metas = page.locator('meta[property="og:image"]').all()
    print(f"   Trouvés: {len(metas)}")
    for meta in metas:
        content = meta.get_attribute('content')
        print(f"   - {content}")
    
    # Cherche dans le HTML brut
    print("\n📋 Recherche dans HTML brut:")
    html = page.content()
    if 'Images/Cards/Hockey' in html:
        print("   ✅ 'Images/Cards/Hockey' trouvé dans le HTML")
        # Extrait les lignes contenant ça
        lines = [line for line in html.split('\n') if 'Images/Cards/Hockey' in line]
        for line in lines[:3]:
            print(f"   {line.strip()[:100]}...")
    else:
        print("   ❌ 'Images/Cards/Hockey' PAS trouvé dans le HTML")
    
    print("\n💾 HTML sauvegardé dans debug_page.html")
    with open('debug_page.html', 'w') as f:
        f.write(html)
    
    time.sleep(2)
    browser.close()

print("\n✅ Terminé! Vérifie debug_page.html")
