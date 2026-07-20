#!/bin/bash
# =============================================================================
# Provisión NO INTERACTIVA del entorno de pruebas de FacturaScripts.
#
# Pensado para ejecutarse tanto en el host como dentro del contenedor podman
# 'test.mesafs' (al arrancar). A diferencia de bin/setup-test-env.sh:
#   - No hace preguntas (todo por variables de entorno con defaults).
#   - No usa sudo ni instala extensiones PHP (ya están en la imagen / el host).
#   - Clona el core por HTTPS (repo público) para no depender de claves SSH.
#   - Genera, además del warm-up, la config phpunit-webrunner.xml que usa la web.
#
# Es idempotente: si el core ya está clonado hace git pull; reusa la BD; etc.
#
# Variables de entorno (todas opcionales):
#   CORE_REPO    repo del core   (def: https://github.com/NeoRazorX/facturascripts.git)
#   CORE_BRANCH  rama del core   (def: master)
#   TEST_DB      BD de pruebas   (def: mesafs_test)
#   ENABLE_LIST  plugins a activar, separados por coma (def: todos los enlazados)
# =============================================================================

set -euo pipefail

# Directorio de este script (test-bin/bin).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Raíz del proyecto FacturaScripts: por defecto el padre de test-bin/ (submódulo).
# Sobreescribible con FS_PROJECT_ROOT para despliegues no estándar.
FS_PROJECT_ROOT="${FS_PROJECT_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"

# Config del despliegue (generada por bin/init-project.sh). Sin valores hardcodeados:
# lo que no venga por entorno ni por este fichero cae en los defaults genéricos.
[ -f "$FS_PROJECT_ROOT/.fs-test-env.env" ] && . "$FS_PROJECT_ROOT/.fs-test-env.env"

# Layout del core dentro del proyecto (Mesa_FS usa 'src'; FS estándar usaría '.').
FS_CORE_DIR="${FS_CORE_DIR:-src}"
CORE_ROOT="$FS_PROJECT_ROOT/$FS_CORE_DIR"
SRC_CONFIG="$CORE_ROOT/config.php"
PLUGINS_SRC="$CORE_ROOT/Plugins"
TESTENV_DIR="${TESTENV_DIR:-$FS_PROJECT_ROOT/test-env/facturascripts}"

CORE_REPO="${CORE_REPO:-https://github.com/NeoRazorX/facturascripts.git}"
# rama o tag del core; vacío/no definido => el tag de la versión instalada (v<Kernel::version()>),
# con fallback a master. Ver bin/branch-helpers.sh.
. "$SCRIPT_DIR/branch-helpers.sh"
CORE_BRANCH="${CORE_BRANCH:-$(fs_default_ref)}"
TEST_DB="${TEST_DB:-fs_test}"
FS_LANG="${FS_LANG:-es_ES}"
FS_TIMEZONE="${FS_TIMEZONE:-UTC}"

# --- salida de progreso (coloreada + con hora) -------------------------------
# Emitimos siempre color por defecto: la ventana de salida de OkoGit no es un TTY
# (así que no podemos gatear el color con [ -t 1 ]) pero sí renderiza ANSI. Se
# desactiva con NO_COLOR (convención estándar).
if [ -n "${NO_COLOR:-}" ]; then
    C_RESET='' C_STEP='' C_OK='' C_WARN='' C_ERR='' C_DIM=''
else
    C_RESET=$'\033[0m'; C_STEP=$'\033[1;36m'; C_OK=$'\033[1;32m'
    C_WARN=$'\033[1;33m'; C_ERR=$'\033[1;31m'; C_DIM=$'\033[2m'
fi
# printf de bash se vuelca al instante aunque la salida esté redirigida a un pipe
# (no hay buffering de bloque como en git/composer/php), así cada marcador aparece
# en OkoGit en cuanto se ejecuta la fase.
log_step() { printf '%s[%s] >> %s%s\n' "$C_STEP" "$(date +%H:%M:%S)" "$*" "$C_RESET"; }
log_ok()   { printf '%s[%s] OK %s%s\n' "$C_OK" "$(date +%H:%M:%S)" "$*" "$C_RESET"; }
log_warn() { printf '%s[%s] !! %s%s\n' "$C_WARN" "$(date +%H:%M:%S)" "$*" "$C_RESET"; }
log_info() { printf '   %s%s%s\n' "$C_DIM" "$*" "$C_RESET"; }
# stdbuf -oL/-eL fuerza a git/composer/php a volcar por líneas cuando la salida no
# es un TTY, de modo que su progreso se ve en vivo (si stdbuf no está, no pasa nada).
if command -v stdbuf >/dev/null 2>&1; then STDBUF=(stdbuf -oL -eL); else STDBUF=(); fi

# --- dependencias de sistema ---
# git es OPCIONAL: en el contenedor podman la imagen no lo trae, pero el core ya
# viene clonado en el host y montado, así que basta con saltarse el clone/pull.
for bin in composer php; do
    command -v "$bin" >/dev/null 2>&1 || { echo "ERROR: falta '$bin' en el sistema." >&2; exit 1; }
done
[ -f "$SRC_CONFIG" ] || { echo "ERROR: no existe $SRC_CONFIG" >&2; exit 1; }

# --- lee constantes del config.php de trabajo (host/usuario/clave de BD) ---
cfg() { php -r "require '$SRC_CONFIG'; echo defined('$1') ? constant('$1') : '';"; }
DB_HOST="$(cfg FS_DB_HOST)"
DB_PORT="$(cfg FS_DB_PORT)"
DB_USER="$(cfg FS_DB_USER)"
DB_PASS="$(cfg FS_DB_PASS)"
DB_WORK="$(cfg FS_DB_NAME)"

# salvaguarda: nunca la BD de trabajo
if [ "$TEST_DB" = "$DB_WORK" ]; then
    echo "ERROR: la BD de pruebas no puede ser la de trabajo ('$DB_WORK')." >&2
    exit 1
fi

printf '%s================================================================%s\n' "$C_STEP" "$C_RESET"
printf '%sProvisión del entorno de pruebas%s\n' "$C_STEP" "$C_RESET"
echo "Core    : $CORE_REPO ($CORE_BRANCH)"
echo "Destino : $TESTENV_DIR"
echo "BD test : $TEST_DB @ $DB_HOST:$DB_PORT (user $DB_USER)"
printf '%s================================================================%s\n' "$C_STEP" "$C_RESET"

# --- 1) clonar o actualizar el core (requiere git) ---
if command -v git >/dev/null 2>&1; then
    if [ -d "$TESTENV_DIR/.git" ]; then
        log_step "Actualizando core existente..."
        git -C "$TESTENV_DIR" checkout -- Test/bootstrap.php 2>/dev/null || true
        # revertimos también install-plugins.php (lo regeneramos más abajo) para que
        # el pull --ff-only no falle por cambios locales sobre un archivo del core.
        git -C "$TESTENV_DIR" checkout -- Test/install-plugins.php 2>/dev/null || true
        git -C "$TESTENV_DIR" fetch --quiet --tags origin
        git -C "$TESTENV_DIR" checkout --quiet "$CORE_BRANCH"
        # solo actualizamos si CORE_BRANCH es una rama; los tags son inmutables.
        if git -C "$TESTENV_DIR" show-ref --verify --quiet "refs/remotes/origin/$CORE_BRANCH"; then
            git -C "$TESTENV_DIR" pull --ff-only origin "$CORE_BRANCH"
        fi
    else
        log_step "Clonando core ($CORE_BRANCH)... (puede tardar varios minutos)"
        mkdir -p "$(dirname "$TESTENV_DIR")"
        # --progress: sin él, git no emite progreso cuando la salida no es un TTY
        # (como la ventana de OkoGit), y el clone parecería colgado.
        git clone --progress --branch "$CORE_BRANCH" "$CORE_REPO" "$TESTENV_DIR"
    fi
elif [ -f "$TESTENV_DIR/Core/Kernel.php" ]; then
    log_step "git no disponible; uso el core ya presente en $TESTENV_DIR (montado del host)."
else
    echo "ERROR: falta git y no hay un core en $TESTENV_DIR." >&2
    echo "       Provisiona primero en el host con bin/setup-test-env.sh." >&2
    exit 1
fi

# --- 2) composer install (phpunit + dev) ---
# Si el vendor ya está (montado del host), lo reutilizamos: así no necesitamos
# git/red dentro del contenedor.
if [ -f "$TESTENV_DIR/vendor/bin/phpunit" ]; then
    log_step "vendor ya presente; omito composer install."
else
    log_step "composer install... (puede tardar; descarga dependencias)"
    # stdbuf -oL + --no-progress: salida por líneas para que se vea avanzar en OkoGit.
    ( cd "$TESTENV_DIR" && "${STDBUF[@]}" composer install --no-interaction --no-progress )
fi

# --- 3) crear la BD de pruebas si no existe ---
log_step "Creando BD de pruebas (si falta)..."
php -r '
$m = new mysqli($argv[1], $argv[3], $argv[4], "", (int)$argv[2]);
if ($m->connect_errno) { fwrite(STDERR, "conexion: ".$m->connect_error."\n"); exit(1); }
$db = $m->real_escape_string($argv[5]);
$m->query("CREATE DATABASE IF NOT EXISTS `$db` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_520_ci");
echo "   BD lista: $argv[5]\n";
' "$DB_HOST" "$DB_PORT" "$DB_USER" "$DB_PASS" "$TEST_DB"

# --- 4) config.php del core apuntando a la BD de pruebas ---
log_step "Escribiendo config.php de pruebas..."
cat > "$TESTENV_DIR/config.php" <<PHP
<?php
define('FS_COOKIES_EXPIRE', 31536000);
define('FS_ROUTE', '');
define('FS_DB_FOREIGN_KEYS', true);
define('FS_DB_TYPE_CHECK', true);
define('FS_MYSQL_CHARSET', 'utf8mb4');
define('FS_MYSQL_COLLATE', 'utf8mb4_unicode_520_ci');
define('FS_LANG', '$FS_LANG');
define('FS_TIMEZONE', '$FS_TIMEZONE');
define('FS_DB_TYPE', 'mysql');
define('FS_DB_HOST', '$DB_HOST');
define('FS_DB_PORT', '$DB_PORT');
define('FS_DB_NAME', '$TEST_DB');
define('FS_DB_USER', '$DB_USER');
define('FS_DB_PASS', '$DB_PASS');
define('FS_DEBUG', true);
PHP

# --- 5) enlazar los plugins ---
log_step "Enlazando plugins..."
mkdir -p "$TESTENV_DIR/Plugins"
LINKED=()
for dir in "$PLUGINS_SRC"/*/; do
    name="$(basename "$dir")"
    [ -f "$dir/facturascripts.ini" ] || continue
    ln -sfn "$dir" "$TESTENV_DIR/Plugins/$name"
    LINKED+=("$name")
    echo "   + $name"
done

# --- 6) preparar lista de activación (genera las clases Dinamic al activar) ---
if [ -z "${ENABLE_LIST:-}" ]; then
    ENABLE_LIST="$(IFS=,; echo "${LINKED[*]}")"
fi
# Ordenamos respetando las dependencias declaradas en 'require' (e incluimos las
# deps transitivas): Plugins::enable() falla si las dependencias no están aún
# activadas, así que cada una debe ir antes que el plugin que la necesita.
ENABLE_LIST="$(php "$SCRIPT_DIR/plugin-topo-order.php" "$PLUGINS_SRC" "$ENABLE_LIST")"
log_step "Plugins a activar (orden por dependencias): $ENABLE_LIST"

mkdir -p "$TESTENV_DIR/Test/Plugins"
echo "$ENABLE_LIST" > "$TESTENV_DIR/Test/Plugins/install-plugins.txt"

# La activación la hace Test/install-plugins.php (sincroniza al conjunto exacto de
# Test/Plugins/install-plugins.txt). Ver la orquestación al final del script.

warmup_schema() {
    log_step "Construyendo esquema de la BD de pruebas (warm-up)..."
    ( cd "$TESTENV_DIR" && php warmup-schema.php 2>/dev/null )
}

# --- 7) parchear el bootstrap de tests (cargar extensiones de plugins) ---
BOOTSTRAP="$TESTENV_DIR/Test/bootstrap.php"
if [ -f "$BOOTSTRAP" ] && ! grep -q "Plugins::init()" "$BOOTSTRAP"; then
    log_step "Parcheando Test/bootstrap.php (Plugins::init)..."
    cat >> "$BOOTSTRAP" <<'PHP'

// inicializamos los plugins para que carguen sus extensiones (mods de modelos,
// controladores, etc.), igual que en runtime. Necesario para tests de extensiones.
Plugins::init();
PHP
fi

# --- 8) config de PHPUnit para la web (ejecuta TODOS los casos, sin parar) ---
log_step "Generando phpunit-webrunner.xml..."
cat > "$TESTENV_DIR/phpunit-webrunner.xml" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<!-- Generado por bin/test-env-provision.sh para el runner web.
     Igual que phpunit-plugins.xml pero SIN parar al primer fallo, para que la
     web muestre el resultado de todos los casos de una vez. -->
<phpunit
        beStrictAboutTestsThatDoNotTestAnything="false"
        bootstrap="Test/test-plugins.php"
        convertNoticesToExceptions="true"
        convertWarningsToExceptions="true"
        stopOnError="false"
        stopOnFailure="false"
        stopOnIncomplete="false"
        stopOnSkipped="false">
    <testsuites>
        <testsuite name="Plugins web runner suite">
            <directory
                    suffix="Test.php"
                    phpVersion="8.0"
                    phpVersionOperator=">=">
                Test/Plugins/
            </directory>
        </testsuite>
    </testsuites>
</phpunit>
XML

# --- 9) generar el script de warm-up del esquema (crea tablas con FK off) ---
cat > "$TESTENV_DIR/warmup-schema.php" <<'PHP'
<?php
// Warm-up del esquema de la BD de pruebas: crea todas las tablas de los modelos
// (core + plugins activos) desactivando las FK para evitar problemas de orden.
// Generado por bin/test-env-provision.sh; test-env está en .gitignore.

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

// FK desactivadas ANTES de Plugins::init(): el Init::update() de algunos plugins
// instancia modelos que crean sus tablas con las FK activas y, en una BD recién
// creada, fallaría por el orden (una tabla referencia otra que aún no existe).
$db = new DataBase();
$db->connect();
$db->exec('SET FOREIGN_KEY_CHECKS=0');

Cache::clear();
Kernel::init();
Plugins::init();
Plugins::deploy();

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

# --- 9b) generar Test/install-plugins.php (versión "sincronizar al conjunto exacto") ---
# Reemplaza al de core (que solo activa). Deja los plugins activos EXACTAMENTE igual a la
# lista de Test/Plugins/install-plugins.txt: desactiva lo que sobre y activa lo que falte.
# Así install-plugins.txt es autoritativo por juego de tests (soporta tests de ausencia).
log_step "Generando Test/install-plugins.php (sync)..."
cat > "$TESTENV_DIR/Test/install-plugins.php" <<'PHP'
<?php
// Sincroniza los plugins activos con la lista EXACTA de Test/Plugins/install-plugins.txt.
// Generado por bin/test-env-provision.sh (test-env está en .gitignore).

use FacturaScripts\Core\Base\DataBase;
use FacturaScripts\Core\Cache;
use FacturaScripts\Core\Kernel;
use FacturaScripts\Core\Plugins;

define('FS_FOLDER', getcwd());
require_once FS_FOLDER . '/vendor/autoload.php';

$config = FS_FOLDER . '/config.php';
if (!file_exists($config)) {
    die($config . " not found!\n");
}
require_once $config;

$db = new DataBase();
$db->connect();
Cache::clear();
Kernel::init();
Plugins::init();

// lista objetivo: conjunto exacto de plugins activos para este juego de tests
$target = [];
$listPath = __DIR__ . '/Plugins/install-plugins.txt';
if (file_exists($listPath)) {
    foreach (explode(',', (string)file_get_contents($listPath)) as $item) {
        $item = trim($item);
        if ($item !== '') {
            $target[] = $item;
        }
    }
}

// 1) desactivar todo lo activo que no esté en la lista
foreach (Plugins::enabled() as $name) {
    if (!in_array($name, $target, true)) {
        Plugins::disable($name);
    }
}

// 2) activar, en el orden indicado (dependencias), lo que falte
foreach ($target as $plugin) {
    if (null === Plugins::get($plugin)) {
        echo '-> Plugin ' . $plugin . ' no localizado.' . PHP_EOL;
        $db->close();
        exit(2);
    }
    if (!Plugins::isEnabled($plugin)) {
        Plugins::enable($plugin);
    }
}

// resumen: evitamos las subcadenas 'enabled'/'not found' para que el bucle del runner
// web pare tras esta única pasada (ya ha sincronizado todo).
echo 'Entorno sincronizado. Activos: ' . implode(',', Plugins::enabled()) . PHP_EOL;
$db->close();
PHP

# --- 10) orquestación: construir esquema con TODO activo y dejar TODO desactivado ---
# 1) Activamos todos los plugins (orden topológico) y creamos sus tablas. Dos rondas a
#    propósito: algunos plugins ejecutan en su post-enable código que necesita el esquema
#    ya creado (p.ej. BusImportacion guarda EmailNotification); no se activan en la 1ª
#    ronda (la tabla aún no existe), el warm-up las crea y la 2ª ronda los activa.
log_step "Construyendo esquema (activar todos + warm-up, 2 rondas)..."
echo "$ENABLE_LIST" > "$TESTENV_DIR/Test/Plugins/install-plugins.txt"
# Estas activaciones son el tramo más largo y antes iba en silencio absoluto
# (>/dev/null): marcamos cada ronda para que se vea el avance en OkoGit.
log_step "Esquema · ronda 1/2: activando plugins (esto tarda)..."
( cd "$TESTENV_DIR" && php Test/install-plugins.php >/dev/null 2>&1 ) || true
warmup_schema
log_step "Esquema · ronda 2/2: activando plugins..."
( cd "$TESTENV_DIR" && php Test/install-plugins.php >/dev/null 2>&1 ) || true
warmup_schema

# 2) Pizarra limpia: sincronizamos a lista VACÍA => se desactivan todos los plugins.
#    Las tablas creadas en el warm-up permanecen; cada juego de tests activará luego
#    exactamente los plugins de su install-plugins.txt.
log_step "Dejando todos los plugins desactivados (pizarra limpia)..."
: > "$TESTENV_DIR/Test/Plugins/install-plugins.txt"
( cd "$TESTENV_DIR" && php Test/install-plugins.php >/dev/null 2>&1 ) || true

echo
printf '%s================================================================%s\n' "$C_OK" "$C_RESET"
log_ok "Entorno de pruebas listo en: $TESTENV_DIR"
printf '%s================================================================%s\n' "$C_OK" "$C_RESET"
