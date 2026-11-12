<?php
/**
 * Construye el esquema de la BD de pruebas de PostgreSQL para UN escenario, desde «sólo el core».
 *
 *   php bin/pg-esquema.php <TESTENV_DIR de PostgreSQL> [--json]
 *
 * El escenario es el que diga `<dir>/Test/Plugins/install-plugins.txt` (vacío = sólo el core). Lo
 * llaman la provisión (con la lista vacía) y el runner (antes de cada phpunit con motor=postgresql).
 *
 * ## POR QUÉ NO VALE EL WARM-UP DE MYSQL
 *
 * PostgreSQL no deja crear una clave ajena hacia una tabla que todavía no existe, ni a un superusuario;
 * MySQL lo tolera con foreign_key_checks=0. Medido: ni siquiera el core sale en una pasada (59 tablas y
 * 113 FK, con fallos en familias, productos, agentes y clientes). Así que van DOS pasadas:
 *
 *   1. SIN claves ajenas (FS_TEST_SIN_FK=1, que los scripts generados convierten en la constante
 *      `db_foreign_keys` = false ANTES de cargar config.php: Tools::config() la busca antes que
 *      FS_DB_FOREIGN_KEYS). Se crean todas las tablas.
 *   2. CON ellas, tras borrar MyFiles/db-updater.json (la caché de tablas ya revisadas): DbUpdater
 *      añade las que faltan con ALTER TABLE … ADD CONSTRAINT. Medido con el core: 83 tablas, 223 FK.
 *
 * Y se comprueba que el truco sigue funcionando, porque depende de un detalle interno del core: tras la
 * pasada 1 tiene que haber 0 FK, y tras la 2 más de 0. Si no, lo dice con nombre, no con un rojo críptico.
 *
 * ## POR QUÉ DESDE «SÓLO EL CORE» CADA VEZ
 *
 * Como el CI de FacturaScripts: el plugin y sus dependencias sobre un core limpio, que es lo que mide la
 * forja. Antes de construir, la base se vacía (DROP OWNED BY CURRENT_USER, que no necesita superusuario)
 * y se borran MyFiles/ y Dinamic/ de este directorio, para que no queden tablas, plugins activos ni
 * clases generadas de un escenario anterior —tampoco de uno que se rompiera a medias—.
 *
 * ## UN ROJO DICE DE DÓNDE VIENE
 *
 * «Falla en PostgreSQL» es justo lo que la forja dice sin más. Cada error sale con la pasada, el plugin
 * (el del modelo o el que se estaba activando), la tabla y de quién es, y el motivo que dio el servidor.
 *
 * ## Y ANTES DE NADA, EL NEGATIVO DEL AISLAMIENTO
 *
 * Conectar a su propia base es el control positivo; el negativo es que el rol de la copia NO pueda
 * conectar a `fstest_centinela` (TESTENV_PG_CENTINELA), una base sin dueño de copia y con REVOKE CONNECT
 * FROM PUBLIC que crea okoworktree. «aislado» si el servidor dice permission denied; «no aislado» si
 * conecta; «no se pudo comprobar» si la centinela no existe. En los dos últimos no se construye nada:
 * quien va a usar PostgreSQL no lo usa sin saber que está aislado.
 *
 * Salida: 0 si el esquema quedó entero; 1 si no, o si la guarda de las FK falla; 2 si la invocación o el
 * entorno no valen.
 */

declare(strict_types=1);

$json = in_array('--json', $argv, true);
$args = array_values(array_filter(array_slice($argv, 1), fn ($a) => $a !== '--json'));
if (count($args) !== 1) {
    fwrite(STDERR, "uso: php " . basename(__FILE__) . " <TESTENV_DIR de PostgreSQL> [--json]\n");
    exit(2);
}

$t0 = microtime(true);
$dir = realpath($args[0]);
if ($dir === false || !is_file($dir . '/config.php') || !is_file($dir . '/warmup-schema.php')
    || !is_file($dir . '/Test/install-plugins.php')) {
    salir(2, 'no es un entorno de test provisionado (faltan config.php, warmup-schema.php o Test/install-plugins.php): ' . $args[0]);
}
require $dir . '/config.php';
if (!defined('FS_DB_TYPE') || strtolower((string) FS_DB_TYPE) !== 'postgresql') {
    salir(2, 'este entorno no es de PostgreSQL (su config.php no dice FS_DB_TYPE postgresql): ' . $dir);
}
if (!function_exists('pg_connect')) {
    salir(2, 'este PHP no tiene la extensión pgsql: recrea el contenedor de test con la imagen nueva.');
}

$q = fn ($v) => "'" . addcslashes((string) $v, "'\\") . "'";
$link = @pg_connect('host=' . $q(FS_DB_HOST) . ' port=' . $q(FS_DB_PORT) . ' user=' . $q(FS_DB_USER)
    . ' password=' . $q(FS_DB_PASS) . ' dbname=' . $q(FS_DB_NAME) . ' connect_timeout=10');
if (!$link) {
    $e = error_get_last();
    salir(2, 'no puedo conectar a ' . FS_DB_NAME . ' en ' . FS_DB_HOST . ':' . FS_DB_PORT . ': '
        . trim((string) ($e['message'] ?? '')) . '. ¿Está fstest-pg arriba (pg-up.sh) y creada la base (okoworktree up)?');
}

$aislamiento = aislamiento($q);
if ($aislamiento !== 'aislado') {
    salir(1, $aislamiento);
}

$plugins = leerEscenario($dir);

// --- 1) volver a «sólo el core»: base vacía y sin restos en el disco ---------------------------
if (!@pg_query($link, 'DROP OWNED BY CURRENT_USER')) {
    salir(1, 'no pude vaciar la base: ' . pg_last_error($link));
}
if (contar($link, 'tablas') !== 0) {
    salir(1, 'la base no quedó vacía tras DROP OWNED: no construyo sobre restos.');
}
foreach (['MyFiles', 'Dinamic'] as $sub) {
    borrar($dir . '/' . $sub);
}

// --- 2) pasada 1, sin claves ajenas -------------------------------------------------------------
$p1install = correr($dir, 'Test/install-plugins.php', true);
$p1warmup = correr($dir, 'warmup-schema.php', true);
$fkTras1 = contar($link, 'fk');

// --- 3) pasada 2, con ellas, sin la caché de tablas revisadas ----------------------------------
@unlink($dir . '/MyFiles/db-updater.json');
$p2warmup = correr($dir, 'warmup-schema.php', false);
$fkTras2 = contar($link, 'fk');
$tablas = contar($link, 'tablas');

// --- 4) qué falló, y de quién ------------------------------------------------------------------
$errores = array_merge(
    analizar($dir, $plugins, 'activación de plugins (pasada 1)', $p1install['salida']),
    analizar($dir, $plugins, 'esquema sin FK (pasada 1)', $p1warmup['salida']),
    analizar($dir, $plugins, 'esquema con FK (pasada 2)', $p2warmup['salida'])
);
// Un paso que no sale con 0 es un error aunque no haya escrito ninguna línea reconocible: si no, un
// fatal que corta el warm-up antes de su resumen daba «esquema completo».
foreach ([['activación de plugins (pasada 1)', 'Test/install-plugins.php', $p1install],
          ['esquema sin FK (pasada 1)', 'warmup-schema.php', $p1warmup],
          ['esquema con FK (pasada 2)', 'warmup-schema.php', $p2warmup]] as [$fase, $script, $paso]) {
    if ($paso['rc'] !== 0) {
        $errores[] = ['fase' => $fase, 'plugin' => '', 'origen' => $script, 'tabla' => '', 'tabla_de' => [],
            'motivo' => 'salió con ' . $paso['rc'] . ': ' . ultimaLinea($paso['salida'])];
    }
}
// Y el resumen del warm-up («OK=n FAIL=m») tiene que cuadrar con los fallos de modelo reconocidos: si
// dice que falló algo que no supe leer, eso es un error y no un verde.
foreach ([['esquema sin FK (pasada 1)', $p1warmup], ['esquema con FK (pasada 2)', $p2warmup]] as [$fase, $paso]) {
    if (!preg_match('/OK=\d+ FAIL=(\d+)/', $paso['salida'], $rm)) {
        if ($paso['rc'] === 0) {
            $errores[] = ['fase' => $fase, 'plugin' => '', 'origen' => 'warmup-schema.php', 'tabla' => '', 'tabla_de' => [],
                'motivo' => 'terminó sin su resumen OK=… FAIL=…: no sé si construyó el esquema.'];
        }
        continue;
    }
    $leidos = count(array_filter(analizar($dir, $plugins, $fase, $paso['salida']),
        fn ($e) => strpos($e['origen'], '\\Model\\') !== false));
    if ((int) $rm[1] !== $leidos) {
        $errores[] = ['fase' => $fase, 'plugin' => '', 'origen' => 'warmup-schema.php', 'tabla' => '', 'tabla_de' => [],
            'motivo' => "su resumen dice FAIL={$rm[1]} y reconocí $leidos fallo(s) de modelo: hay fallos que no sé atribuir."];
    }
}

// La guarda del truco: si el core dejara de mirar `db_foreign_keys` antes que FS_DB_FOREIGN_KEYS, la
// pasada 1 crearía FK y volveríamos al fallo de orden sin saber por qué.
$guarda = '';
if ($fkTras1 !== 0) {
    $guarda = "la pasada sin claves ajenas dejó $fkTras1 FK: el core ya no respeta la constante db_foreign_keys "
        . 'definida antes de config.php (Tools::config). Sin eso, PostgreSQL vuelve a fallar por el orden de las tablas.';
} elseif ($fkTras2 === 0) {
    $guarda = 'la pasada con claves ajenas no añadió ninguna FK: DbUpdater ya no las añade a tablas existentes '
        . '(o no releyó las tablas al borrar MyFiles/db-updater.json).';
}

$ok = $errores === [] && $guarda === '';
$res = [
    'ok' => $ok,
    'motor' => 'postgresql',
    'fase' => 'esquema',
    'aislamiento' => $aislamiento,
    'plugins' => $plugins,
    'tablas' => $tablas,
    'fk' => $fkTras2,
    'guarda' => ['fk_tras_pasada_1' => $fkTras1, 'fk_tras_pasada_2' => $fkTras2, 'error' => $guarda],
    'errores' => $errores,
    'segundos' => round(microtime(true) - $t0, 1),
];

if ($json) {
    echo json_encode($res, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES), "\n";
} else {
    echo 'Esquema PostgreSQL para ' . ($plugins ? implode(',', $plugins) : 'sólo el core') . ': '
        . "$tablas tablas, $fkTras2 FK, {$res['segundos']} s\n";
    if ($guarda !== '') {
        echo "ERROR (guarda de las claves ajenas): $guarda\n";
    }
    foreach ($errores as $e) {
        echo 'ERROR en ' . $e['fase'] . ($e['plugin'] !== '' ? ' · plugin ' . $e['plugin'] : '')
            . ($e['tabla'] !== '' ? ' · tabla ' . $e['tabla'] . ($e['tabla_de'] ? ' (de ' . implode(', ', $e['tabla_de']) . ')' : '') : '')
            . ($e['origen'] !== '' ? ' · ' . $e['origen'] : '') . "\n    " . $e['motivo'] . "\n";
    }
    echo $ok ? "OK: esquema completo.\n" : "NO: el esquema del escenario no se pudo construir (lo de arriba).\n";
}
exit($ok ? 0 : 1);

// ------------------------------------------------------------------------------------------------

function salir(int $rc, string $msg): void
{
    global $json, $aislamiento;
    if ($json) {
        echo json_encode(['ok' => false, 'motor' => 'postgresql', 'fase' => 'esquema',
            'aislamiento' => $aislamiento ?? 'no se pudo comprobar', 'error' => $msg],
            JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES), "\n";
    } else {
        fwrite(STDERR, "ERROR: $msg\n");
    }
    exit($rc);
}

/** El negativo: el rol de la copia no puede conectar a la base centinela. Devuelve «aislado» o el motivo. */
function aislamiento(callable $q): string
{
    $centinela = getenv('TESTENV_PG_CENTINELA') ?: 'fstest_centinela';
    $c = @pg_connect('host=' . $q(FS_DB_HOST) . ' port=' . $q(FS_DB_PORT) . ' user=' . $q(FS_DB_USER)
        . ' password=' . $q(FS_DB_PASS) . ' dbname=' . $q($centinela) . ' connect_timeout=10');
    if ($c) {
        pg_close($c);
        return 'no aislado: el rol ' . FS_DB_USER . " PUEDE conectar a la base centinela «{$centinela}». "
            . 'Su base no está aislada de las de otras copias; no se usa PostgreSQL así.';
    }
    $e = (string) (error_get_last()['message'] ?? '');
    if (stripos($e, 'permission denied for database') !== false) {
        return 'aislado';
    }
    if (stripos($e, 'does not exist') !== false) {
        return "no se pudo comprobar el aislamiento: no existe la base centinela «{$centinela}». La crea okoworktree up.";
    }
    return 'no se pudo comprobar el aislamiento: ' . trim(preg_replace('/^.*?FATAL:\s*/s', '', $e));
}

/** Lista del escenario: separada por comas o por líneas, como la escriben la provisión y los Test/<sub>. */
function leerEscenario(string $dir): array
{
    $f = $dir . '/Test/Plugins/install-plugins.txt';
    $txt = is_file($f) ? (string) file_get_contents($f) : '';
    return array_values(array_filter(array_map('trim', preg_split('/[,\n]/', $txt))));
}

function contar($link, string $que): int
{
    $sql = $que === 'fk'
        ? "SELECT count(*) FROM information_schema.table_constraints WHERE constraint_type = 'FOREIGN KEY' AND table_schema = current_schema()"
        : 'SELECT count(*) FROM information_schema.tables WHERE table_schema = current_schema()';
    $r = @pg_query($link, $sql);
    if (!$r) {
        salir(1, 'no pude contar ' . $que . ': ' . pg_last_error($link));
    }
    return (int) pg_fetch_row($r)[0];
}

/** Borra un subdirectorio del entorno sin seguir enlaces (Plugins/ y Core son enlaces y no se tocan). */
function borrar(string $ruta): void
{
    if (is_link($ruta) || is_file($ruta)) {
        unlink($ruta);
        return;
    }
    if (!is_dir($ruta)) {
        return;
    }
    foreach (scandir($ruta) as $n) {
        if ($n !== '.' && $n !== '..') {
            borrar($ruta . '/' . $n);
        }
    }
    rmdir($ruta);
}

function correr(string $dir, string $script, bool $sinFk): array
{
    $env = getenv();
    if ($sinFk) {
        $env['FS_TEST_SIN_FK'] = '1';
    } else {
        unset($env['FS_TEST_SIN_FK']);
    }
    $p = proc_open([PHP_BINARY, $script], [1 => ['pipe', 'w'], 2 => ['redirect', 1]], $pipes, $dir, $env);
    if (!is_resource($p)) {
        salir(2, "no pude lanzar $script");
    }
    $salida = stream_get_contents($pipes[1]);
    fclose($pipes[1]);
    return ['rc' => proc_close($p), 'salida' => (string) $salida];
}

function ultimaLinea(string $s): string
{
    $l = array_values(array_filter(array_map('trim', explode("\n", $s))));
    return $l ? substr(end($l), 0, 300) : '(sin salida)';
}

/**
 * Lee la salida de un paso y devuelve sus errores con su dueño. Reconoce:
 *   FAIL <Clase>: <mensaje>     un modelo que no pudo crear o actualizar su tabla (warm-up)
 *   FAIL Plugins::init [P]: …   el Init de un plugin falló al arrancar (P sale de la traza)
 *   BD <Plugin>: <motivo> | SQL…   un error de base al activar ese plugin (install-plugins)
 *   …Fatal error: …             un fallo que cortó el paso
 *   MOTIVO <texto>              el error del servidor, que se pega al FAIL anterior
 */
function analizar(string $dir, array $plugins, string $fase, string $salida): array
{
    $errores = [];
    foreach (explode("\n", $salida) as $linea) {
        // Hasta el PRIMER «: » (con espacio): «Plugins::init» lleva dos puntos dentro, y una clase de
        // modelo no lleva «: ». Un «[Plugin]» detrás del origen es el que sacó el warm-up de la traza.
        if (preg_match('/^FAIL (.+?)(?: \[([^\]]+)\])?: (.*)$/', $linea, $m)) {
            $m = [$m[0], $m[1], $m[3], $m[2]];
            $tabla = preg_match('/Error (?:creating|updating) table (\w+)/', $m[2], $t) ? $t[1] : '';
            $errores[] = ['fase' => $fase, 'plugin' => $m[3] !== '' ? $m[3] : duenoModelo($dir, $plugins, $m[1]), 'origen' => $m[1],
                'tabla' => $tabla, 'tabla_de' => $tabla !== '' ? duenosTabla($dir, $plugins, $tabla) : [],
                'motivo' => substr(preg_replace('/: (CREATE|ALTER) TABLE .*/s', '', $m[2]), 0, 300)];
        } elseif (preg_match('/^  MOTIVO (.*)$/', $linea, $m) && $errores) {
            $i = count($errores) - 1;
            $errores[$i]['motivo'] .= ' — servidor: ' . substr($m[1], 0, 300);
        } elseif (preg_match('/^BD ([^:]+): (.*)$/', $linea, $m)) {
            $errores[] = ['fase' => $fase, 'plugin' => $m[1], 'origen' => 'Init del plugin', 'tabla' => '',
                'tabla_de' => [], 'motivo' => substr($m[2], 0, 400)];
        } elseif (preg_match('/Fatal error: (.*)$/', $linea, $m)) {
            $tabla = preg_match('/Error (?:creating|updating) table (\w+)/', $m[1], $t) ? $t[1] : '';
            $errores[] = ['fase' => $fase, 'plugin' => '', 'origen' => 'fallo que cortó el paso', 'tabla' => $tabla,
                'tabla_de' => $tabla !== '' ? duenosTabla($dir, $plugins, $tabla) : [],
                'motivo' => substr(preg_replace('/: (CREATE|ALTER) TABLE .*/s', '', $m[1]), 0, 300)];
        }
    }
    return $errores;
}

/** De quién es un modelo de Dinamic: el primer plugin del escenario que lo define, o el core. */
function duenoModelo(string $dir, array $plugins, string $clase): string
{
    $m = substr($clase, (int) strrpos($clase, '\\') + 1);
    foreach (array_reverse($plugins) as $p) {
        if (is_file("$dir/Plugins/$p/Model/$m.php")) {
            return $p;
        }
    }
    return is_file("$dir/Core/Model/$m.php") ? 'core' : '';
}

/** De quién es una tabla: quién la define y qué plugins del escenario la extienden. */
function duenosTabla(string $dir, array $plugins, string $tabla): array
{
    $d = is_file("$dir/Core/Table/$tabla.xml") ? ['core'] : [];
    foreach ($plugins as $p) {
        if (is_file("$dir/Plugins/$p/Table/$tabla.xml")) {
            $d[] = $p;
        } elseif (is_file("$dir/Plugins/$p/Extension/Table/$tabla.xml")) {
            $d[] = "$p (extensión)";
        }
    }
    return $d;
}
