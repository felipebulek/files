# CBF — watcher de homologação de rodadas (Brasileirão Série A)

Avisa no Telegram quando a CBF homologa rodadas do Campeonato Brasileiro Série A, detectando
**dois sinais independentes**:

| # | Sinal | Fonte |
|---|-------|-------|
| 1 | Novo PDF `Tabela Detalhada - BSA <ano>` | `GET /api/upload/files` |
| 2 | Nova notícia de detalhamento na categoria Série A | `GET /api/paginas` |

Roda de graça no GitHub Actions, sem servidor e sem dependências: só PowerShell 7 (`pwsh`),
que já vem instalado nos runners `ubuntu-latest` e no Windows 11.

---

## Como isso funciona (e por que não é scraping)

O site da CBF é um Next.js que renderiza tudo no cliente — o HTML de
`/futebol-brasileiro/noticias/...` chega praticamente vazio, então raspar a página exigiria um
navegador headless. Mas o site consome um **Strapi público** em `https://cms.cbf.com.br/api`,
que responde sem autenticação. O watcher fala direto com essa API.

Isso foi verificado contra os dados reais:

- O PDF `Tabela Detalhada - BSA 2026 - 25.08.pdf` é o registro `id=25156`, e sua `url` é
  exatamente a do arquivo publicado na área de documentos do site.
- A notícia `cbf-detalha-rodadas-25-e-26-do-brasileirao-betano` traz o campo **`Anexos`** com o
  PDF `Tabela Detalhada - Brasileiro Série A 2026 25ª e 26ª rodada (3).pdf` — ou seja, a própria
  notícia entrega o documento **e os números das rodadas**. É o sinal mais rico dos dois, e o
  watcher inclui esse anexo na mensagem.

**A novidade é decidida por `id` (PDF) e por `Slug` (notícia), nunca por data.** Isso torna a
detecção imune a fuso horário, a republicação do mesmo arquivo e a reordenação no CMS.

### Consultas exatas

```
# Sinal 1 — PDFs
GET https://cms.cbf.com.br/api/upload/files
      ?filters[name][$containsi]=Tabela%20Detalhada
      &sort=createdAt:desc
      &pagination[pageSize]=60

# Sinal 2 — notícias
GET https://cms.cbf.com.br/api/paginas
      ?filters[Categoria][Slug][$eq]=noticias-campeonato-brasileiro-serie-a
      &sort=publishedAt:desc
      &pagination[pageSize]=25
      &populate[Anexos]=*&populate[Area]=*&populate[Categoria][populate][0]=categoria_pai
```

O filtro de Série A é aplicado **no cliente**, por regex, porque a nomenclatura dos arquivos da
CBF é inconsistente (`BSA`, `Brasileiro Série A`, maiúsculas variadas). Ver `config.json`.

---

## Instalação

### 1. Criar o bot do Telegram

1. No Telegram, fale com [@BotFather](https://t.me/BotFather) → `/newbot` → escolha nome e
   username. Ele devolve o **token** (formato `123456789:AA...`).
2. Envie qualquer mensagem para o seu bot recém-criado (o bot não pode iniciar a conversa).
3. Descubra o seu **chat id** abrindo no navegador:
   `https://api.telegram.org/bot<SEU_TOKEN>/getUpdates`
   e lendo `result[0].message.chat.id`.

> Para receber em grupo: adicione o bot ao grupo, mande uma mensagem lá e use o `chat.id`
> negativo que aparecer no `getUpdates`.

### 2. Publicar o repositório

```bash
cd cbf-homologacao-watcher
git init -b main
git add .
git commit -m "feat: watcher de homologacao de rodadas da CBF"
gh repo create cbf-homologacao-watcher --private --source=. --push
```

### 3. Cadastrar os secrets

```bash
gh secret set TELEGRAM_BOT_TOKEN   # cole o token do BotFather
gh secret set TELEGRAM_CHAT_ID     # cole o chat id
```

Ou em **Settings → Secrets and variables → Actions**.

### 4. Semear o estado

O `state.json` versionado começa como `{}`. A **primeira** execução apenas registra a situação
atual e **não notifica** — de propósito, para você não receber um lote de avisos retroativos.
Dispare-a manualmente:

**Actions → CBF - homologacao Serie A → Run workflow → modo `normal`**

A partir daí, só chega mensagem quando houver algo genuinamente novo.

---

## Uso e diagnóstico

Todos os modos estão no `workflow_dispatch` (**Run workflow → Modo de execucao**):

| Modo | O que faz |
|------|-----------|
| `normal` | Detecta, notifica e grava o estado. É o que o cron usa. |
| `dry-run` | Detecta e imprime a mensagem no log. Não envia, não grava. |
| `show-matches` | Lista os itens recentes que casam com os filtros, ignorando o estado. Use para validar as regex. |
| `reseed` | Regrava o estado com a situação atual, sem notificar. Use depois de mexer nos filtros. |

Localmente (Windows, PowerShell 7):

```powershell
# Validar os filtros contra os dados de agora
./scripts/Watch-CbfHomologacao.ps1 -ShowMatches

# Ver a mensagem que seria enviada, sem enviar e sem gravar estado
./scripts/Watch-CbfHomologacao.ps1 -DryRun

# Rodar de verdade a partir da máquina local
$env:TELEGRAM_BOT_TOKEN = '...'
$env:TELEGRAM_CHAT_ID   = '...'
./scripts/Watch-CbfHomologacao.ps1
```

Use `-StatePath` para testar com um estado separado, sem sujar o `state.json` do repositório.

---

## Ajustes

Tudo em **`config.json`** — não é preciso mexer no script.

- **Frequência**: o cron em `.github/workflows/watch.yml` é `*/20 11-23 * * *` (UTC), ou seja a
  cada 20 min entre 08:00 e 20:59 de Brasília — ~39 execuções/dia, cerca de 13 min de Actions
  por dia. Em repositório privado no plano gratuito isso cabe folgado nos 2.000 min/mês; em
  repositório público os minutos são ilimitados.
- **Outras competições**: troque `news.categorySlug` e os padrões de `pdf`. Os slugs seguem o
  formato `noticias-campeonato-brasileiro-serie-b` etc.
- **Quanto o estado lembra**: `state.maxRemembered` (padrão 400 ids).

### Os filtros de Série A

`pdf.mustMatch` exige `tabela detalhada` **e** (`BSA` ou `série a`); `pdf.mustNotMatch` descarta
Feminino, Sub-XX, Séries B/C/D e Copa do Brasil/Nordeste. O padrão `s[eé]rie\s*a\b` casa
`Série A 2026` mas **não** `Série A1` — a fronteira `\b` não existe entre `A` e `1`.

Validado contra a API real: dos 60 PDFs mais recentes com "Tabela Detalhada", exatamente os 5
da Série A passam; das 25 notícias mais recentes da categoria Série A, exatamente a de
homologação passa.

---

## Ressalvas conhecidas

Vale ter em mente, porque nenhuma delas é bug e todas podem aparecer:

1. **A API é interna.** `cms.cbf.com.br/api` não tem contrato público nem versionamento e pode
   mudar sem aviso. Se mudar, o watcher falha de forma **visível** — o job quebra e você recebe
   o alerta de falha no Telegram, em vez de silenciar.
2. **O PDF pode ser detectado antes de aparecer no site.** O sinal 1 observa o storage de
   uploads, não a página. Se a CBF sobe o arquivo e publica minutos depois, o aviso chega antes
   do link estar visível na área de documentos. Na prática é uma vantagem, mas explica um
   eventual clique em link ainda não linkado no site.
3. **Os dois sinais podem disparar para a mesma homologação**, em execuções diferentes (o PDF
   e a notícia raramente saem no mesmo minuto). Foi o que você pediu — "e/ou" —, mas são duas
   mensagens, não uma.
4. **A CBF republica o mesmo PDF.** Há casos de dois uploads no mesmo dia (`18.08` aparece duas
   vezes, ids 24962 e 24974). Cada upload é um `id` distinto, então gera um aviso cada. É o
   comportamento correto: a segunda versão normalmente corrige a primeira.
5. **A janela do sinal 1 é de 60 arquivos.** A CBF publica tabelas de muitas competições, então
   60 registros cobrem ~2 semanas. Com execução a cada 20 min isso é folgado, mas se o watcher
   ficar semanas parado, PDFs antigos podem sair da janela e nunca ser notificados. Aumente
   `pdf.pageSize` se for reativar depois de um hiato longo.
6. **O GitHub desativa cron em repositório sem atividade por 60 dias.** O `state.json` só é
   comitado quando há novidade, então numa entressafra longa o repositório pode ficar parado. O
   GitHub avisa por e-mail antes de desativar; um `Run workflow` manual reativa.

---

## Estrutura

```
.
├── .github/workflows/watch.yml       # cron + modos manuais + commit do estado + alerta de falha
├── scripts/Watch-CbfHomologacao.ps1  # toda a lógica (PowerShell 7, sem dependências)
├── config.json                       # endpoints, filtros regex, limites
├── state.json                        # ids/slugs já vistos (comitado pelo Actions)
└── README.md
```
