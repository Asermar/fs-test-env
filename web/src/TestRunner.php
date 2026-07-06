<?php
/**
 * Ejecuta los tests de un plugin contra el entorno de pruebas
 * (test-env/facturascripts) y devuelve el resultado estructurado.
 *
 * Replica el flujo de `fsmaker run-tests` (copiar Test/<sub> al core, activar
 * plugins, lanzar PHPUnit) pero con --log-junit y la config phpunit-webrunner.xml
 * (que NO para al primer fallo), para mostrar todos los casos en la web.
 *
 * Las ejecuciones se serializan con flock: la BD de pruebas y la carpeta
 * Test/Plugins/ del core son recursos compartidos.
 */

namespace TestWeb;

class TestRunner
{
    /** @var string */
    private $baseDir;
    /** @var string */
    private $fsDir;
    /** @var string Layout del core dentro del proyecto (Mesa_FS 'src'; FS estándar '.'). */
    private $coreDir;

    public function __construct(string $baseDir)
    {
        $this->baseDir = $baseDir;
        $this->coreDir = getenv('FS_CORE_DIR') ?: 'src';
        $this->fsDir = getenv('TESTENV_DIR') ?: $baseDir . '/test-env/facturascripts';
    }

    /**
     * @return array<string, mixed>
     */
    public function run(string $plugin, string $sub, string $file = ''): array
    {
        if (!$this->safe($plugin) || !$this->safe($sub)) {
            return $this->fail('Parámetros no válidos.');
        }
        // fichero opcional: ejecuta SOLO ese *Test.php de la carpeta (el resto de la
        // carpeta -deps, install-plugins.txt- se sigue copiando y activando igual).
        if ($file !== '' && (!$this->safe($file) || substr($file, -8) !== 'Test.php')) {
            return $this->fail('Nombre de fichero de test no válido.');
        }

        $srcTest = $this->baseDir . '/' . $this->coreDir . '/Plugins/' . $plugin . '/Test/' . $sub;
        if (!is_dir($srcTest)) {
            return $this->fail('No existe la carpeta de tests: ' . $srcTest);
        }
        if (!is_file($this->fsDir . '/Core/Kernel.php') || !is_file($this->fsDir . '/config.php')) {
            return $this->fail('El entorno de pruebas no está provisionado (falta el core o config.php).');
        }
        $phpunit = $this->fsDir . '/vendor/bin/phpunit';
        if (!is_file($phpunit)) {
            return $this->fail('Falta PHPUnit. Provisiona el entorno (composer install).');
        }

        // config: preferimos la del runner web (sin stopOnFailure); si no, la estándar.
        $config = is_file($this->fsDir . '/phpunit-webrunner.xml')
            ? 'phpunit-webrunner.xml'
            : 'phpunit-plugins.xml';

        // --- lock (serializa ejecuciones) ---
        $lockPath = dirname($this->fsDir) . '/.webrunner.lock';
        $lock = fopen($lockPath, 'c');
        if ($lock === false || !flock($lock, LOCK_EX)) {
            return $this->fail('No se pudo adquirir el lock de ejecución.');
        }

        $dest = $this->fsDir . '/Test/Plugins';
        $junit = tempnam(sys_get_temp_dir(), 'junit_') . '.xml';
        $log = [];

        try {
            // 1) preparar Test/Plugins con los tests del plugin
            self::rrmdirContents($dest);
            if (!is_dir($dest)) {
                mkdir($dest, 0777, true);
            }
            self::copyDir($srcTest, $dest);

            // 2) activar plugins requeridos (install-plugins.php activa uno por
            //    ejecución y sale; lo llamamos en bucle hasta que no quede ninguno).
            $maxIterations = 25;
            for ($i = 0; $i < $maxIterations; $i++) {
                [, $out, ] = $this->exec('php Test/install-plugins.php');
                $log[] = trim($out);
                if (strpos($out, 'enabled') === false && strpos($out, 'not found') === false) {
                    break;
                }
                if (strpos($out, 'not found') !== false) {
                    break;
                }
            }

            // 3) ejecutar PHPUnit con logging JUnit. Si se indicó un fichero, se pasa
            //    como argumento para ejecutar solo ese caso (ignora la testsuite del config).
            $cmd = 'php ' . escapeshellarg('vendor/bin/phpunit')
                . ' -c ' . escapeshellarg($config)
                . ' --log-junit ' . escapeshellarg($junit);
            if ($file !== '') {
                $cmd .= ' ' . escapeshellarg('Test/Plugins/' . $file);
            }
            [$exitCode, $stdout, ] = $this->exec($cmd);

            $junitXml = is_file($junit) ? (string)file_get_contents($junit) : '';
            $parsed = JUnitParser::parse($junitXml);
        } finally {
            // 4) limpiar Test/Plugins y soltar el lock
            self::rrmdirContents($dest);
            @unlink($junit);
            flock($lock, LOCK_UN);
            fclose($lock);
        }

        return [
            'ok' => true,
            'plugin' => $plugin,
            'sub' => $sub,
            'file' => $file,
            'config' => $config,
            'exitCode' => $exitCode ?? -1,
            'stdout' => $stdout ?? '',
            'installLog' => implode("\n", array_filter($log)),
            'suites' => $parsed['suites'] ?? [],
            'totals' => $parsed['totals'] ?? [],
        ];
    }

    /**
     * Ejecuta un test del CORE de FacturaScripts (fichero o carpeta bajo Test/Core del
     * entorno de pruebas), sin copiar plugins ni activar nada. $path es relativo a la raíz
     * del core (p.ej. "Test/Core/Model/ClienteTest.php").
     *
     * @return array<string, mixed>
     */
    public function runCore(string $path): array
    {
        $path = ltrim(str_replace('\\', '/', $path), '/');
        if ($path === '' || strpos($path, '..') !== false || strpos($path, "\0") !== false
            || strpos($path, 'Test/Core') !== 0) {
            return $this->fail('Ruta de test del core no válida.');
        }
        if (!file_exists($this->fsDir . '/' . $path)) {
            return $this->fail('No existe el test del core: ' . $path);
        }
        if (!is_file($this->fsDir . '/Core/Kernel.php') || !is_file($this->fsDir . '/config.php')) {
            return $this->fail('El entorno de pruebas no está provisionado.');
        }
        if (!is_file($this->fsDir . '/vendor/bin/phpunit')) {
            return $this->fail('Falta PHPUnit. Provisiona el entorno (composer install).');
        }

        // config del runner web (sin stopOnFailure); si no, la estándar del core.
        $config = is_file($this->fsDir . '/phpunit-webrunner.xml') ? 'phpunit-webrunner.xml' : 'phpunit.xml';

        $lock = fopen(dirname($this->fsDir) . '/.webrunner.lock', 'c');
        if ($lock === false || !flock($lock, LOCK_EX)) {
            return $this->fail('No se pudo adquirir el lock de ejecución.');
        }
        $junit = tempnam(sys_get_temp_dir(), 'junit_') . '.xml';
        try {
            // pasar la ruta como argumento hace que PHPUnit ejecute SOLO ese fichero/carpeta,
            // ignorando la testsuite del config (que apunta a Test/Plugins).
            $cmd = 'php ' . escapeshellarg('vendor/bin/phpunit')
                . ' -c ' . escapeshellarg($config)
                . ' --log-junit ' . escapeshellarg($junit)
                . ' ' . escapeshellarg($path);
            [$exitCode, $stdout, ] = $this->exec($cmd);
            $junitXml = is_file($junit) ? (string)file_get_contents($junit) : '';
            $parsed = JUnitParser::parse($junitXml);
        } finally {
            @unlink($junit);
            flock($lock, LOCK_UN);
            fclose($lock);
        }

        return [
            'ok' => true,
            'core' => true,
            'path' => $path,
            'config' => $config,
            'exitCode' => $exitCode ?? -1,
            'stdout' => $stdout ?? '',
            'installLog' => '',
            'suites' => $parsed['suites'] ?? [],
            'totals' => $parsed['totals'] ?? [],
        ];
    }

    /**
     * Ejecuta un comando dentro de la carpeta del core, capturando stdout+stderr.
     *
     * @return array{0:int,1:string,2:string}
     */
    private function exec(string $command): array
    {
        $descriptors = [
            1 => ['pipe', 'w'],
            2 => ['pipe', 'w'],
        ];
        $process = proc_open($command, $descriptors, $pipes, $this->fsDir);
        if (!is_resource($process)) {
            return [-1, '', 'No se pudo iniciar: ' . $command];
        }
        $stdout = stream_get_contents($pipes[1]);
        $stderr = stream_get_contents($pipes[2]);
        fclose($pipes[1]);
        fclose($pipes[2]);
        $exit = proc_close($process);
        return [$exit, $stdout . $stderr, $stderr];
    }

    private function fail(string $message): array
    {
        return ['ok' => false, 'error' => $message];
    }

    private function safe(string $segment): bool
    {
        return $segment !== '' && strpbrk($segment, "/\\") === false && strpos($segment, '..') === false;
    }

    /** Borra el contenido de un directorio sin borrar el propio directorio. */
    private static function rrmdirContents(string $dir): void
    {
        if (!is_dir($dir)) {
            return;
        }
        $items = new \RecursiveIteratorIterator(
            new \RecursiveDirectoryIterator($dir, \RecursiveDirectoryIterator::SKIP_DOTS),
            \RecursiveIteratorIterator::CHILD_FIRST
        );
        foreach ($items as $item) {
            $item->isDir() ? @rmdir($item->getRealPath()) : @unlink($item->getRealPath());
        }
    }

    /** Copia recursivamente el contenido de $source dentro de $dest. */
    private static function copyDir(string $source, string $dest): void
    {
        $iterator = new \RecursiveIteratorIterator(
            new \RecursiveDirectoryIterator($source, \RecursiveDirectoryIterator::SKIP_DOTS),
            \RecursiveIteratorIterator::SELF_FIRST
        );
        foreach ($iterator as $item) {
            $target = $dest . DIRECTORY_SEPARATOR . $iterator->getSubPathName();
            if ($item->isDir()) {
                if (!is_dir($target)) {
                    mkdir($target, 0777, true);
                }
            } else {
                copy($item->getRealPath(), $target);
            }
        }
    }
}
