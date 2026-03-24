import requests
from bs4 import BeautifulSoup
import os

TOKEN = os.getenv("TELEGRAM_TOKEN")
CHAT_ID = os.getenv("TELEGRAM_CHAT_ID")
URL = "https://www.cbf.com.br/futebol-brasileiro/noticias/campeonato-brasileiro/serie-a"

def enviar_telegram(msg):
    requests.post(f"https://api.telegram.org/bot{TOKEN}/sendMessage", 
                  data={"chat_id": CHAT_ID, "text": msg, "parse_mode": "Markdown"})

def buscar_noticia():
    headers = {"User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/119.0.0.0 Safari/537.36"}
    res = requests.get(URL, headers=headers)
    soup = BeautifulSoup(res.text, "html.parser")
    
    # Busca por links que pareçam notícias da série A
    for link in soup.find_all("a", href=True):
        if "/noticias/campeonato-brasileiro/serie-a/" in link["href"]:
            # O título geralmente está no texto do link ou em um span interno
            titulo = link.get_text().strip()
            url_final = link["href"]
            if not url_final.startswith("http"):
                url_final = "https://www.cbf.com.br" + url_final
            
            if len(titulo) > 10: # Filtro simples para pegar manchetes reais
                return titulo, url_final
    return None, None

manchete, url = buscar_noticia()

if manchete:
    # Lógica de persistência para não repetir (GitHub Actions usa artefatos ou commits, 
    # mas para simplificar o teste, vamos apenas imprimir e enviar)
    if "tabela" in manchete.lower() or "detalhada" in manchete.lower():
        enviar_telegram(f"🚨 *Nova Tabela Detalhada!*\n\n{manchete}\n\n[Leia mais]({url})")
    else:
        print(f"Notícia encontrada: {manchete} (não enviada pelo filtro)")
else:
    print("Nenhuma notícia encontrada com os seletores atuais.")