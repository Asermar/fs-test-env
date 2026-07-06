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

// raíz del repo: la app vive en podman/test/app/public, así que subimos 4 niveles
// (public -> app -> test -> podman -> raíz del repo).
$base = dirname(__DIR__, 4);

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
        $result = $runner->run(
            (string)($_POST['plugin'] ?? ''),
            (string)($_POST['sub'] ?? '')
        );
        json_out($result);
        break;

    default:
        $scanner = new TestScanner($base);
        $plugins = $scanner->plugins();
        render_page($plugins);
        break;
}

/**
 * @param array<int, array<string, mixed>> $plugins
 */
function render_page(array $plugins): void
{
    $data = json_encode($plugins, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
    $totalTests = array_sum(array_map(static fn($p) => $p['total'], $plugins));
    $nPlugins = count($plugins);
    ?>
<!DOCTYPE html>
<html lang="es">
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Tests de plugins · Mesa FS</title>
    <link rel="stylesheet" href="assets/style.css?v=<?= @filemtime(__DIR__ . '/assets/style.css') ?>">
    <link rel="stylesheet"
          href="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/styles/github-dark.min.css">
</head>
<body>
    <header class="topbar">
        <h1>Tests de plugins</h1>
        <div class="meta"><?= $nPlugins ?> plugins · <?= $totalTests ?> ficheros de test</div>
    </header>

    <main id="app">
        <aside class="sidebar" id="sidebar"></aside>
        <section class="content" id="content">
            <div class="placeholder">Selecciona un plugin a la izquierda para ver sus tests.</div>
        </section>
    </main>

    <script>window.__PLUGINS__ = <?= $data ?>;</script>
    <script src="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/highlight.min.js"></script>
    <script src="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/languages/php.min.js"></script>
    <script src="assets/app.js?v=<?= @filemtime(__DIR__ . '/assets/app.js') ?>"></script>
</body>
</html>
    <?php
    exit;
}
