#!/bin/bash
# =============================================================================
# Monta un entorno de desarrollo de FacturaScripts para ejecutar los tests
# (PHPUnit) de los plugins, SIN tocar la instalación ni la base de datos de
# trabajo.
#
# Qué hace:
#   1. Comprueba dependencias y extensiones PHP (ofrece instalarlas si faltan).
#   2. Pregunta la rama del core de FacturaScripts a usar (por defecto master).
#   3. Clona (o actualiza) el core de desarrollo en test-env/facturascripts.
#   4. composer install (trae phpunit + el scaffolding de Test del core).
#   5. Crea una base de datos de PRUEBAS aparte (reutiliza host/usuario del
#      config.php actual, pero con otro schema).
#   6. Escribe el config.php del core apuntando a esa BD de pruebas.
#   7. Enlaza (symlink) los plugins de src/Plugins en el core.
#   8. Activa los plugins elegidos (genera las clases Dinamic).
#   9. Parchea el bootstrap de tests para que cargue las extensiones de plugins.
#  10. Construye el esquema completo de la BD de pruebas (warm-up).
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
# Usamos SSH (igual que los submódulos del proyecto) para reutilizar la clave
# SSH y evitar que git pida credenciales HTTPS de GitHub.
CORE_REPO="${CORE_REPO:-git@github.com:NeoRazorX/facturascripts.git}"

# --- dependencias de sistema ---
for bin in git composer php; do
    command -v "$bin" >/dev/null 2>&1 || { echo "ERROR: falta '$bin' en el sistema." >&2; exit 1; }
done
[ -f "$SRC_CONFIG" ] || { echo "ERROR: no existe $SRC_CONFIG" >&2; exit 1; }

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
DB_PASS="$(cfg FS_DB_PASS)"
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

echo
echo "Core    : $CORE_REPO ($CORE_BRANCH)"
echo "Destino : $TESTENV_DIR"
echo "BD test : $TEST_DB @ $DB_HOST:$DB_PORT (user $DB_USER)"
read -rp "¿Continuar? [s/N]: " ok
[ "$ok" = "s" ] || [ "$ok" = "S" ] || { echo "Cancelado."; exit 0; }

# --- 3) clonar o actualizar el core ---
if [ -d "$TESTENV_DIR/.git" ]; then
    echo ">> Actualizando core existente..."
    # descartamos el parche local del bootstrap para no bloquear el ff-only
    git -C "$TESTENV_DIR" checkout -- Test/bootstrap.php 2>/dev/null || true
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
LINKED=()
for dir in "$PLUGINS_SRC"/*/; do
    name="$(basename "$dir")"
    [ -f "$dir/facturascripts.ini" ] || continue
    ln -sfn "$dir" "$TESTENV_DIR/Plugins/$name"
    LINKED+=("$name")
    echo "   + $name"
done

# --- 8) activar plugins (genera las clases Dinamic) ---
echo
echo "Plugins enlazados: ${LINKED[*]}"
read -rp "Plugins a activar (separados por coma) [todos]: " ENABLE_IN
if [ -z "$ENABLE_IN" ]; then
    ENABLE_LIST="$(IFS=,; echo "${LINKED[*]}")"
else
    ENABLE_LIST="$ENABLE_IN"
fi

mkdir -p "$TESTENV_DIR/Test/Plugins"
echo "$ENABLE_LIST" > "$TESTENV_DIR/Test/Plugins/install-plugins.txt"

echo ">> Activando plugins (puede tardar)..."
# install-plugins.php activa UN plugin por ejecución y sale; lo llamamos en bucle.
set +e
count="$(awk -F, '{print NF}' <<<"$ENABLE_LIST")"
for _ in $(seq 1 "$((count + 1))"); do
    out="$(cd "$TESTENV_DIR" && php Test/install-plugins.php 2>/dev/null)"
    line="$(grep -E 'enabled|not found' <<<"$out" | head -n1)"
    [ -z "$line" ] && break
    echo "   $line"
    grep -q 'not found' <<<"$line" && break
done
set -e

# --- 9) parchear el bootstrap de tests (cargar extensiones de plugins) ---
BOOTSTRAP="$TESTENV_DIR/Test/bootstrap.php"
if [ -f "$BOOTSTRAP" ] && ! grep -q "Plugins::init()" "$BOOTSTRAP"; then
    echo ">> Parcheando Test/bootstrap.php (Plugins::init)..."
    cat >> "$BOOTSTRAP" <<'PHP'

// inicializamos los plugins para que carguen sus extensiones (mods de modelos,
// controladores, etc.), igual que en runtime. Necesario para tests de extensiones.
Plugins::init();
PHP
fi

# --- 10) warm-up del esquema (crea todas las tablas con FK desactivadas) ---
echo ">> Construyendo esquema de la BD de pruebas (warm-up)..."
cat > "$TESTENV_DIR/warmup-schema.php" <<'PHP'
<?php
// Warm-up del esquema de la BD de pruebas: crea todas las tablas de los modelos
// (core + plugins activos) desactivando las FK para evitar problemas de orden.
// Generado por bin/setup-test-env.sh; test-env está en .gitignore.

use FacturaScripts\Core\Base\DataBase;
use FacturaScripts\Core\Cache;
use FacturaScripts\Core\Kernel;
use FacturaScripts\Core\Plugins;

define('FS_FOLDER', getcwd());
require_once __DIR__ . '/vendor/autoload.php';

$config = FS_FOLDER . '/config.php';
if (!file_exists($config)) {
    die($config . " not found!\n");
}
require_once $config;

Cache::clear();
Kernel::init();
Plugins::init();
Plugins::deploy();

$db = new DataBase();
$db->connect();
$db->exec('SET FOREIGN_KEY_CHECKS=0');

$ok = 0;
$fail = 0;
foreach (glob(FS_FOLDER . '/Dinamic/Model/*.php') as $file) {
    $class = 'FacturaScripts\\Dinamic\\Model\\' . basename($file, '.php');
    if (!class_exists($class)) {
        continue;
    }
    $ref = new ReflectionClass($class);
    if ($ref->isAbstract()) {
        continue;
    }
    try {
        new $class();
        $ok++;
    } catch (\Throwable $e) {
        $fail++;
        echo 'FAIL ' . $class . ': ' . $e->getMessage() . "\n";
    }
}

$db->exec('SET FOREIGN_KEY_CHECKS=1');
echo "   Tablas verificadas/creadas. OK=$ok FAIL=$fail\n";
PHP
( cd "$TESTENV_DIR" && php warmup-schema.php 2>/dev/null )

echo
echo "================================================================"
echo "Entorno de pruebas listo en: $TESTENV_DIR"
echo
echo "Ejecuta los tests, por ejemplo:"
echo "  cd $TESTENV_DIR"
echo "  vendor/bin/phpunit Plugins/Alias/Test"
echo "  vendor/bin/phpunit Plugins/AliasClientes/Test"
echo
echo "O con fsmaker (método recomendado), desde la carpeta del plugin:"
echo "  cd $TESTENV_DIR/Plugins/Alias"
echo "  fsmaker run-tests $TESTENV_DIR"
echo
echo "  NOTA: pásale la RUTA ABSOLUTA del entorno de pruebas (no '../..')."
echo "  Los plugins están enlazados por symlink y fsmaker resuelve la ruta"
echo "  física; con '../..' acabaría apuntando a src/ y fallaría pidiendo"
echo "  un 'composer install' que en realidad ya está hecho aquí."
echo "================================================================"
