# Modifications de ce fork

Ce dépôt est une copie de [pewdiepie-archdaemon/odysseus](https://github.com/pewdiepie-archdaemon/odysseus)
adaptée à un déploiement **Windows + Docker, entièrement local**. Aucun service
cloud, aucune clé d'API : chaque fonction s'appuie sur un moteur open source
tournant sur la machine.

Le projet amont est déjà conçu pour ça — ces modifications comblent surtout les
écarts qui, en pratique, laissaient des fonctionnalités silencieusement
inactives sur cet environnement.

---

## Vue d'ensemble

| Fonction | Moteur retenu |
|---|---|
| Chat, tâches, recherche | Ollama (modèles locaux) |
| Vision | `qwen2.5vl` via Ollama |
| Dictée (voix → texte) | faster-whisper, en local |
| Synthèse vocale (texte → voix) | Kokoro, conteneur dédié |
| Navigation web par l'agent | Playwright + **Firefox** |
| Recherche web | SearXNG auto-hébergé, repli DuckDuckGo |
| Embeddings / RAG | fastembed (ONNX) + ChromaDB |
| Notifications | ntfy auto-hébergé |

---

## Ce qui a changé

### `Dockerfile`

**Node.js 22 au lieu du paquet Debian.** L'image de base fournit Node 20, en
deçà de ce que réclament certains outils npm. Le binaire officiel est installé
dans `/usr/local` (prioritaire sur `/usr/bin`) après vérification de son
empreinte SHA-256 contre le manifeste signé. Le paquet Debian est conservé :
de nombreux paquets `node-*` en dépendent.

**Dépendances optionnelles intégrées à l'image.** Le projet amont les laisse
facultatives, et leur absence est silencieuse — la fonction concernée ne
répond simplement pas. Sont désormais présentes :

| Paquet | Sans lui |
|---|---|
| `faster-whisper` | la dictée est configurée mais ne transcrit rien |
| `markitdown` | les `.docx` / `.xlsx` / `.pptx` sont ignorés par le chat **et** par l'index RAG |
| `duckduckgo-search` | le repli de recherche retombe sur du scraping HTML |
| `rembg` | pas de détourage d'image dans la Galerie |
| `ripgrep` | l'outil `grep` de l'agent utilise une implémentation plus lente |

**Bibliothèques X11 de Firefox.** Le serveur MCP navigateur utilise Firefox
(voir plus bas), qui réclame `libxcb-shm`, `libX11-xcb` et `libXrandr` —
absentes de l'image *slim* et non couvertes par le jeu de dépendances de
Chromium.

> ⚠️ Tout `pip install` ou `apt install` effectué à chaud dans le conteneur
> est perdu dès la première recréation. Seul le `Dockerfile` persiste.

### `docker-compose.yml`

**Service `kokoro`** — synthèse vocale neuronale locale exposant une API
compatible OpenAI (`/v1/audio/speech`). La lecture des réponses reste donc
hors ligne, sans clé ni compte.

**`HOME=/app`** — correctif d'une incohérence : l'entrypoint abandonne ses
privilèges via `gosu`, qui *préserve l'environnement*. `HOME` restait donc à
`/root`, illisible pour l'uid 1000. Or tout le reste suppose déjà `/app`
(l'entrypoint y place la sortie de `pip install --user`). Conséquence concrète :
npx ne trouvait pas son cache, ce qui désactivait le serveur MCP navigateur.

**Volumes nommés pour le cache npx et les navigateurs Playwright.** Ces caches
ne peuvent vivre :

- ni dans la couche du conteneur — effacée à chaque recréation ;
- ni sur un montage Windows — la lecture de l'arborescence `node_modules` y
  prend une dizaine de secondes, bien au-delà du délai de la sonde de cache.

Un volume Docker (stocké côté Linux) satisfait les deux contraintes.

### `src/builtin_mcp.py`

**Firefox à la place de Chromium** (`--browser firefox`). Playwright utilise
Chromium par défaut ; Firefox lui est préféré ici comme moteur pleinement open
source porté par Mozilla. Les autres valeurs acceptées sont `chrome`, `webkit`
et `msedge`.

**Délai de la sonde de cache npx porté de 5 s à 25 s.** Cette sonde se déclenche
pendant le démarrage, alors que l'application charge aussi FastEmbed, contacte
ChromaDB et lance les autres serveurs MCP. Une recherche dans un cache déjà
peuplé coûte ~1 s au repos, mais dépassait les 5 s sous cette charge : le
serveur navigateur était alors écarté comme « non installé » alors que tout
était en place. Un cache réellement vide répond toujours instantanément, donc
cette marge ne coûte rien dans le cas d'échec légitime.

### `static/`

La lecture vocale des réponses (`TTS Mode`) était masquée dans l'interface.
Elle est réactivée et **active par défaut**, désactivable via le menu **+** du
champ de saisie.

### `scripts/`

| Script | Rôle |
|---|---|
| `Start-Odysseus.ps1` | Démarre l'environnement complet dans l'ordre : Docker, puis Ollama, puis les services, attend que l'application réponde et ouvre le navigateur. Sans effet si tout tourne déjà. |
| `Switch-HighPerf.ps1` | Bascule le chat sur un modèle plus grand, **uniquement** après avoir vérifié que le GPU monte réellement en fréquence sous charge. |
| `odysseus.ico` | Icône du raccourci, dérivée de la favicon du projet. |

`Start-Odysseus.ps1` existe parce qu'Ollama tourne sur l'hôte, pas dans Docker :
les conteneurs redémarrent seuls (`restart: unless-stopped`), lui non.

---

## Configuration hors dépôt

Les réglages vivent dans `data/`, **exclu du dépôt** par `.gitignore` — il
contient les comptes, les conversations et les clés de chiffrement. Après un
clone, il faut donc reconfigurer via l'interface : modèles par rôle (chat,
utilitaire, tâches, recherche, vision), fournisseur STT/TTS, et l'endpoint
Ollama.

Les modèles eux-mêmes se récupèrent avec `ollama pull`.

---

## Suivre les mises à jour du projet d'origine

Deux retouches touchent un fichier du projet amont et seront écrasées par un
`git pull origin dev` :

- `src/builtin_mcp.py` — le `--browser firefox`
- `src/builtin_mcp.py` — le délai de la sonde npx (5 s → 25 s)

Sans elles, le serveur MCP navigateur cesse de se charger. Le message du commit
correspondant les détaille, ce qui permet de les retrouver et de les réappliquer
après une fusion.

---

## Licence

Le projet d'origine est sous licence MIT, conservée telle quelle
(voir [`LICENSE`](LICENSE) et [`ACKNOWLEDGMENTS.md`](ACKNOWLEDGMENTS.md)).
