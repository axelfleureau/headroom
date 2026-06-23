# Headroom × MiniMax — Native MiniMax M3 / M2.7 Backend (v3)

This fork of [`chopratejas/headroom`](https://github.com/chopratejas/headroom)
adds **first-class MiniMax provider support** for the **Mavis Code gateway**
(`agent.minimax.io`).

## Architettura finale (zero-patch)

```
Mavis Code (or any Anthropic-compat client)
   ↓  (sends Token: <jwt> header automatically)
http://127.0.0.1:8788   ←  headroom raw (no auth shim)
   ↓  (passes ALL client headers intatti, including Token)
agent.minimax.io/mavis/api/v1/llm/v1
   ↓
MiniMax M3 / M2.7 / M2.7-highspeed
```

**Nessuna patch al package headroom-ai.** Headroom funziona come proxy
Anthropic-compat raw: passa i client headers al gateway MiniMax. Il client
(Mavis Code, Claude Code, OpenCode) manda già `Token: <jwt>` con il session
JWT — headroom non deve fare nulla.

### Perché questa architettura

Tre lezioni dall'analisi del codice reale di Mavis Code
(`daemon.js`, riga 69981 e 241860):

1. **Mavis Code gestisce `Token: <jwt>`** tramite `authTokenProvider: () =>
   readMavisAuthToken()` — non usa `Authorization: Bearer` per managed providers
2. **I managed providers** sono identificati da URL host: `agent.minimax.io`,
   `agent.minimaxi.com`, `matrix-*.xaminim.com` (vedi `MANAGED_PROVIDER_HOSTS`)
3. **Il JWT vive nel localStorage** di Mavis Code a
   `~/Library/Application Support/MiniMax Agent/Local Storage/leveldb/`

Patchare il package headroom-ai per re-injectare il token è fragile (si rompe a
ogni upgrade di headroom-ai). Molto meglio lasciare che Mavis Code gestisca
l'auth da solo, e headroom resti un proxy trasparente.

---

## Installazione (utente finale)

### Requisiti

- macOS con [Mavis Code](https://agent.minimax.io) installato e loggato
- [headroom-ai](https://github.com/chopratejas/headroom) installato
- `uv tool install headroom-ai[proxy]` (per le dipendenze fastapi/uvicorn)

### One-shot

```bash
git clone https://github.com/axelfleureau/headroom.git ~/headroom
mkdir -p ~/.mavis/bin
cp ~/headroom/scripts/minimax-deploy/* ~/.mavis/bin/
headroom-minimax-enable.sh --yes
```

Lo script:
1. estrae il JWT session dal localStorage di Mavis Code
2. lo salva nel keychain macOS
3. scrive il plist `com.headroom.minimax-enable` (porta 8788, profilo separato)
4. avvia il proxy
5. verifica `/v1/messages` end-to-end con un modello MiniMax reale
6. rollback automatico se qualcosa fallisce

### Uso

```bash
# Imposta ANTHROPIC_BASE_URL al proxy headroom-MiniMax (con fallback automatico)
minimax-with-fallback.sh claude
minimax-with-fallback.sh --model MiniMax-M3

# Oppure manuale
ANTHROPIC_BASE_URL=http://127.0.0.1:8788 \
ANTHROPIC_MODEL=MiniMax-M3 \
claude
```

### Comandi installati in `~/.mavis/bin/`

| Script | Cosa fa |
| :----- | :------ |
| `headroom-minimax-enable.sh` | Abilita opt-in (porta 8788, no patch) |
| `headroom-minimax-disable.sh` | Rollback totale (headroom pulito + keychain pulito) |
| `headroom-minimax-status` | Diagnostica read-only completa |
| `minimax-token-fetch.sh` | Estrae JWT dal localStorage Mavis Code |
| `minimax-with-fallback.sh` | Wrapper con fallback automatico proxy↔diretto |

---

## Modelli supportati

| Modello | Context | Note |
| :------ | :------ | :---- |
| `MiniMax-M3` | 450K | Multimodal (text+image+video), flagship |
| `MiniMax-M2.7-highspeed` | 200K | Text only, latenza minima |
| `MiniMax-M2.7` | 200K | Text only, ragionamento profondo |

Tutti supportano thinking blocks (`thinking: { type: "adaptive" }`).

---

## Refresh del token (ogni ~30 giorni)

Quando Mavis Code refresha il token (login/logout, expiry), il vecchio JWT
diventa invalido. Per refreshare:

```bash
# Refresh manuale
minimax-token-fetch.sh > /tmp/token.txt
security add-generic-password -s minimax-session-token -a mavis-code -w "$(cat /tmp/token.txt)" -U
rm /tmp/token.txt
launchctl kickstart -k gui/$(id -u)/com.headroom.minimax-enable
```

(Oppure rieseguire `headroom-minimax-enable.sh --yes` che fa tutto in automatico.)

Per refresh automatico ogni 6h, installare il LaunchAgent opzionale (vedi sezione
seguente).

---

## Comportamento fallback

Il wrapper `minimax-with-fallback.sh` testa `127.0.0.1:8788/health` ad ogni
invocazione:

- **Proxy attivo** → `ANTHROPIC_BASE_URL=http://127.0.0.1:8788` (headroom con
  SmartCrusher + cache alignment + saving)
- **Proxy giù** → `ANTHROPIC_BASE_URL=https://agent.minimax.io/mavis/api/v1/llm/v1`
  (gateway diretto, nessuna ottimizzazione ma funziona)

Logica safe: il proxy è opzionale, **mai bloccante**. Se headroom-MiniMax va giù
per qualsiasi motivo (crash, port occupata, ecc.), il wrapper ripiega sul
gateway diretto in <100ms.

---

## Troubleshooting

### "401 token is required" via proxy

Causa: il JWT è scaduto. Soluzione:
```bash
headroom-minimax-enable.sh --yes  # ri-estrae token live
```

### "401 auth failed" via gateway diretto

Causa: token scaduto, Mavis Code non loggato. Soluzione: apri Mavis Code, fai
login, invia un messaggio per generare un nuovo token.

### Proxy non si avvia su 8788

```bash
headroom-minimax-status              # diagnostica completa
lsof -iTCP:8788                      # chi sta occupando la porta?
```

### Cache alignment non si attiva

Lo SmartCrusher richiede conversazioni >500 token. Con chiamate piccole
(smoke test), il saving è 0%. Per saving reale, usa sessioni multi-turno con
system prompt stabile.

---

## Come funziona l'auth (deep dive)

### Client → headroom (pass-through)

Il client (Mavis Code o curl) manda:
```
POST http://127.0.0.1:8788/v1/messages
Authorization: Bearer <fake or absent>
Token: eyJ... (solo Mavis Code lo manda)
anthropic-version: 2023-06-01
Content-Type: application/json
{"model": "MiniMax-M3", ...}
```

### headroom → gateway (pass-through)

Headroom aggiunge `content-type: application/json` e forwarda **tutti gli altri
headers intatti** all'upstream `https://agent.minimax.io/mavis/api/v1/llm/v1`:
```
POST /v1/messages
Token: eyJ... (passato invariato)
anthropic-version: 2023-06-01
Content-Type: application/json
{"model": "MiniMax-M3", ...}
```

### Gateway → headroom → client

Il gateway valida il JWT, chiama M3/M2.7, e ritorna la risposta. Headroom la
forwarda al client intatta (applica solo SmartCrusher/cache alignment al body
prima di forwardarlo upstream).

### Perché "pass-through" funziona

Il gateway `agent.minimax.io` riconosce l'header `Token: <jwt>` come managed
provider auth (vedi `MANAGED_PROVIDER_HOSTS` in `daemon.js`). Headroom non
deve manipolare l'auth — è già corretta.

---

## File modificati

| File | Cosa |
| :--- | :--- |
| `headroom/providers/minimax.py` | `MiniMaxProvider` con M3/M2.7 metadata |
| `headroom/providers/registry.py` | Wire minimax in api_overrides/targets |
| `headroom/proxy/models.py` | `minimax_api_key/url/session_token` fields |
| `headroom/cli/proxy.py` | `--backend minimax` + flag CLI |
| `scripts/minimax-deploy/*.sh` | Script operativi (enable/disable/status/fetch/fallback) |
| `README-MINIMAX.md` | Questa doc |

**Totale patch al package headroom-ai**: ZERO. La patch precedente è stata
rimossa perché Mavis Code già gestisce l'auth lato client.

---

## License

Apache-2.0, same as upstream.
---

## Auto-refresh del token (opzionale ma raccomandato)

Il token JWT scade ogni ~30 giorni. Per refresh automatico, dopo aver eseguito
`headroom-minimax-enable.sh`, viene installato un secondo LaunchAgent
(`com.headroom.minimax-token-refresher`) che gira ogni 6 ore:

```bash
# Dopo enable, verifica:
launchctl print gui/$(id -u)/com.headroom.minimax-token-refresher
# → state=running

# Log:
tail -f ~/.headroom/logs/token-refresher.log
```

Comportamento:
- **token invariato** → log `unchanged (exp ...)`, nessuna azione
- **token cambiato** → log `updated (exp ...)`, aggiorna keychain + kickstart
- **Mavis Code non loggato** → log warning, keychain NON modificato

Sicuro: mai loggato in chiaro. Idempotente: puoi rieseguire a mano quando vuoi.

