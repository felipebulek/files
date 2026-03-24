import requests
from bs4 import BeautifulSoup
import os

TOKEN = os.getenv("TELEGRAM_TOKEN")
CHAT_ID = os.getenv("TELEGRAM_CHAT_ID")
URL = "https://www.cbf.com.br/futebol-brasileiro/noticias/campeonato-brasileiro/serie-a"

def enviar_telegram(msg):
    url = f"https://api.telegram.org/bot{TOKEN}/sendMessage"
    payload = {"chat_id": CHAT_ID, "text": msg, "parse_mode": "Markdown"}
    requests.post(url, data=payload)

def buscar_noticias():
    headers = {
        "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
    }
    try:
        res = requests.get(URL, headers=headers, timeout=15)
        soup = BeautifulSoup(res.text, "html.parser")
        
        # O site da CBF organiza as notícias dentro de elementos 'a' 
        # Vamos buscar todos os links que apontam para notícias da Série A
        links_noticias = soup.find_all("a", href=True)
        
        noticias_encontradas = []

        for link in links_noticias:
            href = link["href"]
            if "/noticias/campeonato-brasileiro/serie-a/" in href:
                # Tenta pegar o título: pode estar no texto direto ou em um span interno
                titulo = link.get_text().strip()
                
                # Se o link for relativo, completa
                url_final = href if href.startswith("http") else f"https://www.cbf.com.br{href}"
                
                if len(titulo) > 15: # Filtra ruídos e links curtos
                    noticias_encontradas.append((titulo, url_final))
        
        return noticias_encontradas
    except Exception as e:
        print(f"Erro ao acessar site: {e}")
        return []

# Execução
lista_noticias = buscar_noticias()

if lista_noticias:
    # Vamos pegar a primeira (mais recente)
    manchete, url = lista_noticias[0]
    print(f"Sucesso! Encontrei: {manchete}")
    
    # Filtro específico para o que você quer
    termo_busca = "tabela detalhada"
    if termo_busca in manchete.lower():
        msg = f"🚨 *NOVA TABELA DETALHADA CBF*\n\n{manchete}\n\n[Clique aqui para ver]({url})"
        enviar_telegram(msg)
    else:
        # Para o seu teste agora, vamos enviar qualquer notícia só para ver o Telegram apitar
        enviar_telegram(f"✅ *Robô Ativo!*\nÚltima notícia encontrada:\n\n{manchete}\n\n[Link]({url})")
else:
    print("Ainda não encontrei notícias. Verificando estrutura alternativa...")
    # Debug: imprime os primeiros 500 caracteres do HTML para você ver o que está vindo
