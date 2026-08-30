#Requires -Version 7.0
<#
.SYNOPSIS
    Detecta a homologacao de rodadas do Brasileirao Serie A pela CBF e notifica no Telegram.

.DESCRIPTION
    Monitora dois sinais independentes na API do CMS publico da CBF (Strapi):

      1. /api/upload/files  -> novo PDF "Tabela Detalhada - BSA <ano>"
      2. /api/paginas       -> nova noticia na categoria Serie A cujo titulo indica
                               detalhamento/homologacao de rodadas

    A novidade e determinada por id (PDF) e por Slug (noticia), nunca por data, para
    ser imune a fuso horario, republicacao e reordenacao no CMS.

.PARAMETER DryRun
    Detecta e imprime, mas nao envia Telegram e nao grava o estado.

.PARAMETER Reseed
    Regrava o estado com a situacao atual sem notificar nada. Use na primeira execucao
    ou depois de mexer nos filtros, para nao disparar um lote de avisos retroativos.

.PARAMETER ShowMatches
    Lista os itens recentes que casam com os filtros atuais, ignorando o estado.
    Serve para validar as expressoes regulares de config.json.

.NOTES
    Sem dependencias externas: apenas PowerShell 7 (pwsh), disponivel no Windows e nos
    runners ubuntu-latest do GitHub Actions.
#>
[CmdletBinding()]
param(
    [string] $ConfigPath,
    [string] $StatePath,
    [switch] $DryRun,
    [switch] $Reseed,
    [switch] $ShowMatches
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8

$RepoRoot = Split-Path -Parent $PSScriptRoot
if (-not $ConfigPath) { $ConfigPath = Join-Path $RepoRoot 'config.json' }
if (-not $StatePath)  { $StatePath  = Join-Path $RepoRoot 'state.json' }

# Permite acionar as flags por variavel de ambiente (mais simples de passar no workflow).
if ($env:WATCHER_DRY_RUN      -eq 'true') { $DryRun      = $true }
if ($env:WATCHER_RESEED       -eq 'true') { $Reseed      = $true }
if ($env:WATCHER_SHOW_MATCHES -eq 'true') { $ShowMatches = $true }

#region ----------------------------------------------------------------- helpers

function Write-Step { param([string] $Message) Write-Host "==> $Message" -ForegroundColor Cyan }
function Write-Info { param([string] $Message) Write-Host "    $Message" }
function Write-Warn { param([string] $Message) Write-Host "  ! $Message" -ForegroundColor Yellow }

function Invoke-JsonApi {
    # GET com retry e backoff exponencial. A API da CBF ocasionalmente devolve 5xx.
    param(
        [Parameter(Mandatory)] [string] $Uri,
        [int] $MaxAttempts = 4,
        [int] $TimeoutSec = 45
    )
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            return Invoke-RestMethod -Uri $Uri -Method Get -TimeoutSec $TimeoutSec -Headers @{
                Accept       = 'application/json'
                'User-Agent' = 'cbf-homologacao-watcher/1.0'
            }
        }
        catch {
            if ($attempt -eq $MaxAttempts) {
                throw "Falha ao consultar '$Uri' apos $MaxAttempts tentativas: $($_.Exception.Message)"
            }
            $wait = [int][Math]::Pow(2, $attempt)
            Write-Warn "Tentativa $attempt falhou ($($_.Exception.Message)). Nova tentativa em ${wait}s."
            Start-Sleep -Seconds $wait
        }
    }
}

function Test-Patterns {
    # Verdadeiro se $Text casa com TODAS as regex de MustMatch e com NENHUMA de MustNotMatch.
    param(
        [string] $Text,
        [string[]] $MustMatch,
        [string[]] $MustNotMatch
    )
    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    foreach ($p in @($MustMatch))    { if ($p -and ($Text -notmatch $p)) { return $false } }
    foreach ($p in @($MustNotMatch)) { if ($p -and ($Text -match  $p))   { return $false } }
    return $true
}

function Get-RodadaLabel {
    # Extrai "25 e 26", "28 a 33" ou "25" de um titulo/nome de arquivo, para enriquecer o aviso.
    # O conector original ("e" para rodadas avulsas, "a" para intervalo) e preservado,
    # porque a diferenca importa: "25 e 26" sao duas rodadas, "28 a 33" sao seis.
    param([string] $Text)
    if (-not $Text) { return $null }
    if ($Text -match '(?i)rodadas?\s+(\d{1,2})\s*(e|a|at[eé]|-|/)\s*(\d{1,2})') {
        # Copiar os grupos antes de qualquer outra operacao regex: -match/-replace/switch -Regex
        # sobrescrevem $Matches.
        $first = $Matches[1]; $conn = $Matches[2]; $second = $Matches[3]
        $connLabel = if ($conn.Trim().ToLowerInvariant() -eq 'e') { 'e' } else { 'a' }
        return "$first $connLabel $second"
    }
    if ($Text -match '(?i)(\d{1,2})\s*[ªa°]?\s*e\s*(\d{1,2})\s*[ªa°]?\s*rodada') { return "$($Matches[1]) e $($Matches[2])" }
    if ($Text -match '(?i)rodadas?\s+(\d{1,2})')                                 { return $Matches[1] }
    if ($Text -match '(?i)(\d{1,2})\s*[ªa°]\s*rodada')                           { return $Matches[1] }
    return $null
}

function Format-Timestamp {
    # A conversao de JSON do PowerShell transforma datas ISO em DateTime; aceita os dois casos.
    param($Value)
    if (-not $Value) { return '' }
    if ($Value -is [datetime]) { return $Value.ToLocalTime().ToString('dd/MM/yyyy HH:mm') }
    try { return ([datetime]::Parse([string]$Value)).ToLocalTime().ToString('dd/MM/yyyy HH:mm') }
    catch { return [string]$Value }
}

function Get-NewsUrl {
    # Reproduz a montagem de URL do proprio site (Next.js):
    #   com categoria pai : /{area}/noticias/{pai}/{categoria}/{slug}
    #   sem categoria pai : /{area}/noticias/{categoria}/a/{slug}
    # Os slugs de categoria no CMS vem prefixados com "noticias-", que o site remove.
    param($Attributes, [string] $SiteBase)

    $area = $null
    if (($Attributes.PSObject.Properties.Name -contains 'Area') -and $Attributes.Area -and $Attributes.Area.data) {
        $area = $Attributes.Area.data.attributes.Slug
    }
    if (-not $area) { $area = 'futebol-brasileiro' }

    $cat = $null
    $parent = $null
    if (($Attributes.PSObject.Properties.Name -contains 'Categoria') -and $Attributes.Categoria -and $Attributes.Categoria.data) {
        $catAttr = $Attributes.Categoria.data.attributes
        if ($catAttr.Slug) { $cat = $catAttr.Slug -replace '^noticias-', '' }
        if (($catAttr.PSObject.Properties.Name -contains 'categoria_pai') -and $catAttr.categoria_pai -and $catAttr.categoria_pai.data) {
            $parentSlug = $catAttr.categoria_pai.data.attributes.Slug
            if ($parentSlug) { $parent = $parentSlug -replace '^noticias-', '' }
        }
    }

    if (-not $cat) {
        return "$SiteBase/futebol-brasileiro/noticias/campeonato-brasileiro/campeonato-brasileiro-serie-a/$($Attributes.Slug)"
    }
    if ($parent) { return "$SiteBase/$area/noticias/$parent/$cat/$($Attributes.Slug)" }
    return "$SiteBase/$area/noticias/$cat/a/$($Attributes.Slug)"
}

function Get-HtmlEscaped {
    # Escapa e normaliza espacos: os titulos do CMS costumam vir com \n ou \t no fim.
    param([string] $Text)
    if (-not $Text) { return '' }
    $t = ($Text -replace '\s+', ' ').Trim()
    return ($t -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;')
}

# Emojis por code point: nao depende da codificacao do arquivo nem de o Telegram
# decodificar entidades HTML numericas.
$script:Emoji = @{
    Trophy = [char]::ConvertFromUtf32(0x1F3C6)
    News   = [char]::ConvertFromUtf32(0x1F4F0)
    Doc    = [char]::ConvertFromUtf32(0x1F4C4)
    Clip   = [char]::ConvertFromUtf32(0x1F4CE)
}

function New-TelegramMessage {
    param([object[]] $Events, $Config)

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine("$($script:Emoji.Trophy) <b>Homologacao de rodadas - $(Get-HtmlEscaped $Config.competitionLabel)</b>")

    foreach ($e in $Events) {
        [void]$sb.AppendLine('')
        if ($e.Kind -eq 'news') {
            [void]$sb.AppendLine("$($script:Emoji.News) <b>Nova noticia de detalhamento</b>")
        } else {
            [void]$sb.AppendLine("$($script:Emoji.Doc) <b>Nova tabela detalhada publicada</b>")
        }
        [void]$sb.AppendLine("<b>$(Get-HtmlEscaped $e.Title)</b>")
        if ($e.Rodadas)   { [void]$sb.AppendLine("Rodadas: <b>$(Get-HtmlEscaped $e.Rodadas)</b>") }
        if ($e.Timestamp) { [void]$sb.AppendLine("Publicado em: $(Get-HtmlEscaped $e.Timestamp)") }
        [void]$sb.AppendLine($e.Url)

        if ($e.Kind -eq 'news' -and $e.Anexos -and $e.Anexos.Count -gt 0) {
            foreach ($ax in $e.Anexos) {
                [void]$sb.AppendLine("$($script:Emoji.Clip) <a href=`"$($ax.Url)`">$(Get-HtmlEscaped $ax.Name)</a>")
            }
        }
    }

    [void]$sb.AppendLine('')
    [void]$sb.AppendLine("<a href=`"$($Config.documentsPageUrl)`">Documentos da competicao no site da CBF</a>")
    return $sb.ToString()
}

function Send-TelegramMessage {
    param([string] $Text, $Config)

    $token  = $env:TELEGRAM_BOT_TOKEN
    $chatId = $env:TELEGRAM_CHAT_ID
    if (-not $token -or -not $chatId) {
        throw 'TELEGRAM_BOT_TOKEN e/ou TELEGRAM_CHAT_ID nao definidos no ambiente.'
    }

    # Telegram limita a mensagem a 4096 caracteres.
    if ($Text.Length -gt 4000) { $Text = $Text.Substring(0, 3990) + "`n[...]" }

    $body = @{
        chat_id                  = $chatId
        text                     = $Text
        parse_mode               = 'HTML'
        disable_web_page_preview = [bool]$Config.telegram.disableWebPagePreview
    } | ConvertTo-Json -Depth 3

    $uri = "$($Config.telegram.apiBase)/bot$token/sendMessage"
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            $resp = Invoke-RestMethod -Uri $uri -Method Post -TimeoutSec 30 `
                -ContentType 'application/json; charset=utf-8' `
                -Body ([Text.Encoding]::UTF8.GetBytes($body))
            if (-not $resp.ok) { throw "Telegram respondeu ok=false: $($resp | ConvertTo-Json -Compress)" }
            return
        }
        catch {
            if ($attempt -eq 3) { throw "Falha ao enviar Telegram: $($_.Exception.Message)" }
            Write-Warn "Envio falhou (tentativa $attempt): $($_.Exception.Message)"
            Start-Sleep -Seconds (2 * $attempt)
        }
    }
}

#endregion

#region ------------------------------------------------------------ estado / config

Write-Step "Lendo configuracao: $ConfigPath"
if (-not (Test-Path -LiteralPath $ConfigPath)) { throw "config.json nao encontrado em '$ConfigPath'." }
$cfg = Get-Content -LiteralPath $ConfigPath -Raw -Encoding utf8 | ConvertFrom-Json

# lastChangeAt existe em vez de "lastRunAt" de proposito: no GitHub Actions o state.json e
# comitado de volta ao repositorio, e um timestamp por execucao geraria dezenas de commits
# por dia. Assim o arquivo so muda quando ha novidade de fato.
$defaultState = [ordered]@{
    seededAt      = $null
    lastChangeAt  = $null
    lastPdfId     = 0
    seenPdfIds    = @()
    seenNewsSlugs = @()
}

$loaded = $null
if (Test-Path -LiteralPath $StatePath) {
    $raw = (Get-Content -LiteralPath $StatePath -Raw -Encoding utf8)
    if ($raw -and $raw.Trim()) { $loaded = $raw | ConvertFrom-Json }
}

$state = [ordered]@{}
foreach ($k in $defaultState.Keys) {
    if ($loaded -and ($loaded.PSObject.Properties.Name -contains $k)) { $state[$k] = $loaded.$k }
    else { $state[$k] = $defaultState[$k] }
}

$isFirstRun = -not $state.seededAt
if ($isFirstRun) {
    Write-Warn 'Estado ausente ou nao semeado: esta execucao apenas registra a situacao atual (sem notificar).'
}
$seedOnly = $isFirstRun -or $Reseed

$seenPdfIds = [System.Collections.Generic.HashSet[int]]::new()
foreach ($id in @($state.seenPdfIds)) { if ($null -ne $id) { [void]$seenPdfIds.Add([int]$id) } }

$seenNewsSlugs = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($s in @($state.seenNewsSlugs)) { if ($s) { [void]$seenNewsSlugs.Add([string]$s) } }

#endregion

#region ------------------------------------------------------------------- coleta

$events = [System.Collections.Generic.List[object]]::new()

# ---- Sinal 1: PDF da tabela detalhada -------------------------------------------
$pdfMatches = @()
if ($cfg.pdf.enabled) {
    Write-Step 'Sinal 1/2 - PDFs de tabela detalhada (/api/upload/files)'
    $term = [uri]::EscapeDataString([string]$cfg.pdf.searchTerm)
    $uri  = "$($cfg.apiBase)/upload/files?filters[name][`$containsi]=$term&sort=createdAt:desc&pagination[pageSize]=$($cfg.pdf.pageSize)"
    $files = Invoke-JsonApi -Uri $uri

    # /api/upload/files devolve { data: [...], meta: {...} } ou, em algumas versoes, um array puro.
    $items = if ($files.PSObject.Properties.Name -contains 'data') { @($files.data) } else { @($files) }
    Write-Info "$($items.Count) arquivo(s) retornado(s) pela busca '$($cfg.pdf.searchTerm)'."

    $pdfMatches = @($items | Where-Object {
        Test-Patterns -Text $_.name -MustMatch $cfg.pdf.mustMatch -MustNotMatch $cfg.pdf.mustNotMatch
    })
    Write-Info "$($pdfMatches.Count) casaram com os filtros de Serie A."

    foreach ($f in $pdfMatches) {
        $id = [int]$f.id
        if ($seenPdfIds.Contains($id)) { continue }
        $events.Add([pscustomobject]@{
            Kind      = 'pdf'
            Id        = $id
            Title     = $f.name
            Url       = $f.url
            Rodadas   = Get-RodadaLabel $f.name
            Timestamp = Format-Timestamp $f.createdAt
            Anexos    = @()
        })
    }
}

# ---- Sinal 2: noticia de homologacao --------------------------------------------
$newsMatches = @()
if ($cfg.news.enabled) {
    Write-Step 'Sinal 2/2 - Noticias da Serie A (/api/paginas)'
    $catSlug = [uri]::EscapeDataString([string]$cfg.news.categorySlug)
    $uri = "$($cfg.apiBase)/paginas" +
           "?filters[Categoria][Slug][`$eq]=$catSlug" +
           "&sort=publishedAt:desc" +
           "&pagination[pageSize]=$($cfg.news.pageSize)" +
           "&fields[0]=Titulo&fields[1]=Slug&fields[2]=publishedAt&fields[3]=Headline" +
           "&populate[Anexos]=*" +
           "&populate[Area]=*" +
           "&populate[Categoria][populate][0]=categoria_pai"
    $news = Invoke-JsonApi -Uri $uri
    $items = @($news.data)
    Write-Info "$($items.Count) noticia(s) retornada(s) na categoria '$($cfg.news.categorySlug)'."

    $newsMatches = @($items | Where-Object {
        Test-Patterns -Text $_.attributes.Titulo -MustMatch $cfg.news.mustMatch -MustNotMatch $cfg.news.mustNotMatch
    })
    Write-Info "$($newsMatches.Count) casaram com os filtros de homologacao."

    foreach ($n in $newsMatches) {
        $a = $n.attributes
        if ($seenNewsSlugs.Contains([string]$a.Slug)) { continue }

        $anexos = @()
        if (($a.PSObject.Properties.Name -contains 'Anexos') -and $a.Anexos -and $a.Anexos.data) {
            $anexos = @($a.Anexos.data | ForEach-Object {
                [pscustomobject]@{ Name = $_.attributes.name; Url = $_.attributes.url }
            })
        }
        $rodadas = Get-RodadaLabel $a.Titulo
        if (-not $rodadas -and $anexos.Count -gt 0) { $rodadas = Get-RodadaLabel $anexos[0].Name }

        $events.Add([pscustomobject]@{
            Kind      = 'news'
            Id        = [string]$a.Slug
            Title     = $a.Titulo
            Url       = Get-NewsUrl -Attributes $a -SiteBase $cfg.siteBase
            Rodadas   = $rodadas
            Timestamp = Format-Timestamp $a.publishedAt
            Anexos    = $anexos
        })
    }
}

#endregion

#region ------------------------------------------------------------ modo diagnostico

if ($ShowMatches) {
    Write-Step 'Itens recentes que casam com os filtros atuais (estado ignorado)'
    Write-Host ''
    Write-Host '--- PDFs ---' -ForegroundColor Green
    foreach ($f in $pdfMatches) {
        Write-Host ("  [{0}] {1}  ({2})" -f $f.id, $f.name, (Format-Timestamp $f.createdAt))
    }
    Write-Host ''
    Write-Host '--- Noticias ---' -ForegroundColor Green
    foreach ($n in $newsMatches) {
        Write-Host ("  {0}  |  {1}" -f (Format-Timestamp $n.attributes.publishedAt), $n.attributes.Titulo)
    }
    Write-Host ''
    Write-Info 'Nada foi enviado nem gravado (-ShowMatches).'
    return
}

#endregion

#region ---------------------------------------------------------------- notificacao

Write-Step 'Resultado'

if ($seedOnly) {
    Write-Info "Modo semeadura: $($events.Count) item(ns) conhecido(s) serao registrados sem notificacao."
}
elseif ($events.Count -eq 0) {
    Write-Info 'Nenhuma novidade.'
}
else {
    Write-Info "$($events.Count) novidade(s) detectada(s):"
    foreach ($e in $events) { Write-Host ("      [{0}] {1}" -f $e.Kind, $e.Title) }

    $message = New-TelegramMessage -Events $events.ToArray() -Config $cfg
    if ($DryRun) {
        Write-Warn 'DryRun: mensagem NAO enviada. Conteudo abaixo.'
        Write-Host ''
        Write-Host $message
        Write-Host ''
    } else {
        Send-TelegramMessage -Text $message -Config $cfg
        Write-Info 'Notificacao enviada ao Telegram.'
    }
}

#endregion

#region --------------------------------------------------------------- persistencia

if ($DryRun) {
    Write-Warn 'DryRun: estado NAO gravado.'
    return
}

# Registra tudo que casou com os filtros nesta rodada (novo ou nao).
$addedCount = 0
foreach ($f in $pdfMatches)  { if ($seenPdfIds.Add([int]$f.id))                        { $addedCount++ } }
foreach ($n in $newsMatches) { if ($seenNewsSlugs.Add([string]$n.attributes.Slug))     { $addedCount++ } }

$maxKeep = [int]$cfg.state.maxRemembered
$state.seenPdfIds    = @($seenPdfIds | Sort-Object -Descending | Select-Object -First $maxKeep)
$state.seenNewsSlugs = @($seenNewsSlugs | Select-Object -First $maxKeep)
$state.lastPdfId     = if ($state.seenPdfIds.Count -gt 0) { [int]($state.seenPdfIds[0]) } else { 0 }

$stateIsNew = -not $state.seededAt
if ($stateIsNew) { $state.seededAt = (Get-Date).ToUniversalTime().ToString('o') }

if ($addedCount -eq 0 -and -not $stateIsNew) {
    Write-Info 'Estado inalterado: arquivo nao reescrito (evita commit vazio no Actions).'
    return
}

$state.lastChangeAt = (Get-Date).ToUniversalTime().ToString('o')
$json = [pscustomobject]$state | ConvertTo-Json -Depth 4
Set-Content -LiteralPath $StatePath -Value $json -Encoding utf8NoBOM
Write-Info "Estado gravado em $StatePath ($addedCount novo(s); PDFs: $($state.seenPdfIds.Count), noticias: $($state.seenNewsSlugs.Count))."

#endregion
