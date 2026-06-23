#!/bin/bash
# =============================================================================
# Monta un entorno de desarrollo de FacturaScripts para ejecutar los tests
# (PHPUnit) de los plugins, SIN tocar la instalación ni la base de datos de
# trabajo.
#
# Qué hace:
#   1. Pregunta la rama del core de FacturaScripts a usar.
#   2. Clona (o actualiza) el core de desarrollo en test-env/facturascripts.
#   3. composer install (trae phpunit + el scaffolding de Test del core).
#   4. Crea una base de datos de PRUEBAS aparte (reutiliza host/usuario del
#      config.php actual, pero con otro schema).
#   5. Escribe el config.php del core apuntando a esa BD de pruebas.
#   6. Enlaza (symlink) todos los plugins de src/Plugins en el core.
#
# Variables opcionales (override):
#   CORE_REPO   repositorio del core (def: FacturaScripts/facturascripts)
# =============================================================================

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_CONFIG="$ROOT/src/config.php"
PLUGINS_SRC="$ROOT/src/Plugins"
TESTENV_DIR="$ROOT/test-env/facturascripts"
CORE_REPO="${CORE_REPO:-https://github.com/FacturaScripts/facturascripts.git}"

# --- dependencias ---
for bin in git composer php; do
    command -v "$bin" >/dev/null 2>&1 || { echo "ERROR: falta '$bin' en el sistema." >&2; exit 1; }
done
[ -f "$SRC_CONFIG" ] || { echo "ERROR: no existe $SRC_CONFIG" >&2; exit 1; }

# --- lee constantes del config.php actual ---
cfg() { php -r "require '$SRC_CONFIG'; echo defined('$1') ? constant('$1') : '';"; }
DB_HOST="$(cfg FS_DB_HOST)"
DB_PORT="$(cfg FS_DB_PORT)"
DB_USER="$(cfg FS_DB_USER)"
DB_PASS="$(cfg FS_DB_PASS)"
DB_WORK="$(cfg FS_DB_NAME)"

# --- 1) rama del core (interactivo) ---
read -rp "Rama del core de FacturaScripts a usar [main]: " CORE_BRANCH
CORE_BRANCH="${CORE_BRANCH:-main}"

# --- 2) BD de pruebas (interactivo) ---
read -rp "Nombre de la BD de pruebas [mesafs_test]: " TEST_DB
TEST_DB="${TEST_DB:-mesafs_test}"

# salvaguarda: nunca la BD de trabajo
if [ "$TEST_DB" = "$DB_WORK" ]; then
    echo "ERROR: la BD de pruebas no puede ser la de trabajo ('$DB_WORK')." >&2
    exit 1
fi

echo
echo "Core    : $CORE_REPO ($CORE_BRANCH)"
echo "Destino : $TESTENV_DIR"
echo "BD test : $TEST_DB @ $DB_HOST:$DB_PORT (user $DB_USER)"
read -rp "¿Continuar? [s/N]: " ok
[ "$ok" = "s" ] || [ "$ok" = "S" ] || { echo "Cancelado."; exit 0; }

# --- 3) clonar o actualizar el core ---
if [ -d "$TESTENV_DIR/.git" ]; then
    echo ">> Actualizando core existente..."
    git -C "$TESTENV_DIR" fetch --quiet origin
    git -C "$TESTENV_DIR" checkout "$CORE_BRANCH"
    git -C "$TESTENV_DIR" pull --ff-only origin "$CORE_BRANCH"
else
    echo ">> Clonando core..."
    mkdir -p "$(dirname "$TESTENV_DIR")"
    git clone --branch "$CORE_BRANCH" "$CORE_REPO" "$TESTENV_DIR"
fi

# --- 4) composer install (phpunit + dev) ---
echo ">> composer install..."
( cd "$TESTENV_DIR" && composer install --no-interaction )

# --- 5) crear la BD de pruebas si no existe ---
echo ">> Creando BD de pruebas (si falta)..."
php -r '
$m = new mysqli($argv[1], $argv[3], $argv[4], "", (int)$argv[2]);
if ($m->connect_errno) { fwrite(STDERR, "conexion: ".$m->connect_error."\n"); exit(1); }
$db = $m->real_escape_string($argv[5]);
$m->query("CREATE DATABASE IF NOT EXISTS `$db` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_520_ci");
echo "   BD lista: $argv[5]\n";
' "$DB_HOST" "$DB_PORT" "$DB_USER" "$DB_PASS" "$TEST_DB"

# --- 6) config.php del core apuntando a la BD de pruebas ---
echo ">> Escribiendo config.php de pruebas..."
cat > "$TESTENV_DIR/config.php" <<PHP
<?php
define('FS_COOKIES_EXPIRE', 31536000);
define('FS_ROUTE', '');
define('FS_DB_FOREIGN_KEYS', true);
define('FS_DB_TYPE_CHECK', true);
define('FS_MYSQL_CHARSET', 'utf8mb4');
define('FS_MYSQL_COLLATE', 'utf8mb4_unicode_520_ci');
define('FS_LANG', 'es_ES');
define('FS_TIMEZONE', 'Atlantic/Canary');
define('FS_DB_TYPE', 'mysql');
define('FS_DB_HOST', '$DB_HOST');
define('FS_DB_PORT', '$DB_PORT');
define('FS_DB_NAME', '$TEST_DB');
define('FS_DB_USER', '$DB_USER');
define('FS_DB_PASS', '$DB_PASS');
define('FS_DEBUG', true);
PHP

# --- 7) enlazar los plugins ---
echo ">> Enlazando plugins..."
mkdir -p "$TESTENV_DIR/Plugins"
for dir in "$PLUGINS_SRC"/*/; do
    name="$(basename "$dir")"
    [ -f "$dir/facturascripts.ini" ] || continue
    ln -sfn "$dir" "$TESTENV_DIR/Plugins/$name"
    echo "   + $name"
done

echo
echo "================================================================"
echo "Entorno de pruebas listo en: $TESTENV_DIR"
echo
echo "Ejecuta los tests, por ejemplo:"
echo "  cd $TESTENV_DIR"
echo "  vendor/bin/phpunit Plugins/Alias/Test"
echo "  vendor/bin/phpunit Plugins/AliasClientes/Test"
echo "================================================================"
