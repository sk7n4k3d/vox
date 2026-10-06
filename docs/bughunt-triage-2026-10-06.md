# VOX — triage de la batterie bug-hunt (2026-10-06)

Première passe de la batterie `scripts/bughunt.sh` sur `feature/ux-refonte`.
Objet : séparer le signal du bruit. **Aucun bug neuf confirmé** ; le code est
déjà durci là où ça compte.

## Résultats bruts

| Outil | Sortie | Verdict |
|---|---|---|
| `flutter analyze` | 6 | préexistants, cosmétiques (déprécations M3 + ordre d'imports) |
| `ktlint` | 908 | **formatage uniquement** (`standard:*`) — aucun bug |
| `detekt` | 433 | surtout du style ; 15 `SwallowedException` + 93 `TooGenericExceptionCaught` |
| `SpotBugs + find-sec-bugs` | 9 High / 82 Medium | voir triage ci-dessous |
| `semgrep` (registre Kotlin/Java) | 0 | rien |
| `trivy` | 0 | rien |
| `osv-scanner` | 0 | aucune vuln dans `pubspec.lock` |
| `gitleaks` (historique) | 714 | **faux positifs** (lockfile, doc, bundles web) |

## Triage des findings SpotBugs / find-sec-bugs

**Faux positifs — `ST_WRITE_TO_STATIC_FROM_INSTANCE_METHOD` (9 High).**
Tous portent sur des singletons dont le champ est explicitement `@Volatile` :
`SmsBridge.onSmsReceived` / `onMmsReceived` / `onMmsSendResult`,
`SmsNotifier.activeThreadId`, `WearBridge.refreshRequestedCallback` /
`voiceReceivedCallback` / `messagesRequestedCallback`. Écriture délibérée,
visibilité mémoire assurée. → exclus via `.spotbugs-exclude.xml`.

**Faux positifs — `EI` / `EI2` (« expose internal representation », 37).**
Systématique sur les data classes Kotlin à `ByteArray`/`HashSet`
(`MmsPduComposer.Part`, `SmsBridge.listContacts$2$Acc`). Non actionnable.
→ exclus via `.spotbugs-exclude.xml`.

**Déjà mitigés — règles `SEC*` de find-sec-bugs (20), volontairement laissées
visibles :**

- `SECSSSRFUC` (SSRF) × 3 — `MmsHttpClient.kt` **valide déjà** le schéma
  (`http`/`https`) et l'hôte (`isBlockedHost` : loopback/link-local) avant
  d'envoyer le PDU ; `LlmSuggestions.kt` utilise une URL venue des **réglages
  utilisateur**, pas d'un tiers. Le RFC1918 est laissé ouvert volontairement
  (proxy MMS opérateur).
- `SECPTI` (path traversal) × 13 — `MmsPduProvider.fileForName` a sa garde
  `canonicalPath.startsWith(dir + File.separator)` ; les autres sites
  construisent des `File(cacheDir, "part_$partId…")` avec un `partId` Long venu
  du provider, et les noms réseau passent par `MmsRetrieveParser.sanitizeName`.
- `SECXML` × 1 — `buildSmil` applique bien `xmlAttr(p.contentLocation)`.
- `SECUNI` × 2, `SECEFA` × 1 — non qualifiés comme exploitables.

## Bruit neutralisé (pour que la prochaine passe soit lisible)

- `.gitleaks.toml` : allowlist des chemins qui matchent par heuristique
  (`macos/Podfile.lock`, `PRIVACY.md`, `android/app/google-services.json`,
  `*.js.map`, `web/`, `nightly/`, artefacts de build). 714 → attendu ~0.
- `.spotbugs-exclude.xml` : `EI`/`EI2` + les 3 classes à champ `@Volatile`.

Les règles `SEC*` **ne sont pas** exclues : elles resteront visibles pour qu'un
changement futur réel ne passe pas sous le radar.

## À traiter plus tard (vrai gisement, non urgent)

`detekt` — 15 `SwallowedException` : les occurrences échantillonnées
(`SmsDeliverReceiver`, `SmsBridge` sniff MIME, `ContentUris.parseId`) sont des
`try/catch` best-effort délibérés. À repasser quand la liste sera réduite par
une baseline detekt.
