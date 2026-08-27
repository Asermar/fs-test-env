#!/bin/bash
# =============================================================================
# Testing de MUTACIÓN sobre un escenario de test de un plugin.
#
# Responde a una pregunta que la cobertura no responde: **¿los tests fallarían si el
# código estuviera mal?** Introduce fallos de verdad —invierte una condición, cambia un
# operador, quita una llamada— y cuenta cuántos caza la suite. Un fallo que ningún test
# detecta es un «mutante superviviente», y cada superviviente es una comprobación que
# creíamos tener y no tenemos.
#
# Es la versión automática de lo que había que hacer a mano: neutralizar una guarda y ver
# si el test se pone rojo. Hacerlo a mano sólo cubre lo que a uno se le ocurre mirar.
#
# ## Por qué vive aquí y no en el core del test-env
#
# El core es un CLON de FacturaScripts al que la provisión hace `git pull` y
# `composer install`. Una dependencia añadida allí se perdería en la siguiente provisión o
# daría conflicto al actualizar. Así que Infection se instala en este repo (`fs-test`) y
# desde aquí se apunta al core.
#
# ## Uso
#
#   bin/test-env-mutacion.sh <plugin> [escenario] [subdirectorio]
#
#   bin/test-env-mutacion.sh OSBCae                     todo el plugin, escenario main
#   bin/test-env-mutacion.sh OSBCae main Lib            sólo Lib/
#   bin/test-env-mutacion.sh BusCanarias rutas Lib/Rutas
#
# El subdirectorio importa: sin él se mutan también controladores y vistas, que ningún
# test toca, y el resultado queda enterrado en supervivientes que no dicen nada.
#
# Variables: FS_PROJECT_ROOT, TESTENV_DIR, MSI_MINIMO (umbral para el código de salida).
# =============================================================================
set -euo pipefail

C_STEP=$'\033[1;36m'; C_OK=$'\033[1;32m'; C_WARN=$'\033[1;33m'; C_ERR=$'\033[1;31m'
C_DIM=$'\033[2m'; C_RESET=$'\033[0m'
log_step() { printf '%s[%s] >> %s%s\n' "$C_STEP" "$(date +%H:%M:%S)" "$*" "$C_RESET"; }
log_ok()   { printf '%s[%s] OK %s%s\n' "$C_OK" "$(date +%H:%M:%S)" "$*" "$C_RESET"; }
log_warn() { printf '%s[%s] !! %s%s\n' "$C_WARN" "$(date +%H:%M:%S)" "$*" "$C_RESET"; }
log_err()  { printf '%s[%s] ERROR %s%s\n' "$C_ERR" "$(date +%H:%M:%S)" "$*" "$C_RESET" >&2; }
log_info() { printf '   %s%s%s\n' "$C_DIM" "$*" "$C_RESET"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTBIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
FS_PROJECT_ROOT="${FS_PROJECT_ROOT:-$(cd "$TESTBIN_DIR/.." && pwd)}"
TESTENV_DIR="${TESTENV_DIR:-$FS_PROJECT_ROOT/test-env/facturascripts}"
MSI_MINIMO="${MSI_MINIMO:-0}"

PLUGIN="${1:-}"
ESCENARIO="${2:-main}"
SUBDIR="${3:-}"

# --- PRECONDICIONES: fallar antes de tocar nada, y decir cómo se arregla ------------
[ -n "$PLUGIN" ] || { log_err "falta el plugin. Uso: $(basename "$0") <plugin> [escenario] [subdirectorio]"; exit 2; }

INFECTION="$TESTBIN_DIR/vendor/bin/infection"
if [ ! -x "$INFECTION" ]; then
    log_err "no está Infection. Instálalo con:  ( cd $TESTBIN_DIR && composer install )"
    exit 2
fi

PLUGIN_SRC="$FS_PROJECT_ROOT/src/Plugins/$PLUGIN"
[ -d "$PLUGIN_SRC" ] || { log_err "no existe el plugin: $PLUGIN_SRC"; exit 2; }

ESCENARIO_DIR="$PLUGIN_SRC/Test/$ESCENARIO"
if [ ! -d "$ESCENARIO_DIR" ]; then
    log_err "no existe el escenario '$ESCENARIO'. Los que hay:"
    ls -1 "$PLUGIN_SRC/Test" 2>/dev/null | sed 's|^|     |' >&2 || echo "     (ninguno)" >&2
    exit 2
fi

[ -x "$TESTENV_DIR/vendor/bin/phpunit" ] || {
    log_err "no hay phpunit en $TESTENV_DIR. Provisiona el entorno con bin/test-env-provision.sh"
    exit 2
}

# El enlace del plugin dentro del core es lo que hace que las rutas relativas funcionen.
[ -e "$TESTENV_DIR/Plugins/$PLUGIN" ] || {
    log_err "el plugin no está enlazado en $TESTENV_DIR/Plugins. Reprovisiona el entorno."
    exit 2
}

# Sin cobertura no hay mutación posible: Infection necesita saber qué test cubre qué línea.
php -m 2>/dev/null | grep -qiE '^(xdebug|pcov)$' || {
    log_err "hace falta xdebug o pcov para medir cobertura; sin eso Infection no puede trabajar."
    exit 2
}

# Ruta a mutar, RELATIVA al core: se aprovecha el enlace Plugins/<plugin>.
RUTA_MUTAR="Plugins/$PLUGIN"
[ -n "$SUBDIR" ] && RUTA_MUTAR="Plugins/$PLUGIN/$SUBDIR"
[ -d "$TESTENV_DIR/$RUTA_MUTAR" ] || { log_err "no existe el subdirectorio: $RUTA_MUTAR"; exit 2; }

# Huella del código ANTES: Infection no debe modificar fuentes, y aquí se comprueba en vez
# de confiarlo. Los plugins entran por symlink, así que un escritor descuidado tocaría el
# repo de verdad.
HUELLA_ANTES=""
if git -C "$PLUGIN_SRC" rev-parse --git-dir >/dev/null 2>&1; then
    HUELLA_ANTES="$(git -C "$PLUGIN_SRC" status --porcelain)"
fi

log_step "Mutación de $PLUGIN (escenario '$ESCENARIO', ruta $RUTA_MUTAR)"

# --- lock: Test/Plugins es recurso compartido con el runner web --------------------
LOCK="$FS_PROJECT_ROOT/test-env/.webrunner.lock"
exec 9>"$LOCK"
if ! flock -w 600 9; then
    log_err "no se pudo tomar el lock de ejecución ($LOCK); hay otra corrida en marcha."
    exit 1
fi

DEST="$TESTENV_DIR/Test/Plugins"
CFG="$TESTENV_DIR/.infection.tmp.json"
SALIDA="$(mktemp)"
# Infection sólo sabe usar `phpunit.xml`, y el del core apunta a Test/Core. Se sustituye
# temporalmente por uno acotado a los plugins, con respaldo, y se restaura SIEMPRE.
PHPUNIT_XML="$TESTENV_DIR/phpunit.xml"
PHPUNIT_BAK="$TESTENV_DIR/phpunit.xml.mutacion-bak"

limpiar() {
    rm -rf "${DEST:?}"/* 2>/dev/null || true
    rm -f "$CFG" "$SALIDA" 2>/dev/null || true
    rm -rf "$TESTENV_DIR/.infection-tmp" 2>/dev/null || true
    if [ -f "$PHPUNIT_BAK" ]; then
        mv -f "$PHPUNIT_BAK" "$PHPUNIT_XML"
    fi
    flock -u 9 2>/dev/null || true
}
trap limpiar EXIT

# --- 1) preparar el escenario, igual que hace el runner web -------------------------
mkdir -p "$DEST"
rm -rf "${DEST:?}"/*
cp -r "$ESCENARIO_DIR"/. "$DEST"/

# --- 2) sincronizar la activación de plugins ---------------------------------------
# Sin esto el plugin no está activo, su código no se ejecuta, y la cobertura sale a cero:
# Infection concluiría que no hay nada que mutar. Es el error más fácil de cometer aquí.
log_step "Sincronizando la activación del escenario..."
for _ in $(seq 1 25); do
    salida="$(cd "$TESTENV_DIR" && php Test/install-plugins.php 2>&1 || true)"
    log_info "$(echo "$salida" | tail -1)"
    echo "$salida" | grep -q 'enabled' || break
done

# --- 3a) phpunit.xml acotado a los plugins -----------------------------------------
# Infection busca `phpunit.xml` en el directorio de configuración y no acepta otro nombre,
# así que no basta con tener `phpunit-plugins.xml`: hay que ponerlo en su sitio. Si no, corre
# la suite del core (Test/Core), que en este entorno no pasa, e Infection se niega a seguir
# con «Project tests must be in a passing state» — medido.
#
# `executionOrder="default"` es necesario: Infection exige orden aleatorio o un orden
# declarado explícitamente, y estos tests comparten base de datos.
[ -f "$PHPUNIT_XML" ] && mv -f "$PHPUNIT_XML" "$PHPUNIT_BAK"
sed 's|<phpunit|<phpunit executionOrder="default"|' "$TESTENV_DIR/phpunit-plugins.xml" > "$PHPUNIT_XML"

# --- 3b) configuración temporal de Infection ----------------------------------------
cat > "$CFG" <<JSON
{
    "source": {
        "directories": ["$RUTA_MUTAR"],
        "excludes": ["Test", "vendor", "Assets", "Data", "Translation", "XMLView", "View"]
    },
    "testFramework": "phpunit",
    "phpUnit": { "configDir": "." },
    "logs": { "text": "php://stdout" },
    "tmpDir": ".infection-tmp"
}
JSON

# --- 4) mutar ----------------------------------------------------------------------
# Mutar sólo lo cubierto es el comportamiento POR DEFECTO de Infection; lo contrario se
# pediría con --with-uncovered. Y el umbral se delega en su propia opción, que ya decide el
# código de salida, en vez de reimplementar la comparación.
#
# ⚠ UN SOLO HILO, y no es una elección de rendimiento. Estos tests comparten UNA base de
# datos: con varios hilos, dos mutantes siembran a la vez y choca la clave única —medido:
# «Duplicate entry '1-2026' for key 'uniq_codcuenta'»—, así que los mutantes mueren por la
# colisión y no por el fallo introducido. Eso inflaría el MSI y lo haría mentir en la
# dirección cómoda. Paralelizar exigiría una base por hilo.
MIN_MSI_ARG=""
[ "$MSI_MINIMO" != "0" ] && MIN_MSI_ARG="--min-msi=$MSI_MINIMO"

log_step "Ejecutando Infection (la primera pasada mide cobertura; tarda)..."
set +e
( cd "$TESTENV_DIR" && php -d xdebug.mode=coverage "$INFECTION" \
    --configuration="$(basename "$CFG")" \
    --test-framework=phpunit \
    --initial-tests-php-options="-d xdebug.mode=coverage" \
    ${MIN_MSI_ARG} \
    --no-interaction \
    --no-progress \
    --threads=1 ) 2>&1 | tee "$SALIDA"
CODIGO=${PIPESTATUS[0]}
set -e

# --- 5) POSTCONDICIONES ------------------------------------------------------------
if [ -n "$HUELLA_ANTES" ] || git -C "$PLUGIN_SRC" rev-parse --git-dir >/dev/null 2>&1; then
    HUELLA_DESPUES="$(git -C "$PLUGIN_SRC" status --porcelain)"
    if [ "$HUELLA_ANTES" != "$HUELLA_DESPUES" ]; then
        log_err "el código fuente de $PLUGIN CAMBIÓ durante la mutación. Revísalo antes de commitear:"
        git -C "$PLUGIN_SRC" status --porcelain | sed 's|^|     |' >&2
        exit 1
    fi
    log_ok "el código fuente quedó intacto"
fi

# Infection publica la métrica como «Covered Code MSI» y, según la versión y el ancho de la
# terminal, también como «Mutation Score Indicator (MSI)». Se aceptan las dos, y además se
# informan las CUENTAS, que dicen más que el porcentaje: lo que importa es cuántos fallos se
# pudieron introducir sin que ningún test se enterara.
MSI="$(grep -oE '(Covered Code MSI|Mutation Score Indicator \(MSI\)): *[0-9.]+' "$SALIDA" \
        | grep -oE '[0-9.]+' | tail -1 || true)"
MATADOS="$(grep -oE '[0-9]+ mutants? were killed by Test Framework' "$SALIDA" \
        | grep -oE '^[0-9]+' | tail -1 || true)"
ESCAPADOS="$(grep -oE '[0-9]+ covered mutants? were not detected' "$SALIDA" \
        | grep -oE '^[0-9]+' | tail -1 || true)"

if [ -z "$MSI" ]; then
    log_warn "no se pudo leer la métrica de la salida: revísala arriba. Código de Infection: $CODIGO"
    exit 1
fi

log_ok "MSI del código cubierto: ${MSI}%   —   matados: ${MATADOS:-?}   escapados: ${ESCAPADOS:-0}"
if [ "${ESCAPADOS:-0}" != "0" ]; then
    log_info "Cada escapado es un fallo que se puede introducir sin que ningún test lo diga."
    log_info "Míralos arriba, en «Escaped mutants»: unos son huecos de test y otros son"
    log_info "mutantes inocuos (cambios que de verdad no alteran el comportamiento)."
fi

# El umbral, si se fijó, lo aplicó Infection con --min-msi y ya viene en su código de salida.
if [ "$CODIGO" != "0" ]; then
    log_err "Infection salió con código $CODIGO (umbral exigido: ${MSI_MINIMO}%)"
    exit 1
fi

exit 0
