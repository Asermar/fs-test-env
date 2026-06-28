#!/bin/bash
# =============================================================================
# Monta un entorno de desarrollo de FacturaScripts para ejecutar los tests
# (PHPUnit) de los plugins, SIN tocar la instalación ni la base de datos de
# trabajo.
#
# Este script es el FRONT INTERACTIVO para uso en el host:
#   1. Comprueba dependencias y extensiones PHP (ofrece instalarlas con sudo).
#   2. Pregunta la rama del core, la BD de pruebas y los plugins a activar.
#   3. Delega la provisión real en bin/test-env-provision.sh (no interactivo),
#      que también usa el contenedor podman 'test.mesafs' al arrancar.
#
# Variables opcionales (override):
#   CORE_REPO   repositorio del core por SSH
#               (def: git@github.com:NeoRazorX/facturascripts.git)
# =============================================================================

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_CONFIG="$ROOT/src/config.php"
PLUGINS_SRC="$ROOT/src/Plugins"
TESTENV_DIR="$ROOT/test-env/facturascripts"
PROVISION="$ROOT/bin/test-env-provision.sh"
# Usamos SSH (igual que los submódulos del proyecto) para reutilizar la clave
# SSH y evitar que git pida credenciales HTTPS de GitHub.
CORE_REPO="${CORE_REPO:-git@github.com:NeoRazorX/facturascripts.git}"

# --- dependencias de sistema ---
for bin in git composer php; do
    command -v "$bin" >/dev/null 2>&1 || { echo "ERROR: falta '$bin' en el sistema." >&2; exit 1; }
done
[ -f "$SRC_CONFIG" ] || { echo "ERROR: no existe $SRC_CONFIG" >&2; exit 1; }
[ -x "$PROVISION" ] || { echo "ERROR: no existe o no es ejecutable $PROVISION" >&2; exit 1; }

# --- extensiones PHP requeridas por el core (composer + conexión a BD) ---
echo ">> Comprobando extensiones PHP..."
PHP_VER="$(php -r 'echo PHP_MAJOR_VERSION . "." . PHP_MINOR_VERSION;')"
# mapa extensión -> paquete apt (mysqli lo provee phpX.Y-mysql)
declare -A EXT_PKG=(
    [bcmath]="php${PHP_VER}-bcmath"
    [gd]="php${PHP_VER}-gd"
    [mysqli]="php${PHP_VER}-mysql"
    [pgsql]="php${PHP_VER}-pgsql"
)
missing_ext=()
missing_pkg=()
loaded="$(php -m)"
for ext in bcmath gd mysqli pgsql; do
    if ! grep -qix "$ext" <<<"$loaded"; then
        missing_ext+=("$ext")
        missing_pkg+=("${EXT_PKG[$ext]}")
    fi
done
if [ "${#missing_ext[@]}" -gt 0 ]; then
    echo "   Faltan extensiones PHP requeridas: ${missing_ext[*]}"
    echo "   Paquetes a instalar: ${missing_pkg[*]}"
    read -rp "   ¿Instalarlas ahora con apt (sudo)? [s/N]: " inst
    if [ "$inst" = "s" ] || [ "$inst" = "S" ]; then
        sudo apt-get update
        sudo apt-get install -y "${missing_pkg[@]}"
    else
        echo "ERROR: no se puede continuar sin esas extensiones." >&2
        exit 1
    fi
else
    echo "   OK (bcmath, gd, mysqli, pgsql)"
fi

# --- lee constantes del config.php actual ---
cfg() { php -r "require '$SRC_CONFIG'; echo defined('$1') ? constant('$1') : '';"; }
DB_HOST="$(cfg FS_DB_HOST)"
DB_PORT="$(cfg FS_DB_PORT)"
DB_USER="$(cfg FS_DB_USER)"
DB_WORK="$(cfg FS_DB_NAME)"

# --- 1) rama del core (interactivo) ---
read -rp "Rama del core de FacturaScripts a usar [master]: " CORE_BRANCH
CORE_BRANCH="${CORE_BRANCH:-master}"

# --- 2) BD de pruebas (interactivo) ---
read -rp "Nombre de la BD de pruebas [mesafs_test]: " TEST_DB
TEST_DB="${TEST_DB:-mesafs_test}"

# salvaguarda: nunca la BD de trabajo
if [ "$TEST_DB" = "$DB_WORK" ]; then
    echo "ERROR: la BD de pruebas no puede ser la de trabajo ('$DB_WORK')." >&2
    exit 1
fi

# --- 3) plugins a activar (interactivo) ---
LINKED=()
for dir in "$PLUGINS_SRC"/*/; do
    name="$(basename "$dir")"
    [ -f "$dir/facturascripts.ini" ] || continue
    LINKED+=("$name")
done
echo
echo "Plugins disponibles: ${LINKED[*]}"
read -rp "Plugins a activar (separados por coma) [todos]: " ENABLE_IN
if [ -z "$ENABLE_IN" ]; then
    ENABLE_LIST="$(IFS=,; echo "${LINKED[*]}")"
else
    ENABLE_LIST="$ENABLE_IN"
fi

echo
echo "Core    : $CORE_REPO ($CORE_BRANCH)"
echo "Destino : $TESTENV_DIR"
echo "BD test : $TEST_DB @ $DB_HOST:$DB_PORT (user $DB_USER)"
echo "Plugins : $ENABLE_LIST"
read -rp "¿Continuar? [s/N]: " ok
[ "$ok" = "s" ] || [ "$ok" = "S" ] || { echo "Cancelado."; exit 0; }

# --- 4) delegamos la provisión real (no interactiva) ---
CORE_REPO="$CORE_REPO" CORE_BRANCH="$CORE_BRANCH" TEST_DB="$TEST_DB" \
    ENABLE_LIST="$ENABLE_LIST" "$PROVISION"

echo
echo "================================================================"
echo "Entorno de pruebas listo en: $TESTENV_DIR"
echo
echo "Ejecuta los tests de forma navegable en la web:"
echo "  https://test.mesafs.asermar.com  (contenedor podman 'test.mesafs')"
echo
echo "O desde la línea de comandos, por ejemplo:"
echo "  cd $TESTENV_DIR"
echo "  vendor/bin/phpunit Plugins/Alias/Test"
echo
echo "O con fsmaker (desde la carpeta del plugin):"
echo "  cd $TESTENV_DIR/Plugins/Alias"
echo "  fsmaker run-tests $TESTENV_DIR"
echo
echo "  NOTA: pásale la RUTA ABSOLUTA del entorno de pruebas (no '../..')."
echo "  Los plugins están enlazados por symlink y fsmaker resuelve la ruta"
echo "  física; con '../..' acabaría apuntando a src/ y fallaría pidiendo"
echo "  un 'composer install' que en realidad ya está hecho aquí."
echo "================================================================"
