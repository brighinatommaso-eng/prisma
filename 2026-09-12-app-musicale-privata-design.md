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

Riferimento visivo: `docs/prisma-prototipo.html`, prototipo interattivo delle cinque
schermate. In caso di divergenza tra questo testo e il prototipo, vince il prototipo per
la disposizione e questo testo per i valori.

### 5.1 Principio

Apple divide ogni interfaccia iOS 26 in due strati e la regola è esplicita: **il Liquid
Glass va solo sul functional layer**. Controlli, tab bar, toolbar, overlay transitori.
Mai sul content layer — liste di brani, griglie di copertine, testo lungo.

In Prisma quindi: aura colorata sul fondo, contenuto su superfici piene sopra, vetro solo
su tab bar, mini-player, campo di ricerca, chip e pulsante play principale.

### 5.2 Le quattro modalità

Selezionabili in Impostazioni → Aspetto.

| Modalità | Comportamento |
|---|---|
| **Adattivo** | L'aura usa la palette del brano in riproduzione, cioè i quattro colori che il backend calcola al download e consegna nel campo `palette`. Cambia a ogni traccia con una transizione animata. È l'identità dell'app. |
| **Preset** | Palette fissa scelta tra le dodici della tabella 5.3. L'aura resta ferma. |
| **Nero** | Nessuna aura. Fondo pieno `#08090A`, neutro. Il vetro resta identico alla modalità scura. Massima leggibilità e minimo consumo su OLED. |
| **Bianco** | Nessuna aura. Fondo pieno `#EFEFF2`. **Il vetro si inverte** — vedi 5.5. |

Nelle modalità Nero e Bianco non esiste alcuna sfumatura: nessuna aura, nessuno scrim,
nessun gradiente di fondo. Sono temi piatti, con il vetro come unico elemento traslucido.

Le copertine degli album restano a colori in tutte e quattro le modalità.

### 5.3 Preset

Ogni preset è una quadrupla, perché l'aura ha quattro sorgenti.

| Nome | c1 | c2 | c3 | c4 |
|---|---|---|---|---|
| Prisma (default) | `#1e26b6` | `#e73b86` | `#fba402` | `#00d4c8` |
| Abisso | `#06283d` | `#1363df` | `#47b5ff` | `#0a9396` |
| Brace | `#7c2d12` | `#dc2626` | `#f59e0b` | `#fde047` |
| Serra | `#14532d` | `#4d7c0f` | `#84cc16` | `#0f766e` |
| Cenere | `#312e40` | `#4b5563` | `#6b7280` | `#94a3b8` |
| Aurora | `#134e4a` | `#7c3aed` | `#f472b6` | `#22d3ee` |
| Nebulosa | `#2e1065` | `#6d28d9` | `#a78bfa` | `#ec4899` |
| Agrume | `#b45309` | `#f97316` | `#facc15` | `#65a30d` |
| Laguna | `#0c4a6e` | `#0891b2` | `#22d3ee` | `#5eead4` |
| Vinile | `#451a03` | `#92400e` | `#d97706` | `#fbbf24` |
| Neon | `#c026d3` | `#22d3ee` | `#a3e635` | `#f43f5e` |
| Crepuscolo | `#1e1b4b` | `#4338ca` | `#f472b6` | `#fb923c` |

Il preset **Prisma** è la palette dell'icona dell'app. Icona e schermata in riproduzione
devono leggersi come la stessa cosa: è il motivo per cui è il default.

### 5.4 Motore dei temi

Il `ThemeEngine` è un `@Observable` che espone una singola `AuraPalette` più un
`SurfaceStyle`. Chi produce la palette — il brano corrente, un preset, o niente nelle
modalità monocromatiche — è invisibile al resto dell'app. Cambiare modalità significa
cambiare la sorgente, non toccare le view.

La modalità scelta si persiste. All'avvio l'app riapre con l'ultima usata.

### 5.5 Il vetro nelle due polarità

Questa è la parte che non si può improvvisare in fase di implementazione.

Su fondo scuro il vetro è bianco translucido con bordo chiaro: si stacca perché è più
luminoso di ciò che ha sotto. **Su fondo chiaro la stessa ricetta sparisce** — bianco su
bianco, bordo invisibile, la tab bar diventa un rettangolo che non si vede.

In modalità Bianco quindi si invertono tre cose:

- il **bordo** passa da chiaro a scuro, `rgba(13,13,16,.11)`
- il **riflesso interno** diventa bianco quasi pieno, `rgba(255,255,255,.95)`
- le **etichette** passano a `#0d0d10` e le loro gerarchie secondarie a opacità 60% e 40%

L'ombra esterna si ammorbidisce e si scurisce: `0 8px 26px rgba(13,13,16,.13)`.

In SwiftUI questo corrisponde a usare `.glassEffect(.regular)` con `colorScheme`
coerente, non a ridipingere i materiali a mano.

### 5.6 Contrasto in modalità adattiva

È il rischio principale di Prisma. Testo bianco su un'aura ambra chiara è illeggibile, e
con la modalità adattiva la palette non è nota a priori.

Due livelli:

1. **Scrim adattivo** — sopra l'aura c'è sempre un velo scuro la cui opacità è calcolata
   dalla luminanza relativa della palette. Palette chiara → velo più denso. L'opacità si
   muove tra 0.42 e 0.78.
2. **Clamp sulla luminosità** — i colori estratti dal server vengono limitati prima
   dell'uso, così nessuna copertina può produrre un'aura bianca.

Va verificato su almeno una dozzina di copertine reali, incluse bianche, nere e
fluorescenti. È il punto in cui Prisma fallisce se fatto male.

Nelle modalità Preset, Nero e Bianco lo scrim non esiste: i fondi sono noti e il
contrasto è fissato a priori.

### 5.7 Accessibilità

- `accessibilityReduceTransparency` attivo → tutte le superfici passano a
  `.glassEffect(.identity)` e diventano opache.
- `accessibilityReduceMotion` attivo → la transizione dell'aura tra un brano e l'altro è
  un dissolve istantaneo invece di un morph animato.

Sono due righe di codice e separano un'app curata da una che sembra curata.

### 5.8 Struttura delle schermate

Quattro tab più il player a schermo intero, e la pagina playlist spinta dentro Libreria.

| Schermata | Vetro | Note |
|---|---|---|
| **Libreria** | chip, mini-player, tab bar | Titolo grande, chip Album / Playlist / Preferiti, album con copertina 62pt e righe brano sotto. Stato di download come icona a destra di ogni riga: spunta nel colore d'accento se scaricato, freccia attenuata se no, anello di avanzamento durante il download, equalizzatore animato sul brano in riproduzione. |
| **Playlist** | pulsante Casuale, mini-player, tab bar | Mosaico 2×2 dalle prime quattro copertine di album distinte, nome, "N brani · N min", poi **Riproduci** pieno e **Casuale** in vetro affiancati, poi i brani e infine "Scarica N brani mancanti" quando serve. Casuale avvia la riproduzione già in ordine casuale. |
| **Cerca** | campo di ricerca, mini-player, tab bar | Risultati con miniatura 46pt e stato di download come icona. |
| **Download** | mini-player, tab bar | Sezioni In corso / Non riuscito / Annullati / Scaricati, con anello di avanzamento sulla copertina. Gli errori si leggono in linguaggio semplice ("Impossibile raggiungere il server"); codice, URL e pulsante di copia restano a un tocco, dietro "Mostra dettagli tecnici". |
| **Impostazioni** | campo server, card, segmenti, preset | Server, stato, Aspetto, info. |
| **Player** | solo il pulsante play | Riga di contesto in alto ("In riproduzione da" e la sorgente) con chiusura a sinistra e menu a destra; copertina grande con ombra profonda; titolo e artista con il cuore a destra; barra di avanzamento; trasporto; in basso coda e AirPlay. Quasi senza vetro di proposito: lì il contenuto è la musica, e frapporre pannelli la allontana. |

Il mini-player è presente su tutte e quattro le tab, e su ogni schermata spinta dentro
una tab, e scompare nel player a schermo intero.

**Le righe di contenuto sono trasparenti.** Una riga non ha sfondo proprio: la
separazione è solo un filo sottile, e l'aura si vede di continuo dietro l'intera lista,
non soltanto negli spazi tra le sezioni. Vale per Libreria, Cerca, Download, playlist e
preferiti. Nell'interfaccia principale non compaiono dati diagnostici — dimensioni in
byte, tempi in millisecondi, id, codici d'errore grezzi: le durate sostituiscono le
dimensioni, e i dettagli tecnici restano raggiungibili dietro "Mostra dettagli tecnici".

### 5.9 Note di implementazione

- Il vetro non può campionare altro vetro. Elementi vicini o sovrapposti vanno racchiusi
  in un `GlassEffectContainer`, che stabilisce una regione di campionamento condivisa. Non
  è un'ottimizzazione: senza, il rendering è visibilmente sbagliato.
- `.glassEffect()` va applicato **dopo** i modificatori di layout e aspetto, mai prima.
- Per i pulsanti usare `.buttonStyle(.glass)`. La forma custom passata a
  `.glassEffect(_:in:)` viene ignorata in alcuni casi noti e il pulsante torna a capsula.
- `.interactive()` solo su elementi realmente toccabili.
- Il mini-player va spostato sullo slot nativo `tabViewBottomAccessory` di iOS 26.
  L'implementazione attuale è una barra costruita a mano, scelta deliberatamente durante
  la fase funzionale per evitare lo stile vetro automatico. Con il design attivo lo slot
  nativo è preferibile: si integra con la tab bar e il vetro lo gestisce il sistema.
- L'inset del mini-player va applicato **dentro** ogni `NavigationStack`, non fuori: un
  safe area inset applicato all'esterno non attraversa il contenitore UIKit e le liste
  finiscono sotto la barra. Ogni schermata spinta dentro una tab deve applicare lo stesso
  modificatore.

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
