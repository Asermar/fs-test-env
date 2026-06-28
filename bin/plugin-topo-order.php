<?php
/**
 * Ordena una lista de plugins respetando sus dependencias (clave `require` del
 * facturascripts.ini), de forma que cada dependencia aparezca ANTES que el
 * plugin que la necesita. Así Plugins::enable() (que falla si las dependencias
 * no están activadas todavía) puede activarlos uno a uno sin abortar.
 *
 * Incluye automáticamente las dependencias transitivas que existan en la carpeta
 * de plugins, aunque no estuvieran en la lista pedida (si pides BusCanarias,
 * necesitas OpenServBus, PlantillasPDF y PortalCliente).
 *
 * Uso:
 *   php bin/plugin-topo-order.php <ruta-src-Plugins> "<lista,separada,por,comas>"
 *   - Si la lista está vacía, ordena TODOS los plugins de la carpeta.
 *   - Salida: lista separada por comas, en orden de activación.
 */

$pluginsDir = $argv[1] ?? '';
$requestedRaw = $argv[2] ?? '';

if ($pluginsDir === '' || !is_dir($pluginsDir)) {
    fwrite(STDERR, "ruta de plugins no válida: $pluginsDir\n");
    exit(1);
}

// 1) leer todos los plugins disponibles y su 'require'.
// Parseamos a mano las claves name/require (los .ini mezclan valores con y sin
// comillas; parse_ini_file en modo RAW deja las comillas y rompe el casado de
// nombres con las dependencias).
$clean = static function (string $v): string {
    return trim($v, " \t\n\r\0\x0B'\"");
};
$requires = []; // nombre => [deps]
foreach (glob($pluginsDir . '/*/facturascripts.ini') as $ini) {
    $lines = file($ini, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES) ?: [];
    $name = '';
    $deps = [];
    foreach ($lines as $line) {
        if (preg_match('/^\s*name\s*=\s*(.+)$/i', $line, $m)) {
            $name = $clean($m[1]);
        } elseif (preg_match('/^\s*require\s*=\s*(.+)$/i', $line, $m)) {
            foreach (explode(',', $clean($m[1])) as $d) {
                $d = $clean($d);
                if ($d !== '') {
                    $deps[] = $d;
                }
            }
        }
    }
    if ($name !== '') {
        $requires[$name] = $deps;
    }
}

// 2) lista pedida (o todos)
$requested = [];
foreach (explode(',', $requestedRaw) as $p) {
    $p = trim($p);
    if ($p !== '') {
        $requested[] = $p;
    }
}
if (empty($requested)) {
    $requested = array_keys($requires);
}

// 3) conjunto a instalar = pedidos + dependencias transitivas que existan
$want = [];
$stack = $requested;
while ($stack) {
    $n = array_pop($stack);
    if (isset($want[$n]) || !isset($requires[$n])) {
        // desconocido (no está en la carpeta): lo ignoramos en el orden
        continue;
    }
    $want[$n] = true;
    foreach ($requires[$n] as $d) {
        if (!isset($want[$d])) {
            $stack[] = $d;
        }
    }
}

// 4) orden topológico (DFS post-orden: deps antes que dependientes)
$order = [];
$state = []; // 0=en proceso, 1=hecho

$visit = function (string $n) use (&$visit, &$requires, &$want, &$state, &$order): void {
    if (isset($state[$n])) {
        return; // ya hecho o en proceso (ciclo: cortamos para no bucle infinito)
    }
    if (!isset($want[$n])) {
        return;
    }
    $state[$n] = 0;
    foreach ($requires[$n] as $d) {
        if (isset($want[$d])) {
            $visit($d);
        }
    }
    $state[$n] = 1;
    $order[] = $n;
};

foreach (array_keys($want) as $n) {
    $visit($n);
}

echo implode(',', $order);
