# App musicale privata — design

**Data:** 2026-09-12
**Stato:** proposta, in attesa di approvazione
**Nome in codice:** Prisma

---

## 1. Obiettivo

Un'app musicale personale su un solo iPhone, con libreria interamente offline. L'utente cerca un brano, lo scarica sul telefono attraverso un backend self-hosted basato su yt-dlp, e lo ascolta senza rete.

### Cosa deve fare

- Cercare brani, album e artisti con metadata puliti (titolo, artista, album, durata, copertina).
- Scaricare l'audio sul server, taggarlo, e trasferirlo sull'iPhone.
- Riprodurre offline con controlli di sistema (lock screen, AirPods, Centro di Controllo).
- Funzionare identica in casa e fuori, senza esporre porte su internet.
- Avere un'interfaccia curata, conforme a Liquid Glass, con tema configurabile.

### Cosa NON deve fare (fuori scope, esplicito)

| Fuori scope | Motivo |
|---|---|
| Pubblicazione su App Store | Verrebbe rifiutata. La distribuzione è sideload personale. |
| Multi-utente / account | Un solo utente, un solo dispositivo. |
| App CarPlay dedicata | Richiede un entitlement che Apple concede solo ad account a pagamento approvati. I controlli su schermo auto arrivano comunque via `MPRemoteCommandCenter`. |
| Sincronizzazione playlist con servizi esterni | Non serve. |
| Testi, radio, raccomandazioni algoritmiche | Complessità sproporzionata rispetto al valore. |
| Widget e Live Activity | Richiedono target aggiuntivi. Eventuale fase successiva. |
| Streaming dal server | Deciso: la libreria vive sul telefono. Lo streaming resterebbe un percorso di codice parallelo da mantenere senza motivo. |

### Criteri di successo

1. Da "cerco un brano" a "ce l'ho sul telefono" in meno di 30 secondi su rete domestica.
2. L'app riproduce in modalità aereo senza alcun degrado.
3. I download proseguono con l'app in background o schermo bloccato.
4. La libreria sopravvive a un aggiornamento dell'app (nessuna perdita di file).

---

## 2. Architettura generale

```
┌─────────────────────────────┐         ┌──────────────────────────────┐
│  your-server                │         │  iPhone                      │
│  Ubuntu 24.04 · Docker      │         │  iOS 26                      │
│                             │         │                              │
│  ┌───────────────────────┐  │         │  ┌────────────────────────┐  │
│  │ container: harmonia   │  │◄────────┼──┤ SwiftUI app            │  │
│  │  FastAPI              │  │Tailscale│  │  SwiftData (libreria)  │  │
│  │  ytmusicapi (ricerca) │  │ MagicDNS│  │  URLSession background │  │
│  │  yt-dlp + ffmpeg      │  │         │  │  AVQueuePlayer         │  │
│  │  mutagen (tag)        │  │         │  │  File system locale    │  │
│  │  Pillow (palette)     │  │         │  └────────────────────────┘  │
│  │  SQLite (catalogo)    │  │         └──────────────────────────────┘
│  └───────────┬───────────┘  │
│              │              │
│   /mnt/nas/musica/*.m4a     │
└─────────────────────────────┘
```

Tre unità indipendenti, ognuna testabile da sola:

- **Backend** — non sa nulla dell'iPhone. Espone una API HTTP. Testabile con `curl`.
- **App** — non sa nulla di yt-dlp. Parla solo la API. Testabile con un server finto.
- **Pipeline di build** — non sa nulla delle altre due. Prende un progetto Xcode, sputa un `.ipa`.

Il contratto tra backend e app è l'unico punto di accoppiamento, ed è un file OpenAPI generato automaticamente da FastAPI.

---

## 3. Backend

### 3.1 Stack

Container Docker singolo su `your-server`, gestito via `docker compose`, visibile in CasaOS.

| Componente | Ruolo |
|---|---|
| FastAPI + uvicorn | API HTTP |
| ytmusicapi | ricerca su YouTube Music |
| yt-dlp | download |
| ffmpeg | remux / transcodifica di fallback |
| mutagen | scrittura tag e copertina |
| Pillow | estrazione palette dalla copertina |
| SQLite | catalogo e coda job |

### 3.2 La scelta del formato audio (decisione non ovvia)

YouTube offre come audio migliore Opus in contenitore WebM. **AVPlayer su iOS non riproduce Opus in WebM.** Transcodificare Opus → AAC significa una seconda perdita di qualità su un file già lossy.

Soluzione: scaricare direttamente la traccia **AAC in contenitore M4A** che YouTube già fornisce (itag 140, 128 kbps), senza ricodifica. È un copy puro, istantaneo, e nativamente supportato da AVPlayer. Se per un video specifico l'M4A non esiste, si scarica Opus e si transcodifica ad AAC 192 kbps come fallback.

```
-f 'bestaudio[ext=m4a]/bestaudio'
→ se non m4a: ffmpeg -c:a aac -b:a 192k
```

Il contenitore M4A supporta anche i tag MP4 con copertina incorporata, quindi i metadata viaggiano dentro al file e sopravvivono a qualunque cosa.

### 3.3 Estrazione della palette lato server

L'estetica Prisma richiede 4 colori dominanti per brano, usati per costruire l'aura di sfondo. Farlo sul telefono significherebbe analizzare un'immagine ad ogni cambio traccia.

Si fa invece **una volta sola, sul server, al momento del download**: Pillow quantizza la copertina, si scartano i colori troppo scuri o desaturati, si ordinano per frequenza, si salvano quattro hex in SQLite. L'app li riceve già pronti dentro il JSON del brano. Costo sul telefono: zero.

### 3.4 Modello dati

```sql
tracks(
  id TEXT PRIMARY KEY,        -- videoId YouTube
  title TEXT, artist TEXT, album TEXT,
  duration_s INTEGER,
  file_path TEXT,
  file_bytes INTEGER,
  artwork_path TEXT,
  palette TEXT,               -- JSON: ["#ff2e7e","#ff9a1f","#7b2ff7","#00d4c8"]
  added_at INTEGER
)

jobs(
  id INTEGER PRIMARY KEY,
  track_id TEXT,
  state TEXT,                 -- queued | running | done | failed
  progress REAL,              -- 0.0–1.0
  error TEXT,
  created_at INTEGER
)
```

### 3.5 API

| Metodo | Path | Note |
|---|---|---|
| `GET` | `/search?q=&type=songs\|albums\|artists` | ytmusicapi, nessun download |
| `POST` | `/downloads` | body `{video_id}` → crea job, risponde 202 |
| `GET` | `/downloads` | stato di tutti i job |
| `DELETE` | `/downloads/{job_id}` | annulla |
| `GET` | `/library` | brani pronti, con palette |
| `GET` | `/library/delta?since=` | solo le modifiche dal timestamp — sincronizzazione incrementale |
| `GET` | `/tracks/{id}/file` | il file audio, **con supporto Range** |
| `GET` | `/tracks/{id}/artwork` | JPEG copertina |
| `GET` | `/health` | versione yt-dlp, spazio disco, numero brani |

**Range — verificato:** `FileResponse` di Starlette **1.6.0 implementa le richieste Range** (`_parse_range_header`, `_handle_single_range`, `_handle_multiple_ranges`), quindi non serve implementarlo a mano. Misurato sul deploy, non dedotto dalla documentazione: `curl -r 0-1023` risponde `206` con `content-range: bytes 0-1023/7069872` e 1024 byte esatti; una richiesta senza header `Range` risponde `200` con il file intero; scaricando lo stesso file in due metà e concatenandole, lo sha256 coincide con quello nel database. `accept-ranges: bytes` è annunciato sia sul 200 sia sul 206. Resta valido il motivo per cui serve: senza Range un download interrotto al 90% ripartirebbe da zero. Da riverificare se la versione di Starlette cambia.

**Coda:** un singolo worker asyncio che consuma la tabella `jobs`. Niente Celery, niente Redis: il carico è un utente e un download alla volta. Aggiungere un broker sarebbe complessità senza beneficio.

### 3.6 Il problema yt-dlp

yt-dlp si rompe periodicamente, senza preavviso, quando YouTube cambia qualcosa lato server. È il singolo punto di fragilità più prevedibile dell'intero progetto.

Mitigazione, tre livelli:
1. `pip install -U yt-dlp` all'avvio del container.
2. Restart automatico del container ogni notte (`restart: unless-stopped` + cron).
3. `/health` espone la versione di yt-dlp e la data dell'ultimo download riuscito, così quando qualcosa smette di funzionare la diagnosi è immediata invece che un'ora di confusione.

### 3.7 Storage e rete

I file finiscono in `/mnt/nas/musica/`, montato nel container. Puntando **Navidrome** (già disponibile nell'app store di CasaOS) alla stessa cartella si ottiene gratis un player web dal PC, senza scrivere una riga di codice in più.

La rete è già risolta: Tailscale è installato su entrambi i dispositivi. L'app punta a `http://your-server:8000` via MagicDNS e funziona identica ovunque. Nessuna porta aperta sul Fritz!Box, nessun DDNS, nessun certificato.

---

## 4. App iOS

### 4.1 Requisiti tecnici

- **Deployment target: iOS 26.0.** Non negoziabile: `glassEffect` non esiste prima. L'iPhone deve essere su iOS 26.
- SwiftUI, macro `@Observable`, SwiftData per la libreria locale.
- Nessuna dipendenza esterna. Ogni package è una cosa in più che può rompere la build in CI e che non puoi debuggare senza Xcode.

### 4.2 Moduli

**`APIClient`** — un attore che incapsula tutte le chiamate HTTP. Tipizzato sui modelli generati dall'OpenAPI del backend. Unica cosa che conosce l'indirizzo del server.

**`DownloadManager`** — `URLSession` con configurazione `.background(withIdentifier:)`. Questo è il pezzo che rende i download affidabili: proseguono ad app chiusa e sopravvivono al kill del sistema. Richiede un `UIApplicationDelegateAdaptor` che implementi `handleEventsForBackgroundURLSession`, altrimenti al ritorno in foreground i completamenti vanno persi silenziosamente. Al termine: sposta il file dalla cartella temporanea ad Application Support, scrive il record SwiftData, marca la URL come esclusa dal backup iCloud (altrimenti la libreria satura lo spazio iCloud).

**`PlayerEngine`** — `AVQueuePlayer`. Configura `AVAudioSession` in categoria `.playback` (senza questo, l'audio si ferma al blocco schermo e rispetta il silenzioso). Aggiorna `MPNowPlayingInfoCenter` a ogni cambio traccia e registra gli handler di `MPRemoteCommandCenter` per play/pausa/avanti/indietro/seek.

**`ThemeEngine`** — vedi sotto.

**`LibraryStore`** — SwiftData, sincronizzazione incrementale via `/library/delta`.

### 4.3 Storage su dispositivo

```
Application Support/
  Music/
    {videoId}.m4a
  Artwork/
    {videoId}.jpg
```

Non `Documents` (visibile in File e sincronizzata), non `Caches` (il sistema la cancella quando lo spazio scarseggia, e perderesti la libreria senza preavviso).

---

## 5. Design system — Prisma

### 5.1 Principio

Apple divide ogni interfaccia iOS 26 in due strati e la regola è esplicita: **il Liquid Glass va solo sul functional layer**. Controlli, tab bar, toolbar, overlay transitori. Mai sul content layer — liste di brani, griglie di copertine, testo lungo. Il vetro sul contenuto produce gerarchia confusa e testo illeggibile.

In Prisma quindi: aura colorata sul fondo, contenuto su superfici piene sopra, vetro solo su barra di ricerca, chip, mini-player e tab bar.

### 5.2 Motore dei temi

Tre modalità, selezionabili nelle impostazioni:

| Modalità | Comportamento |
|---|---|
| **Adattiva** | L'aura usa la palette del brano in riproduzione. Cambia a ogni traccia con una transizione animata. È l'identità dell'app. |
| **Preset** | Palette fissa scelta da una lista. L'aura resta ferma, l'app è cromaticamente stabile. |
| **Scuro** | Nessuna aura. Fondo quasi nero, vetro neutro. Massima leggibilità, massima autonomia batteria su OLED. |

Preset proposti — ognuno è una quadrupla di colori, non un colore singolo, perché l'aura ha quattro sorgenti:

- **Sunfracture** — magenta, ambra, viola, ciano (il default, quello dei mockup)
- **Abisso** — blu notte, teal, indaco, verde acqua
- **Brace** — rosso mattone, arancio, oro, bruno
- **Serra** — verde bosco, lime, salvia, ottanio
- **Cenere** — grigi neutri con una punta di blu (semi-monocromo)
- **Aurora** — verde menta, viola, rosa pallido, ciano

Il `ThemeEngine` è un `@Observable` che espone una singola `AuraPalette`. Chi la produce — il brano corrente, un preset, o il tema scuro — è invisibile al resto dell'app. Cambiare modalità è cambiare la sorgente, non toccare le view.

### 5.3 Il problema del contrasto (il rischio principale di Prisma)

Testo bianco su un'aura ambra chiara è illeggibile. Con la modalità adattiva la palette non è nota a priori: arriva dalla copertina e può essere qualsiasi cosa.

Soluzione a due livelli:
1. **Scrim adattivo** — sopra l'aura c'è sempre un velo scuro la cui opacità è calcolata dalla luminanza relativa della palette. Palette chiara → velo più denso. L'opacità si muove tra 0.42 e 0.78.
2. **Clamp sulla saturazione** — i colori estratti dal server vengono limitati in luminosità prima di essere usati, così nessuna copertina può produrre un'aura bianca.

Questo va verificato su almeno una dozzina di copertine reali diverse, incluse quelle bianche, nere e fluorescenti. È il punto in cui Prisma fallisce se fatto male.

### 5.4 Accessibilità

- `accessibilityReduceTransparency` attivo → tutte le superfici passano a `.glassEffect(.identity)` e diventano opache.
- `accessibilityReduceMotion` attivo → la transizione dell'aura tra un brano e l'altro è un dissolve istantaneo invece di un morph animato.

Sono due righe di codice e sono quello che separa un'app curata da una che sembra curata.

### 5.5 Note di implementazione Liquid Glass

- Il vetro non può campionare altro vetro. Elementi di vetro vicini o sovrapposti vanno racchiusi in un `GlassEffectContainer`, che stabilisce una regione di campionamento condivisa. Non è un'ottimizzazione: senza, il rendering è visibilmente sbagliato.
- `.glassEffect()` va applicato **dopo** i modificatori di layout e aspetto, mai prima.
- Per i pulsanti usare `.buttonStyle(.glass)`. La forma custom passata a `.glassEffect(_:in:)` viene ignorata in alcuni casi noti e il pulsante torna a capsula.
- `.interactive()` solo su elementi realmente toccabili.

---

## 6. Build e distribuzione

### 6.1 Pipeline

```
Windows (Claude Code) ──push──► GitHub, repo pubblico
                                      │
                                      ▼
                         GitHub Actions, runner macos-15
                         xcodebuild archive CODE_SIGNING_ALLOWED=NO
                         zip Payload/App.app → App.ipa
                                      │
                                      ▼
                         artifact scaricabile
                                      │
                                      ▼
                    Windows: Sideloadly firma con Apple ID gratuito
                                      │
                                      ▼
                              iPhone, via cavo
                                      │
                                      ▼
                    SideStore rifirma ogni 7 giorni via WiFi
```

Il runner va **pinnato** a una versione esplicita (`macos-15`, mai `macos-latest`) e la versione di Xcode va fissata. Un aggiornamento silenzioso del runner che rompe la build è impossibile da diagnosticare senza un Mac.

### 6.2 Vincoli del sideload gratuito

| Vincolo | Conseguenza |
|---|---|
| Certificato valido 7 giorni | SideStore rifirma automaticamente via WiFi. Se il telefono resta offline più di una settimana, l'app non si apre finché non la rifirmi. |
| Massimo 3 app ID a settimana | SideStore ne occupa uno, l'app un altro. Ne resta uno libero. |
| Runner macOS gratis solo su repo pubblici | Il repository va pubblico. È codice tuo, non è un problema, ma non ci vanno dentro segreti. |
| Il Mac remoto serve solo in fase UI | Previews e simulatore per costruire le schermate. Dopo, Actions basta. |

### 6.3 Configurazione

L'indirizzo del server sta in un file di configurazione locale non committato, non nel codice. Il repo è pubblico.

---

## 7. Gestione degli errori

| Scenario | Comportamento |
|---|---|
| Server irraggiungibile | L'app resta pienamente funzionante in sola lettura. La libreria locale suona. Un banner discreto segnala lo stato, niente alert modali. |
| Download fallito | Il job resta in `failed` con il messaggio di errore visibile. Retry manuale. Nessun retry automatico infinito: maschererebbe un yt-dlp rotto. |
| yt-dlp rotto | `/health` lo rende evidente. L'app mostra lo stato nelle impostazioni. |
| Spazio esaurito sull'iPhone | Controllo preventivo prima di avviare il download, confronto con lo spazio libero. |
| File corrotto | Checksum SHA-256 calcolato dal server, verificato dall'app dopo il trasferimento. File corrotto → cancellato e riscaricato. |
| Certificato scaduto | L'app semplicemente non si apre. Non è gestibile da codice, va solo saputo. |

---

## 8. Testing

**Backend** — pytest. La ricerca e il download si testano contro fixture registrate, non contro YouTube: i test non devono dipendere dalla rete né rompersi quando YouTube cambia. Un singolo test di integrazione marcato `@slow` colpisce YouTube davvero, eseguito a mano.

**App** — unit test sulla logica pura: parsing, calcolo della luminanza dello scrim, macchina a stati del download. Le view non si testano automaticamente in questo contesto: senza simulatore in CI non ha senso.

**Verifica manuale** — una checklist fissa da ripetere a ogni release, perché senza simulatore è l'unica rete di sicurezza reale: modalità aereo, blocco schermo durante il download, cambio brano da AirPods, tutte e tre le modalità tema, Reduce Transparency attivo, riavvio del telefono con download in corso.

---

## 9. Ordine di costruzione

1. **Backend completo e testato via curl.** Zero codice iOS. Se questo non funziona, tutto il resto è inutile.
2. **Pipeline di build** con un'app SwiftUI vuota. Si verifica che l'intera catena Actions → Sideloadly → iPhone funzioni prima di scriverci dentro qualcosa. Scoprire che la pipeline è rotta dopo aver scritto tremila righe è il modo peggiore di scoprirlo.
3. **App funzionale, UI grezza.** Ricerca, download, riproduzione. Bruttissima, funzionante.
4. **Design system Prisma** sul Mac remoto, con Previews.
5. **Rifinitura** — accessibilità, gestione errori, stati vuoti.

Questo ordine mette i due rischi più grandi — backend e pipeline — all'inizio, quando abbandonare costa poco.

---

## 10. Rischi noti

| Rischio | Gravità | Mitigazione |
|---|---|---|
| yt-dlp si rompe | alta probabilità, impatto medio | auto-update, `/health` diagnostico |
| Iterazione UI lenta senza Mac | certezza | design congelato prima di scrivere SwiftUI; Mac remoto in fase 4 |
| Contrasto illeggibile in modalità adattiva | media | scrim adattivo + clamp, verifica su copertine reali |
| Rifirma settimanale dimenticata | certezza nel tempo | SideStore automatico; comunque un attrito permanente del progetto |
| iPhone non su iOS 26 | bloccante | da verificare **prima** di iniziare |
