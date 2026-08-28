#!/bin/bash
# =============================================================================
# Provisión NO INTERACTIVA del entorno de pruebas de FacturaScripts.
#
# Pensado para ejecutarse tanto en el host como dentro del contenedor podman
# 'mesa-fs-test' (al arrancar). A diferencia de bin/setup-test-env.sh:
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

# Directorio de este script (<arnés>/bin).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FS_TEST_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Raíz del proyecto FacturaScripts. Desde que el arnés vive FUERA del proyecto, subir dos niveles
# desde aquí ya no da un proyecto: da la carpeta donde está instalado el arnés. Así que quien invoca
# la dice —el compose la pasa en `FS_PROJECT_ROOT`— y, si no la dice, se prueba el directorio actual
# por si se lanzó a mano desde el proyecto.
FS_PROJECT_ROOT="${FS_PROJECT_ROOT:-$PWD}"

# =============================================================================================
# EL ENTORNO DE TEST VIVE EN UNA COPIA, NO EN EL CHECKOUT PRINCIPAL
#
# Decisión de Alexis (27-ago-2026): con desarrollo basado en worktrees el entorno vive en la copia,
# y **la existencia de la copia es su declaración de propiedad** — si la copia existe tiene dueño;
# si no existe, el entorno es basura. Los entornos de los principales se retiraron ese día.
#
# Esto es el instrumento de esa decisión: sin él, un `test-env-provision.sh` en el principal lo
# recrea entero y la decisión dura lo que tarde alguien en ejecutarlo por costumbre.
#
# ## LA SEÑAL, y NO es la que parece
#
#     git rev-parse --absolute-git-dir              vs.  --path-format=absolute --git-common-dir
#     iguales → checkout PRINCIPAL                        distintos → WORKTREE
#
# **«El `.git` es un fichero» NO sirve**, y el error habría sido invisible donde importa: en un
# SUBMÓDULO el `.git` también es un fichero. Medido sobre los cuatro casos reales de esta casa —
# `Mesa/FS` (directorio), `Mesa/FS/src/Plugins/OkoTranslate` (fichero), `Tooling/fs-test` (fichero)
# y un worktree (fichero)—: con el tipo de `.git`, los dos submódulos saldrían «worktree». Y los
# clientes son superproyectos llenos de submódulos, así que habría acertado en la raíz y mordido en
# cada plugin.
#
# ## POR QUÉ LA SEÑAL DE GIT Y NO EL ID `-wt-` DEL REGISTRO
#
# Porque el id es un NOMBRE, y un nombre falla en las dos direcciones. Medido:
#
#   - un worktree creado a mano SIN la convención (`FS-arreglourgente`) → git dice worktree, el id
#     dice «no es copia»: con el id se RECHAZARÍA trabajo legítimo;
#   - una carpeta llamada `FS-wt-falso` que es un repo normal → git dice principal, el id dice «es
#     copia»: con el id se DEJARÍA PASAR justo lo que hay que impedir.
#
# La regla habla del ÁRBOL DE TRABAJO, no de cómo se llame. Así que la señal es la de git.
#
# ## EL ESCAPE ES UN FLAG, NO UNA VARIABLE, y a propósito
#
# Un rechazo sin salida acaba bloqueando algo legítimo. Pero una variable de entorno se exporta una
# vez y se olvida —en un perfil, en un compose— y a partir de ahí el rechazo no rechaza nada, en
# silencio. Un flag tiene que escribirse en CADA invocación, así que queda a la vista en el
# historial, en el script que lo llame y en el botón que lo dispare.
# =============================================================================================
PERMITIR_PRINCIPAL=0
for _a in "$@"; do [ "$_a" = '--en-el-principal' ] && PERMITIR_PRINCIPAL=1; done

_git_dir="$(git -C "$FS_PROJECT_ROOT" rev-parse --absolute-git-dir 2>/dev/null || true)"
_git_comun="$(git -C "$FS_PROJECT_ROOT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
if [ -n "$_git_dir" ] && [ "$_git_dir" = "$_git_comun" ] && [ "$PERMITIR_PRINCIPAL" = 0 ]; then
    cat >&2 <<FIN
ERROR: «$FS_PROJECT_ROOT» es el checkout PRINCIPAL, y el entorno de test no vive aquí.

  Con desarrollo por worktrees el entorno vive en la COPIA, y la existencia de la copia es su
  declaración de propiedad: si la copia existe tiene dueño, y si no existe el entorno es basura.
  Provisionar en el principal devuelve un entorno que nadie reclama y que nadie retira.

  Crea la copia y provisiona ahí:

      okoworktree add <nombre> --db-mode fresh

  Eso levanta su stack y provisiona su entorno de test, con SU base de datos.

  Si de verdad hace falta aquí —y conviene decir por qué antes de hacerlo— el escape es explícito y
  hay que escribirlo en cada invocación:

      $0 --en-el-principal

  Es un flag y no una variable de entorno a propósito: una variable se exporta una vez y se olvida,
  y a partir de ahí este rechazo dejaría de rechazar sin que nadie lo notara.
FIN
    exit 1
fi
[ "$PERMITIR_PRINCIPAL" = 1 ] && [ "$_git_dir" = "$_git_comun" ] && \
    echo "AVISO: provisionando en el checkout PRINCIPAL con --en-el-principal. El entorno queda sin dueño." >&2


# Precondición, y falla antes de escribir nada: sin esto, el provisionador seguiría adelante contra
# una carpeta que no es un proyecto y el fallo aparecería más tarde y hablando de otra cosa.
if [ ! -f "$FS_PROJECT_ROOT/.fs-test-env.env" ]; then
    echo "ERROR: '$FS_PROJECT_ROOT' no parece un proyecto configurado: no tiene .fs-test-env.env." >&2
    echo "  Arreglo: lánzalo desde la raíz del proyecto, o dilo:" >&2
    echo "           FS_PROJECT_ROOT=/ruta/del/proyecto $0" >&2
    echo "  Si el proyecto aún no está configurado: $FS_TEST_DIR/bin/init-project.sh" >&2
    exit 1
fi

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
# LA CONTRASEÑA NO VA EN argv. Un argumento de proceso se lee en `/proc/<pid>/cmdline`, que es
# LEGIBLE POR CUALQUIER USUARIO de la máquina: no hace falta que nadie pegue un log, basta un `ps`
# en el momento justo. El entorno no: `/proc/<pid>/environ` es 0400 del propio usuario. Lo estricto
# sería pasarla por stdin, y si algún día esto crece a algo con más de un usuario real, ése es el
# siguiente paso. Los otros argumentos (host, puerto, usuario, base) no son secretos y se quedan.
FS_TEST_DB_PASS="$DB_PASS" php -r '
$m = new mysqli($argv[1], $argv[3], (string) getenv("FS_TEST_DB_PASS"), "", (int)$argv[2]);
if ($m->connect_errno) { fwrite(STDERR, "conexion: ".$m->connect_error."\n"); exit(1); }
$db = $m->real_escape_string($argv[5]);
$m->query("CREATE DATABASE IF NOT EXISTS `$db` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_520_ci");
echo "   BD lista: $argv[5]\n";
' "$DB_HOST" "$DB_PORT" "$DB_USER" "" "$TEST_DB"

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

# EL WARM-UP HABLA, Y SE COMPRUEBA SI FALLÓ. Antes iba con `2>/dev/null` y sin mirar el resultado:
# cuando PHP moría con un fatal no se imprimía NADA y, con `set -e`, el script abortaba en silencio.
# «Ni funciona ni lo dice» es la peor combinación, y costó horas de diagnóstico — el fallo real era un
# `Table/*.xml` que declaraba `serial` sin PRIMARY KEY y no se podía crear de cero, invisible detrás
# del silenciador.
#
# OJO A LA DIFERENCIA con los `2>/dev/null` de más arriba (los `git checkout --` de los ficheros
# parcheados): aquéllos son DELIBERADOS y correctos, porque restauran ficheros que pueden no existir y
# llevan su `|| true`. El patrón malo es otro: silenciar algo que SÍ puede fallar de verdad y además
# no mirar si falló. No los unifiques.
# warmup_schema [--exigir]: HABLA SIEMPRE, pero sólo es FATAL con `--exigir`.
#
# Los dos matices importan y salen de un error propio. Que hable siempre: antes iba con
# `2>/dev/null` y sin mirar el resultado, así que un fatal de PHP no imprimía NADA y con `set -e` la
# provisión abortaba en silencio — «ni funciona ni lo dice», horas de diagnóstico por un
# `Table/*.xml` con `serial` sin PRIMARY KEY que sólo asoma en una BD nueva.
#
# Y que sólo sea fatal al final: la ronda 1 PUEDE fallar por diseño —hay plugins que en su
# post-enable necesitan un esquema que aún no existe, y de eso van justamente las dos rondas—, así
# que hacerla fatal aborta una provisión que iba bien. Medido: al hacerla fatal, una provisión desde
# una BD vacía moría en la ronda 1 y ejecutar el warm-up a mano justo después daba OK=290 FAIL=0.
# La que no puede fallar es la ÚLTIMA, y ésa es la que lleva `--exigir`.
warmup_schema() {
    local exigir=0
    [ "${1:-}" = "--exigir" ] && exigir=1
    log_step "Construyendo esquema de la BD de pruebas (warm-up)..."
    if ( cd "$TESTENV_DIR" && php warmup-schema.php ); then
        return 0
    fi
    if [ "$exigir" -eq 1 ]; then
        echo "ERROR: el warm-up del esquema falló en la ronda final (su salida está arriba)." >&2
        echo "  suele ser un Table/*.xml que no se puede crear de cero — p. ej. 'serial' sin" >&2
        echo "  PRIMARY KEY, que da ERROR 1075 y sólo asoma en una BD nueva." >&2
        return 1
    fi
    echo "AVISO: el warm-up falló en una ronda intermedia. Puede ser normal —hay plugins que" >&2
    echo "  necesitan un esquema que aún no existe— pero su salida queda arriba por si no lo es." >&2
    return 0
}

# --- 7) parchear el bootstrap de tests (extensiones de plugins, y quitar la fuga de la clave) ---
BOOTSTRAP="$TESTENV_DIR/Test/bootstrap.php"

# LA CONTRASEÑA DE LA BD SE QUITA DEL BOOTSTRAP, Y NO ES UN BUG NUESTRO. La línea
# `echo "\n" . 'DB Pass: ' . FS_DB_PASS;` viene del CORE OFICIAL de FacturaScripts
# (`Test/bootstrap.php`, ~línea 43): imprime la contraseña en la cabecera de CADA ejecución de
# PHPUnit, así que acaba en cualquier log, captura o pegado de una salida de tests. Aquí se retira
# porque este fichero ya se parchea de todas formas, y sale gratis.
#
# Queda comentado a propósito, con dos motivos: que nadie lo lea como un defecto de este arnés, y
# que nadie lo «restaure» al actualizar el core. Y va FUERA del `if` de abajo: ese `if` sólo actúa
# cuando falta `Plugins::init()`, mientras que el `echo` vuelve en CADA actualización del core (el
# paso 2 hace `git checkout --` de este fichero antes de parchearlo), así que hay que quitarlo
# siempre. Es idempotente: si ya no está, no hace nada.
if [ -f "$BOOTSTRAP" ] && grep -q "DB Pass" "$BOOTSTRAP"; then
    log_step "Quitando del bootstrap el volcado de la contraseña (viene del core)..."
    tmp_bs="$(mktemp)"
    grep -v "DB Pass" "$BOOTSTRAP" > "$tmp_bs" && mv "$tmp_bs" "$BOOTSTRAP"
    if grep -q "DB Pass" "$BOOTSTRAP"; then
        echo "ERROR: no se pudo quitar la contraseña del bootstrap; los tests la imprimirán." >&2
        exit 1
    fi
fi

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
// Sincroniza los plugins activos con el conjunto Y EL ORDEN exactos de
// Test/Plugins/install-plugins.txt. El orden importa tanto como el conjunto: en Dinamic
// gana el plugin con `order` más alto (PluginsDeploy::run() hace array_reverse y se queda
// con el primer fichero que encuentra), y Plugins::enable() solo asigna
// `order = maxOrder() + 1` cuando activa de verdad -- si el plugin ya estaba activo de una
// suite anterior, enable() es un no-op y conserva su `order` viejo, invirtiendo la
// precedencia que declara esta lista. Por eso, cuando el conjunto activo o su orden relativo
// no coincide con la lista, desactivamos TODO y reactivamos en el orden pedido (así se
// reasignan los `order`); si ya coincide, no tocamos nada (reactivar dispara
// Plugins::deploy(), que reconstruye Dinamic/, rutas y esquema, y es caro).
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

// lista objetivo: conjunto y orden exactos de plugins activos para este juego de tests
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

// Orden de activación: preservamos el orden de $target, pero si un plugin requiere a otro
// que en la lista aparece DESPUÉS, la dependencia manda (Plugins::enable() no activa un
// plugin sin sus dependencias ya activas: ver Plugin::dependenciesOk()). Es un orden
// topológico ESTABLE: para cada plugin de $target, en su orden, colocamos antes
// (recursivamente) las dependencias que también estén en la lista y aún no se hayan
// colocado. install-plugins.txt ya debería declarar las dependencias antes que quien las
// necesita (igual que exige bin/plugin-topo-order.php al generar la lista completa del
// aprovisionamiento); esto es solo la red de seguridad para ese caso, y si $target ya es
// topológicamente válida, $activationOrder sale idéntica a $target.
$activationOrder = [];
$placed = [];
$placeWithDeps = function (string $name) use (&$placeWithDeps, &$activationOrder, &$placed, $target): void {
    if (isset($placed[$name])) {
        return;
    }
    $placed[$name] = true;
    $plugin = Plugins::get($name);
    if ($plugin) {
        foreach ($plugin->require as $dep) {
            if (in_array($dep, $target, true)) {
                $placeWithDeps($dep);
            }
        }
    }
    $activationOrder[] = $name;
};
foreach ($target as $name) {
    $placeWithDeps($name);
}

// si el conjunto activo actual y su orden relativo YA coinciden, no tocamos nada.
$current = Plugins::enabled();
if ($current === $activationOrder) {
    echo 'Entorno ya sincronizado. Activos: ' . implode(',', $current) . PHP_EOL;
    $db->close();
    exit(0);
}

// 1) desactivamos TODO lo que esté activo. No basta con desactivar lo que sobra: el
//    `order` de un plugin solo cambia al pasar por un enable() nuevo, así que para corregir
//    el orden relativo hay que desactivar también los que se van a mantener y reactivarlos
//    después en su sitio.
foreach ($current as $name) {
    Plugins::disable($name);
}

// 2) activamos en el orden ya resuelto (lista + dependencias).
foreach ($activationOrder as $plugin) {
    if (null === Plugins::get($plugin)) {
        echo '-> Plugin ' . $plugin . ' no localizado.' . PHP_EOL;
        $db->close();
        exit(2);
    }
    if (!Plugins::enable($plugin)) {
        echo '-> No se pudo activar ' . $plugin . ': revisa sus dependencias en install-plugins.txt.' . PHP_EOL;
        $db->close();
        exit(3);
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
#
# El `|| true` SE QUEDA y es de su diseño: en la 1ª ronda algunos plugins no pueden activarse porque
# su tabla aún no existe, y eso es esperado. Lo que se quita es el `2>&1`: la salida normal sigue
# callada —es larguísima— pero un error de verdad ya no se descarta. Silenciar el avance es una
# decisión; silenciar los errores es perder el diagnóstico.
log_step "Esquema · ronda 1/2: activando plugins (esto tarda)..."
( cd "$TESTENV_DIR" && php Test/install-plugins.php >/dev/null ) || true
warmup_schema
log_step "Esquema · ronda 2/2: activando plugins..."
( cd "$TESTENV_DIR" && php Test/install-plugins.php >/dev/null ) || true
warmup_schema --exigir

# 2) Pizarra limpia: sincronizamos a lista VACÍA => se desactivan todos los plugins.
#    Las tablas creadas en el warm-up permanecen; cada juego de tests activará luego
#    exactamente los plugins de su install-plugins.txt.
# La pizarra limpia también deja pasar el stderr, y por el mismo motivo: si esto falla, el entorno
# queda con plugins activos y el siguiente juego de tests arranca sobre un estado que no es el que
# declara su `install-plugins.txt`. El `|| true` se conserva para no abortar por esto una provisión
# que por lo demás salió bien, pero al menos se ve.
log_step "Dejando todos los plugins desactivados (pizarra limpia)..."
: > "$TESTENV_DIR/Test/Plugins/install-plugins.txt"
( cd "$TESTENV_DIR" && php Test/install-plugins.php >/dev/null ) || true

echo
printf '%s================================================================%s\n' "$C_OK" "$C_RESET"
log_ok "Entorno de pruebas listo en: $TESTENV_DIR"
printf '%s================================================================%s\n' "$C_OK" "$C_RESET"
