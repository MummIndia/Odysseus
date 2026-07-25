***Français** · [English](MODIFICATIONS.en.md)*

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

### `src/tool_index.py`

**Les outils navigateur inutilisables monopolisaient la sélection.** La
sélection d'outils est un top-8 sémantique, et `@playwright/mcp` expose à lui
seul 30 outils. Mesuré sur trois requêtes de navigation typiques, l'agent
recevait `browser_drop`, `browser_handle_dialog`, `browser_close`,
`browser_console_messages` et toute la famille souris-XY — mais
**`browser_navigate` était absent 2 fois sur 3**. Sur « clique sur le bouton
de connexion », 6 créneaux sur 8 partaient dans les primitives de souris.

Sans l'outil qui ouvre une page, tous les autres sont morts. Le modèle
répondait donc, exactement, qu'il ne pouvait pas aller sur internet — et cette
réponse était juste.

Deux garde-fous :

- `MCP_INDEX_DENIED` — 18 outils écartés de l'index (primitives de pointage,
  aides au débogage, plomberie de session, et `browser_run_code_unsafe` qui
  exécute du JavaScript arbitraire). Ils restent connectés et appelables, ils
  ne concourent simplement plus pour un créneau.
- `MCP_COMPANIONS` — si un outil navigateur est retenu, `browser_navigate` et
  `browser_snapshot` sont ajoutés d'office. Le préfixe est repris du résultat
  lui-même, donc la règle tient quel que soit l'identifiant du serveur.

Après correction, sur les mêmes trois requêtes : `browser_navigate` présent
3 fois sur 3, aucun outil écarté ne passe, et les créneaux ne contiennent plus
que des outils utiles (`navigate`, `snapshot`, `find`, `click`, `type`,
`press_key`, `select_option`). L'application indexe 12 outils MCP au lieu de 30.

### `src/agent_loop.py`

**Naviguer n'est pas lire.** `browser_navigate` renvoie le titre de la page et
une *référence* de snapshot, jamais le texte. Mesuré : à qui demande d'ouvrir
une URL et de la résumer, l'agent appelait `browser_navigate`, constatait
`exit_code=0`, répondait « la page s'est chargée avec succès » et s'arrêtait —
sans avoir rien lu. Une consigne le précise désormais : navigate n'est jamais
la dernière étape, il faut enchaîner sur `browser_snapshot` (ou `browser_find`),
et `web_fetch` suffit en un seul appel quand il s'agit seulement de lire.

La consigne interdit aussi le paramètre `filename` de `browser_snapshot`, dont
le schéma dit : « Save snapshot to markdown file *instead of returning it in the
response* ». Le modèle en inventait un et recevait alors un chemin de fichier au
lieu du contenu — 175 caractères de référence contre 1634 de contenu réel une
fois le paramètre omis.

Cette consigne n'est injectée que si des outils navigateur figurent dans la
sélection du tour — elle ne coûte rien aux autres requêtes.

### `static/js/chat.js`

**Une erreur contenant « tool » suffisait à désactiver le mode agent.** Le test
portait sur `errText.includes('tool') || errText.includes('auto')`, donc
n'importe quel échec sans rapport — un outil qui expire, un serveur MCP qui
tombe, un message mentionnant « automatic » — déclenchait trois effets :
le message d'erreur réel était remplacé par « This model doesn't support agent
tools », l'interface repassait en mode Chat, et ce choix était **écrit dans
`localStorage`**. Les messages suivants de la conversation partaient donc sans
outils. Cela se présentait comme « le mode agent marche dans une conversation
neuve mais plus dans celle-ci ».

Le test porte désormais sur la formulation réellement émise par le fournisseur
(Ollama : `<modèle> does not support tools`), et le message d'origine est
conservé.

### `config/searxng/settings.yml`

**Le jeu de moteurs par défaut ne renvoyait rien.** SearXNG interroge ses
moteurs en parallèle et fusionne : une requête groupée ne vaut donc que ce que
vaut son plus mauvais moteur. Mesuré depuis cette machine, une recherche
courante renvoyait **zéro résultat**, brave répondant « too many requests »
pendant que duckduckgo et startpage servaient un CAPTCHA.

Interrogés un par un : bing et duckduckgo renvoient 10 résultats chacun ;
google, mojeek, qwant, startpage et brave sont morts ou bloqués. Ces cinq-là
sont désactivés. La paire restante renvoie 11 à 20 résultats de façon stable.

Ce sont des moteurs derrière une IP résidentielle, pas une infrastructure
figée : à revérifier si les résultats s'appauvrissent.

### `src/builtin_mcp.py`

**Firefox à la place de Chromium** (`--browser firefox`). Playwright utilise
Chromium par défaut ; Firefox lui est préféré ici comme moteur pleinement open
source porté par Mozilla. Les autres valeurs acceptées sont `chrome`, `webkit`
et `msedge`.

**Environnement transmis aux serveurs MCP.** `_connect_stdio` construisait
`env={**os.environ, **env} if env else None`. Or `None` ne signifie pas
« hérite » : le SDK MCP y substitue un environnement minimal. Les serveurs
Python passaient `PYTHONPATH`, donc héritaient de tout ; le serveur npx ne
passait rien et perdait `PLAYWRIGHT_BROWSERS_PATH`. Il cherchait alors les
navigateurs dans le cache par défaut et signalait `Browser "firefox" is not
installed` — avec le navigateur installé un dossier plus loin.

**Reconnexion des serveurs MCP intégrés.** Une session peut disparaître sans
que le processus meure (fermeture stdio à cheval sur deux tâches asyncio). La
reconnexion existante ne se déclenchait qu'en cas d'exception, ce qui suppose
une session ; l'absence de session était donc définitive. Elle est désormais
tentée aussi dans ce cas, et couvre les serveurs npx — le navigateur en était
exclu par un test d'appartenance au seul dictionnaire des serveurs Python.

> ⚠️ Les navigateurs doivent être installés avec la version de Playwright
> qu'embarque `@playwright/mcp`, pas avec le paquet `playwright` autonome :
> les numéros de build diffèrent et le serveur refuse celui qu'il n'attend pas.
> `npx @playwright/mcp@latest install-browser firefox`, en uid 1000. Ils vivent
> dans le volume `playwright-browsers`, donc hors de l'image.

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

### Réglages qui ont fait la différence

Sur une machine modeste, ces quatre points ont plus d'effet que le choix du
modèle lui-même :

| Réglage | Valeur | Pourquoi |
|---|---|---|
| `disabled_tools` | ne garder que 13 outils | Un petit modèle choisit mal parmi 29 options : il tournait en boucle sur `api_call`/`app_api`. Conserver de quoi coder et agir (`bash`, `python`, `ls`, `glob`, `grep`, `read_file`, `write_file`, `edit_file`, `web_search`, `web_fetch`, `manage_memory`, `ask_user`, `update_plan`) et écarter le reste. |
| Un seul modèle par rôle | chat = utilitaire = tâches | Un modèle distinct par rôle en maintient plusieurs en VRAM simultanément. |
| `OLLAMA_CONTEXT_LENGTH` | 8192 | Le prompt système compact plus les schémas d'outils pèsent ~4 200 tokens : sous la valeur par défaut de 4096, Ollama tronque et le modèle affirme ne pas avoir les outils qu'il vient de recevoir. Le dimensionner sur le besoin mesuré — le surplus se paie intégralement en mémoire. |
| `OLLAMA_KEEP_ALIVE` | `-1` | Évite de recharger plusieurs Go après cinq minutes d'inactivité. À ne combiner avec un contexte large qu'en surveillant la VRAM. |

### Le piège de l'interrupteur « web »

Dans le champ de saisie, l'interrupteur web ne fait pas qu'autoriser la
recherche : en mode agent, `allow_web_search` absent retire **`web_search` et
`web_fetch`** (`routes/chat_routes.py`). Interrupteur éteint, l'agent n'a donc
aucun moyen de lire une URL, y compris une URL collée explicitement dans le
message — et il le dit, ce qui se lit à tort comme un refus ou une
hallucination.

C'est le comportement voulu : cet interrupteur est le consentement explicite à
sortir sur le réseau, et le garder éteint par défaut est le bon réglage pour
une installation locale. Il faut simplement savoir que **« ouvre cette page »
exige de l'activer d'abord**. Même logique pour l'interrupteur bash, qui seul
donne `bash`.

⚠️ Sous Windows, redémarrer Ollama demande de tuer **`llama-server`** en plus
d'`ollama` : les modèles sont tenus par ces processus enfants, et un filtre
`ollama*` les laisse orphelins avec leur allocation. Chaque redémarrage
incomplet fuit alors la valeur d'un modèle entier en VRAM, jusqu'à ce que les
générations soient coupées en cours (`peer closed connection`, erreur 502).
Comparer `ollama ps` et `nvidia-smi` révèle l'écart.

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
