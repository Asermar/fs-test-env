<?php
/**
 * Descubre los plugins de src/Plugins que tienen tests PHPUnit.
 *
 * Estructura esperada (la misma que usa fsmaker run-tests):
 *   src/Plugins/<Plugin>/Test/<sub>/<X>Test.php
 *   src/Plugins/<Plugin>/Test/<sub>/install-plugins.txt
 */

namespace TestWeb;

class TestScanner
{
    /** @var string Ruta a src/Plugins del repo. */
    private $pluginsDir;

    public function __construct(string $baseDir)
    {
        $this->pluginsDir = $baseDir . '/src/Plugins';
    }

    /**
     * Devuelve la lista de plugins con tests. Cada elemento:
     *   [
     *     'plugin' => 'Alias',
     *     'subs'   => [
     *        ['sub' => 'main', 'files' => ['AliasTest.php', ...], 'deps' => 'Alias'],
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
            $total = 0;
            foreach (scandir($testDir) as $sub) {
                if ($sub === '.' || $sub === '..') {
                    continue;
                }
                $subPath = $testDir . '/' . $sub;
                if (!is_dir($subPath)) {
                    continue;
                }

                $files = [];
                foreach (scandir($subPath) as $file) {
                    if (substr($file, -8) === 'Test.php') {
                        $files[] = $file;
                    }
                }
                if (empty($files)) {
                    continue;
                }
                sort($files);

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
                'subs' => $subs,
                'total' => $total,
            ];
        }

        return $result;
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
