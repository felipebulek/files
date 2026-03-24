import requests
from bs4 import BeautifulSoup
import os

TOKEN = os.getenv("TELEGRAM_TOKEN")
CHAT_ID = os.getenv("TELEGRAM_CHAT_ID")
URL = "https://www.cbf.com.br/futebol-brasileiro/noticias/campeonato-brasileiro/serie-a"

def enviar_telegram(msg):
    api_url = f"https://api.telegram.org/bot{TOKEN}/sendMessage"
    payload = {"chat_id": CHAT_ID, "text": msg, "parse_mode": "Markdown"}
    requests.post(api_url, data=payload)

def buscar_noticias():
    # User-Agent bem completo para parecer um navegador real
    headers = {
        "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36",
        "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8",
        "Accept-Language": "pt-BR,pt;q=0.9,en-US;q=0.8,en;q=0.7"
    }
    
    try:
        res = requests.get(URL, headers=headers, timeout=20)
        soup = BeautifulSoup(res.text, "html.parser")
        
        # DEBUG: Vamos ver se o site bloqueou o acesso
        if res.status_code != 200:
            print(f"Erro no acesso: Status {res.status_code}")
            return []

        # Tenta encontrar todos os links que apontam para notícias
        links = soup.find_all("a", href=True)
        noticias = []

        for l in links:
            href = l['href']
            # Filtro pela estrutura da URL da CBF
            if "/noticias/campeonato-brasileiro/serie-a/" in href:
                # Pega o texto do link ou de um span/h3 dentro dele
                texto = l.get_text().strip()
                if len(texto) > 15:
                    url_completa = href if href.startswith("http") else f"https://www.cbf.com.br{href}"
                    noticias.append((texto, url_completa))

        return noticias
    except Exception as e:
        print(f"Erro crítico: {e}")
        return []

# Execução principal
lista = buscar_noticias()

if lista:
    # Remove duplicatas mantendo a ordem
    lista_limpa = list(dict.fromkeys(lista))
    manchete, link = lista_limpa[0]
    
    print(f"✅ Notícia encontrada: {manchete}")
    
    # Envia para o Telegram para confirmar que o robô está VIVO
    enviar_telegram(f"🤖 *Robô CBF Ativo!*\n\nÚltima notícia: {manchete}\n\n[Link]({link})")
else:
    print("❌ Nenhuma notícia encontrada. Talvez o site use carregamento dinâmico.")
    enviar_telegram("⚠️ O robô rodou, mas não encontrou notícias no site da CBF.")
