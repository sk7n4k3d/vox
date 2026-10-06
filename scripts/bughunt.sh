#!/usr/bin/env bash
# scripts/bughunt.sh — batterie de recherche de bugs en profondeur pour VOX.
#
# Pourquoi un script et pas des plugins Gradle ? Le toolchain Android de VOX a
# des planchers de version durs (AGP / Kotlin) : ajouter des plugins au build
# est risqué pour `assembleRelease`. Ici les mêmes analyseurs (detekt, ktlint,
# SpotBugs + find-sec-bugs, semgrep, trivy, osv-scanner, gitleaks) tournent en
# CLI, sans toucher au build.
#
# Outils requis (cf. fiche mémoire `infra_bughunt_tools`) : flutter, ktlint,
# detekt, spotbugs, semgrep, trivy, osv-scanner, gitleaks. SpotBugs a besoin
# du JDK et d'une compilation Gradle.
#
# Usage :
#   scripts/bughunt.sh          # batterie complète
#   scripts/bughunt.sh --fast   # saute SpotBugs (compile Gradle) et l'historique git
#
# Sortie : build/bughunt/ (rapports bruts) + build/bughunt/summary.txt

set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${VOX_BUGHUNT_OUT:-$ROOT/build/bughunt}"
FAST=0
[ "${1:-}" = "--fast" ] && FAST=1

mkdir -p "$OUT"
SUMMARY="$OUT/summary.txt"
: > "$SUMMARY"

have() { command -v "$1" >/dev/null 2>&1; }
say() { printf '%s\n' "$*" | tee -a "$SUMMARY"; }
title() { printf '\n### %s\n' "$*" | tee -a "$SUMMARY"; }
# step <nom> <log> <commande...>
step() {
  local name="$1" log="$2"; shift 2
  ( cd "$ROOT" && "$@" ) >"$log" 2>&1
  printf '%-22s exit=%-3s %s\n' "$name" "$?" "$(basename "$log")" | tee -a "$SUMMARY"
}
skip() { printf '%-22s ignoré (%s)\n' "$1" "$2" | tee -a "$SUMMARY"; }

title "VOX bug-hunt — $(date -Iseconds)"
say "racine   : $ROOT"
say "rapports : $OUT"

# ── Dart / Flutter ───────────────────────────────────────────────────────────
if have flutter; then
  step "flutter analyze" "$OUT/flutter_analyze.log" \
    bash -c 'flutter analyze lib 2>&1; exit 0'
  say "  issues : $(grep -cE '^\s+(info|warning|error) •' "$OUT/flutter_analyze.log" 2>/dev/null || true)"
else
  skip "flutter analyze" "flutter absent"
fi

# ── Kotlin : style ───────────────────────────────────────────────────────────
if have ktlint; then
  step "ktlint" "$OUT/ktlint.log" \
    bash -c 'ktlint "android/app/src/main/kotlin/**/*.kt" 2>&1; exit 0'
  say "  anomalies : $(grep -cE '\([a-z-]+:[a-z-]+\)$' "$OUT/ktlint.log" 2>/dev/null || true)"
else
  skip "ktlint" "absent"
fi

# ── Kotlin : analyse statique ────────────────────────────────────────────────
if have detekt; then
  step "detekt" "$OUT/detekt.log" \
    bash -c 'detekt --input android/app/src/main/kotlin --build-upon-default-config --base-path "$PWD" 2>&1; exit 0'
  say "  issues : $(grep -cE '\[[A-Za-z]+\]$' "$OUT/detekt.log" 2>/dev/null || true)"
else
  skip "detekt" "absent"
fi

# ── SpotBugs + find-sec-bugs (nécessite des classes compilées) ───────────────
if [ "$FAST" = "1" ]; then
  skip "spotbugs+findsecbugs" "--fast"
elif have spotbugs; then
  # NB : Flutter relocalise le build Gradle dans <repo>/build (pas android/app/build).
  ( cd "$ROOT/android" && ./gradlew :app:compileReleaseKotlin -q ) \
    >"$OUT/gradle_compile.log" 2>&1
  CLASSES="$(find "$ROOT/build/app" -type d -name kotlin-classes 2>/dev/null | head -1)"
  if [ -z "$CLASSES" ]; then
    skip "spotbugs+findsecbugs" "classes Kotlin introuvables (voir gradle_compile.log)"
  else
    PLUGINS="$(find -L /opt/bughunt/spotbugs -name 'findsecbugs-plugin-*.jar' 2>/dev/null | head -1)"
    if [ -n "$PLUGINS" ]; then
      step "spotbugs+findsecbugs" "$OUT/spotbugs.log" \
        bash -c "spotbugs -textui -effort:max -low -pluginList '$PLUGINS' -sortByClass '$CLASSES' 2>&1; exit 0"
    else
      step "spotbugs" "$OUT/spotbugs.log" \
        bash -c "spotbugs -textui -effort:max -low -sortByClass '$CLASSES' 2>&1; exit 0"
    fi
    say "  High/Medium : $(grep -cE '^H ' "$OUT/spotbugs.log" 2>/dev/null || true)/$(grep -cE '^M ' "$OUT/spotbugs.log" 2>/dev/null || true)"
  fi
else
  skip "spotbugs+findsecbugs" "absent"
fi

# ── Semgrep (règles du registre, Kotlin/Java) ────────────────────────────────
if have semgrep; then
  step "semgrep" "$OUT/semgrep.log" \
    bash -c 'semgrep scan --quiet --config p/kotlin --config p/java \
      --exclude build --exclude .dart_tool android/app/src/main/kotlin 2>&1; exit 0'
  say "  findings : $(grep -cE '^\s+(kotlin|java)\.' "$OUT/semgrep.log" 2>/dev/null || true)"
else
  skip "semgrep" "absent"
fi

# ── Dépendances & secrets ────────────────────────────────────────────────────
if have trivy; then
  step "trivy fs" "$OUT/trivy.log" \
    bash -c 'trivy fs --scanners vuln,secret,misconfig --quiet --no-progress \
      --skip-dirs build --skip-dirs .dart_tool --skip-dirs .git . 2>&1; exit 0'
  say "  sévérités : $(grep -cE '^(HIGH|CRITICAL|MEDIUM|LOW):' "$OUT/trivy.log" 2>/dev/null || true)"
fi
if have osv-scanner; then
  step "osv-scanner" "$OUT/osv.log" \
    bash -c 'osv-scanner --lockfile pubspec.lock 2>&1; exit 0'
  say "  mentions vuln : $(grep -ciE 'vulnerabilit' "$OUT/osv.log" 2>/dev/null || true)"
fi

# ── Secrets dans l'historique git ────────────────────────────────────────────
if [ "$FAST" = "1" ]; then
  skip "gitleaks (git)" "--fast"
elif have gitleaks; then
  step "gitleaks (git)" "$OUT/gitleaks.log" \
    bash -c 'gitleaks detect --source . --redact --no-banner --report-format json \
      --report-path build/bughunt/gitleaks.json 2>&1; exit 0'
  say "  findings : $(grep -oE '"RuleID"' "$OUT/gitleaks.json" 2>/dev/null | wc -l)"
fi

title "FIN — rapports bruts dans $OUT"
