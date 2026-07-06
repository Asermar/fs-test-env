<?php
/**
 * Front controller del runner web de tests.
 *
 * Sin framework ni dependencias: enruta por ?action= y sirve la página o JSON.
 *   (vacío)        -> página HTML con el listado de plugins con tests
 *   action=source  -> JSON con el código fuente de un fichero *Test.php
 *   action=run     -> (POST) ejecuta los tests de un plugin y devuelve JSON
 */

declare(strict_types=1);

require __DIR__ . '/../src/TestScanner.php';
require __DIR__ . '/../src/JUnitParser.php';
require __DIR__ . '/../src/TestRunner.php';

use TestWeb\TestScanner;
use TestWeb\TestRunner;

// raíz del proyecto FacturaScripts. La app vive en test-bin/web/public, así que
// subimos 3 niveles (public -> web -> test-bin -> raíz). Override con FS_PROJECT_ROOT.
$base = getenv('FS_PROJECT_ROOT') ?: dirname(__DIR__, 3);

$action = $_GET['action'] ?? '';

function json_out($data): void
{
    header('Content-Type: application/json; charset=utf-8');
    echo json_encode($data, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
    exit;
}

switch ($action) {
    case 'source':
        $scanner = new TestScanner($base);
        $src = $scanner->source(
            (string)($_GET['plugin'] ?? ''),
            (string)($_GET['sub'] ?? ''),
            (string)($_GET['file'] ?? '')
        );
        if ($src === null) {
            http_response_code(404);
            json_out(['ok' => false, 'error' => 'Fichero no encontrado.']);
        }
        json_out(['ok' => true, 'source' => $src]);
        break;

    case 'run':
        if ($_SERVER['REQUEST_METHOD'] !== 'POST') {
            http_response_code(405);
            json_out(['ok' => false, 'error' => 'Método no permitido.']);
        }
        $runner = new TestRunner($base);
        if (!empty($_POST['core'])) {
            $result = $runner->runCore((string)($_POST['path'] ?? ''));
        } else {
            $result = $runner->run(
                (string)($_POST['plugin'] ?? ''),
                (string)($_POST['sub'] ?? ''),
                (string)($_POST['file'] ?? '')
            );
        }
        json_out($result);
        break;

    default:
        $scanner = new TestScanner($base);
        $plugins = $scanner->plugins();
        $core = $scanner->core();
        if (($core['total'] ?? 0) > 0) {
            array_unshift($plugins, $core); // la sección Core va primero
        }
        render_page($plugins, core_ref($base));
        break;
}

/** Versión del entorno de test (fichero VERSION del submódulo fs-test-env). */
function env_version(): string
{
    $f = dirname(__DIR__, 2) . '/VERSION';
    return is_file($f) ? trim((string)file_get_contents($f)) : '';
}

/** Referencia (tag o rama) del core de FacturaScripts provisionado en test-env. */
function core_ref(string $base): string
{
    $fsDir = getenv('TESTENV_DIR') ?: $base . '/test-env/facturascripts';

    // si hay git y el core es un repo, el tag exacto (o la rama) es lo más fiable.
    if (is_dir($fsDir . '/.git') && function_exists('shell_exec')) {
        $g = 'git -C ' . escapeshellarg($fsDir) . ' ';
        $tag = trim((string)@shell_exec($g . 'describe --tags --exact-match HEAD 2>/dev/null'));
        if ($tag !== '') {
            return $tag;
        }
        $branch = trim((string)@shell_exec($g . 'rev-parse --abbrev-ref HEAD 2>/dev/null'));
        if ($branch !== '' && $branch !== 'HEAD') {
            return $branch;
        }
    }

    // fallback sin git: versión del Kernel del core -> tag equivalente vX.
    $kernel = $fsDir . '/Core/Kernel.php';
    if (is_file($kernel)
        && preg_match('/function\s+version\s*\([^)]*\)\s*:\s*float\s*\{\s*return\s+([0-9.]+)/s', (string)file_get_contents($kernel), $m)) {
        return 'v' . $m[1];
    }

    return '';
}

/**
 * @param array<int, array<string, mixed>> $plugins
 */
function render_page(array $plugins, string $coreRef): void
{
    $data = json_encode($plugins, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
    $totalTests = array_sum(array_map(static fn($p) => $p['total'], $plugins));
    $nPlugins = count($plugins);
    $title = getenv('TEST_WEB_TITLE') ?: 'Tests de plugins';
    $envVersion = env_version();
    ?>
<!DOCTYPE html>
<html lang="es">
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title><?= htmlspecialchars($title, ENT_QUOTES) ?></title>
    <link rel="stylesheet" href="assets/style.css?v=<?= @filemtime(__DIR__ . '/assets/style.css') ?>">
    <link rel="stylesheet"
          href="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/styles/github-dark.min.css">
</head>
<body>
    <div id="busybar" class="busybar" aria-hidden="true"></div>
    <header class="topbar">
        <h1><?= htmlspecialchars($title, ENT_QUOTES) ?></h1>
        <span id="running" class="running-indicator"><span class="spinner"></span> Ejecutando…</span>
        <div class="meta">
            <?= $nPlugins ?> plugins · <?= $totalTests ?> ficheros de test<?php if ($coreRef !== ''): ?>
            · core <span class="core-ref"><?= htmlspecialchars($coreRef, ENT_QUOTES) ?></span><?php endif ?><?php if ($envVersion !== ''): ?>
            · entorno <span class="core-ref">v<?= htmlspecialchars($envVersion, ENT_QUOTES) ?></span><?php endif ?>
        </div>
    </header>

    <main id="app">
        <aside class="sidebar" id="sidebar"></aside>
        <section class="content" id="content">
            <div class="placeholder">Selecciona un plugin a la izquierda para ver sus tests.</div>
        </section>
    </main>

    <footer class="pagefoot">
        <button id="toTop" class="ghost" type="button">↑ Volver arriba</button>
    </footer>

    <script>window.__PLUGINS__ = <?= $data ?>;</script>
    <script src="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/highlight.min.js"></script>
    <script src="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/languages/php.min.js"></script>
    <script src="assets/app.js?v=<?= @filemtime(__DIR__ . '/assets/app.js') ?>"></script>
</body>
</html>
    <?php
    exit;
}
