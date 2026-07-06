<?php
/**
 * Descubre los plugins de src/Plugins que tienen tests PHPUnit.
 *
 * Estructura esperada (la misma que usa fsmaker run-tests):
 *   src/Plugins/<Plugin>/Test/<sub>/<X>Test.php
 *   src/Plugins/<Plugin>/Test/<sub>/install-plugins.txt
 */

namespace TestWeb;

require_once __DIR__ . '/TestDoc.php';

class TestScanner
{
    /** @var string Ruta a la carpeta Plugins del proyecto. */
    private $pluginsDir;
    /** @var string Raíz del core de pruebas (test-env/facturascripts). */
    private $fsDir;

    public function __construct(string $baseDir)
    {
        // layout del core dentro del proyecto (Mesa_FS usa 'src'; FS estándar '.').
        $coreDir = getenv('FS_CORE_DIR') ?: 'src';
        $this->pluginsDir = $baseDir . '/' . $coreDir . '/Plugins';
        $this->fsDir = getenv('TESTENV_DIR') ?: $baseDir . '/test-env/facturascripts';
    }

    /**
     * Tests propios del CORE de FacturaScripts, tomados de Test/Core del entorno de pruebas.
     * Devuelve una entrada análoga a un plugin pero con isCore=true y, en cada fichero, su
     * 'path' relativo a la raíz del core (para poder ejecutarlo). Agrupa por carpeta.
     *
     * @return array<string, mixed>|null  null si el entorno no está provisionado
     */
    public function core(): array
    {
        $testDir = $this->fsDir . '/Test/Core';
        $result = ['plugin' => 'FacturaScripts Core', 'isCore' => true, 'subs' => [], 'total' => 0, 'tests' => 0];
        if (!is_dir($testDir)) {
            return $result;
        }

        // agrupamos los *Test.php por carpeta (relativa a Test/), p.ej. Core, Core/Model, Core/Lib.
        $groups = [];
        $it = new \RecursiveIteratorIterator(
            new \RecursiveDirectoryIterator($testDir, \FilesystemIterator::SKIP_DOTS)
        );
        foreach ($it as $file) {
            if (substr($file->getFilename(), -8) !== 'Test.php') {
                continue;
            }
            $abs = $file->getPathname();
            $rel = ltrim(str_replace($this->fsDir, '', $abs), '/');      // Test/Core/Model/XTest.php
            $group = str_replace($this->fsDir . '/Test/', '', dirname($abs)); // Core, Core/Model...
            $groups[$group][] = ['name' => $file->getFilename(), 'path' => $rel, 'tests' => $this->countTests($abs)];
        }
        ksort($groups);

        foreach ($groups as $group => $files) {
            usort($files, static fn($a, $b) => strcmp($a['name'], $b['name']));
            $result['subs'][] = ['sub' => $group, 'deps' => '', 'files' => $files];
            $result['total'] += count($files);
            foreach ($files as $f) {
                $result['tests'] += $f['tests'];
            }
        }
        return $result;
    }

    /**
     * Cuenta los tests reales de un fichero: cada método test*() (o con @test) cuenta 1,
     * salvo que use @dataProvider, en cuyo caso cuenta el nº de casos que aporta el provider
     * (elementos del array que devuelve, o nº de yields). Coincide con lo que ejecuta PHPUnit.
     */
    private function countTests(string $absPath): int
    {
        $src = @file_get_contents($absPath);
        if ($src === false) {
            return 0;
        }

        $funcs = $this->parseFunctions($src); // nombre => ['doc' => string, 'datasets' => int|null]

        $total = 0;
        foreach ($funcs as $name => $info) {
            $isTest = stripos($name, 'test') === 0 || preg_match('/@test\b/', $info['doc']);
            if (!$isTest) {
                continue;
            }
            if (preg_match('/@dataProvider\s+([\\\\A-Za-z0-9_:]+)/', $info['doc'], $m)) {
                $prov = $m[1];
                if (($pos = strrpos($prov, '::')) !== false) {
                    $prov = substr($prov, $pos + 2);
                }
                $n = $funcs[$prov]['datasets'] ?? null;
                $total += ($n && $n > 0) ? $n : 1; // si no se puede contar el provider, cuenta 1
            } else {
                $total++;
            }
        }
        return $total;
    }

    /**
     * Extrae las funciones del fichero: nombre => ['doc' => docblock previo, 'datasets' => nº
     * de elementos del array devuelto (para providers), o null si no es un return de array].
     *
     * @return array<string, array{doc:string, datasets:int|null}>
     */
    private function parseFunctions(string $src): array
    {
        $tokens = token_get_all($src);
        $n = count($tokens);
        $funcs = [];
        $lastDoc = '';
        $modifiers = [T_PUBLIC, T_PROTECTED, T_PRIVATE, T_STATIC, T_FINAL, T_ABSTRACT];

        for ($i = 0; $i < $n; $i++) {
            $t = $tokens[$i];
            if (is_array($t)) {
                if ($t[0] === T_DOC_COMMENT) {
                    $lastDoc = $t[1];
                    continue;
                }
                if ($t[0] === T_WHITESPACE || in_array($t[0], $modifiers, true)) {
                    continue; // los modificadores van entre el docblock y function: no reinician
                }
                if ($t[0] === T_FUNCTION) {
                    $name = null;
                    for ($j = $i + 1; $j < $n; $j++) {
                        if (is_array($tokens[$j]) && $tokens[$j][0] === T_STRING) {
                            $name = $tokens[$j][1];
                            $i = $j;
                            break;
                        }
                        if ($tokens[$j] === '(') {
                            break; // función anónima, sin nombre
                        }
                    }
                    // localizar el cuerpo { ... } (o ; si es abstracto)
                    $datasets = null;
                    for ($j = $i + 1; $j < $n; $j++) {
                        if ($tokens[$j] === '{') {
                            $datasets = $this->countDatasetsInBody($tokens, $j, $n);
                            break;
                        }
                        if ($tokens[$j] === ';') {
                            break;
                        }
                    }
                    if ($name !== null) {
                        $funcs[$name] = ['doc' => $lastDoc, 'datasets' => $datasets];
                    }
                    $lastDoc = '';
                    continue;
                }
                $lastDoc = ''; // cualquier otro token de código: el docblock ya no es de una función
            } else {
                if ($t === '{' || $t === '}' || $t === ';') {
                    $lastDoc = '';
                }
            }
        }
        return $funcs;
    }

    /**
     * Dado el índice del '{' que abre el cuerpo de una función, devuelve el nº de casos que
     * aportaría como dataProvider: nº de yields, o nº de elementos de primer nivel del array
     * que devuelve. null si el return no es un array literal (no contable estáticamente).
     */
    private function countDatasetsInBody(array $tokens, int $bodyStart, int $n): ?int
    {
        // localizar el '}' que cierra el cuerpo
        $depth = 0;
        $end = $n;
        for ($j = $bodyStart; $j < $n; $j++) {
            if ($tokens[$j] === '{') {
                $depth++;
            } elseif ($tokens[$j] === '}') {
                $depth--;
                if ($depth === 0) {
                    $end = $j;
                    break;
                }
            }
        }

        // generador: contar yields
        $yields = 0;
        for ($j = $bodyStart; $j < $end; $j++) {
            if (is_array($tokens[$j])
                && ($tokens[$j][0] === T_YIELD || (defined('T_YIELD_FROM') && $tokens[$j][0] === T_YIELD_FROM))) {
                $yields++;
            }
        }
        if ($yields > 0) {
            return $yields;
        }

        // primer return con array literal ([...] o array(...))
        for ($j = $bodyStart; $j < $end; $j++) {
            if (is_array($tokens[$j]) && $tokens[$j][0] === T_RETURN) {
                $k = $j + 1;
                while ($k < $end && is_array($tokens[$k]) && $tokens[$k][0] === T_WHITESPACE) {
                    $k++;
                }
                if ($k < $end && $tokens[$k] === '[') {
                    return $this->countTopLevelElements($tokens, $k, $end);
                }
                if ($k < $end && is_array($tokens[$k]) && $tokens[$k][0] === T_ARRAY) {
                    $k++;
                    while ($k < $end && is_array($tokens[$k]) && $tokens[$k][0] === T_WHITESPACE) {
                        $k++;
                    }
                    if ($k < $end && $tokens[$k] === '(') {
                        return $this->countTopLevelElements($tokens, $k, $end);
                    }
                }
                return null; // return de algo que no es un array literal
            }
        }
        return null;
    }

    /**
     * Cuenta los elementos de primer nivel de un array literal cuyo paréntesis/corchete de
     * apertura está en $openIdx. Cuenta comas al nivel 1 de anidamiento (los arrays internos,
     * al aumentar la profundidad, no cuentan) y suma 1 si hay contenido tras la última coma.
     */
    private function countTopLevelElements(array $tokens, int $openIdx, int $end): int
    {
        $depth = 0;
        $commas = 0;
        $sawContent = false;
        for ($j = $openIdx; $j < $end; $j++) {
            $tk = $tokens[$j];
            if ($tk === '[' || $tk === '(' || $tk === '{') {
                if ($depth === 1) {
                    $sawContent = true; // el elemento actual es un array/llamada anidada
                }
                $depth++;
                continue;
            }
            if ($tk === ']' || $tk === ')' || $tk === '}') {
                $depth--;
                if ($depth === 0) {
                    break;
                }
                continue;
            }
            if ($depth !== 1) {
                continue;
            }
            if ($tk === ',') {
                $commas++;
                $sawContent = false;
                continue;
            }
            if (is_array($tk)) {
                if ($tk[0] !== T_WHITESPACE && $tk[0] !== T_COMMENT && $tk[0] !== T_DOC_COMMENT) {
                    $sawContent = true;
                }
            } else {
                $sawContent = true;
            }
        }
        return $commas + ($sawContent ? 1 : 0);
    }

    /**
     * Devuelve la lista de plugins con tests. Cada elemento:
     *   [
     *     'plugin' => 'Alias',
     *     'subs'   => [
     *        ['sub' => 'main', 'deps' => 'Alias', 'files' => [
     *            ['name' => 'AliasTest.php', 'desc' => '<html>|null', 'methods' => [
     *                ['name' => 'testX', 'title' => 'X', 'desc' => '<html>|null'],
     *            ]],
     *        ]],
     *     ],
     *     'total'  => 1,   // nº total de ficheros *Test.php
     *   ]
     *
     * @return array<int, array<string, mixed>>
     */
    public function plugins(): array
    {
        $result = [];

        if (!is_dir($this->pluginsDir)) {
            return $result;
        }

        foreach (scandir($this->pluginsDir) as $plugin) {
            if ($plugin === '.' || $plugin === '..') {
                continue;
            }

            $testDir = $this->pluginsDir . '/' . $plugin . '/Test';
            if (!is_dir($testDir)) {
                continue;
            }

            $subs = [];
            $total = 0;       // nº de ficheros *Test.php
            $tests = 0;       // nº de métodos test*() (tests reales a ejecutar)
            foreach (scandir($testDir) as $sub) {
                if ($sub === '.' || $sub === '..') {
                    continue;
                }
                $subPath = $testDir . '/' . $sub;
                if (!is_dir($subPath)) {
                    continue;
                }

                $fileNames = [];
                foreach (scandir($subPath) as $file) {
                    if (substr($file, -8) === 'Test.php') {
                        $fileNames[] = $file;
                    }
                }
                if (empty($fileNames)) {
                    continue;
                }
                sort($fileNames);

                // enriquecemos cada fichero con su descripción (markdown -> HTML) y las
                // descripciones de sus métodos test*(), extraídas del propio fichero.
                $files = [];
                foreach ($fileNames as $file) {
                    $doc = TestDoc::forFile($subPath . '/' . $file);
                    $files[] = [
                        'name' => $file,
                        'desc' => $doc['class'],
                        'methods' => $doc['methods'],
                    ];
                    $tests += $this->countTests($subPath . '/' . $file); // cuenta casos (con dataProviders)
                }

                $depsFile = $subPath . '/install-plugins.txt';
                $deps = is_file($depsFile) ? trim((string)file_get_contents($depsFile)) : '';

                $subs[] = [
                    'sub' => $sub,
                    'files' => $files,
                    'deps' => $deps,
                ];
                $total += count($files);
            }

            if (empty($subs)) {
                continue;
            }

            $result[] = [
                'plugin' => $plugin,
                'version' => $this->pluginVersion($plugin),
                'subs' => $subs,
                'total' => $total,
                'tests' => $tests,
            ];
        }

        return $result;
    }

    /** Versión del plugin leída de su facturascripts.ini (o '' si no se encuentra). */
    private function pluginVersion(string $plugin): string
    {
        $ini = $this->pluginsDir . '/' . $plugin . '/facturascripts.ini';
        if (!is_file($ini)) {
            return '';
        }
        $content = (string)file_get_contents($ini);
        if (preg_match('/^\s*version\s*=\s*[\'"]?([0-9][0-9.]*)/mi', $content, $m)) {
            return $m[1];
        }
        return '';
    }

    /**
     * Lee el código fuente de un fichero de test, validando rutas para evitar
     * traversal. Devuelve null si no es válido.
     */
    public function source(string $plugin, string $sub, string $file): ?string
    {
        if (!$this->safe($plugin) || !$this->safe($sub) || !$this->safe($file)) {
            return null;
        }
        if (substr($file, -8) !== 'Test.php') {
            return null;
        }

        $path = $this->pluginsDir . '/' . $plugin . '/Test/' . $sub . '/' . $file;
        $real = realpath($path);
        $baseReal = realpath($this->pluginsDir);
        if ($real === false || $baseReal === false || strpos($real, $baseReal) !== 0) {
            return null;
        }

        $content = file_get_contents($real);
        return $content === false ? null : $content;
    }

    /** Un segmento de ruta es seguro si no contiene separadores ni '..'. */
    private function safe(string $segment): bool
    {
        return $segment !== '' && strpbrk($segment, "/\\") === false && strpos($segment, '..') === false;
    }
}
