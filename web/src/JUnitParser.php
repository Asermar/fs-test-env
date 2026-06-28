<?php
/**
 * Convierte el XML JUnit que emite PHPUnit (--log-junit) en una estructura
 * sencilla para la web: suites con sus casos (estado, tiempo, aserciones y,
 * en los fallos, tipo + mensaje + traza).
 */

namespace TestWeb;

class JUnitParser
{
    /**
     * @return array{
     *   suites: array<int, array<string, mixed>>,
     *   totals: array<string, int|float>
     * }
     */
    public static function parse(string $xmlContent): array
    {
        $out = ['suites' => [], 'totals' => self::emptyTotals()];

        if (trim($xmlContent) === '') {
            return $out;
        }

        $prev = libxml_use_internal_errors(true);
        $xml = simplexml_load_string($xmlContent);
        libxml_use_internal_errors($prev);
        if ($xml === false) {
            return $out;
        }

        // Las suites de primer nivel (una por fichero/clase de test).
        foreach ($xml->testsuite as $suite) {
            self::collect($suite, $out);
        }

        return $out;
    }

    /**
     * Recorre recursivamente: una <testsuite> puede contener subsuites y/o
     * <testcase>. Aplanamos a "suites con casos directos".
     */
    private static function collect(\SimpleXMLElement $suite, array &$out): void
    {
        $cases = [];
        foreach ($suite->testcase as $case) {
            $cases[] = self::caseToArray($case, $out['totals']);
        }

        if (!empty($cases)) {
            $attr = $suite->attributes();
            $out['suites'][] = [
                'name' => (string)($attr['name'] ?? ''),
                'time' => (float)($attr['time'] ?? 0),
                'cases' => $cases,
            ];
        }

        // subsuites
        foreach ($suite->testsuite as $child) {
            self::collect($child, $out);
        }
    }

    private static function caseToArray(\SimpleXMLElement $case, array &$totals): array
    {
        $attr = $case->attributes();
        $status = 'pass';
        $type = '';
        $message = '';
        $detail = '';

        if (isset($case->error)) {
            $status = 'error';
            [$type, $message, $detail] = self::issue($case->error);
        } elseif (isset($case->failure)) {
            $status = 'fail';
            [$type, $message, $detail] = self::issue($case->failure);
        } elseif (isset($case->skipped)) {
            $status = 'skip';
        } elseif (isset($case->warning)) {
            $status = 'warning';
            [$type, $message, $detail] = self::issue($case->warning);
        }

        $totals['tests']++;
        $totals[$status] = ($totals[$status] ?? 0) + 1;
        $totals['assertions'] += (int)($attr['assertions'] ?? 0);
        $totals['time'] += (float)($attr['time'] ?? 0);

        return [
            'name' => (string)($attr['name'] ?? ''),
            'class' => (string)($attr['class'] ?? ($attr['classname'] ?? '')),
            'status' => $status,
            'assertions' => (int)($attr['assertions'] ?? 0),
            'time' => (float)($attr['time'] ?? 0),
            'type' => $type,
            'message' => $message,
            'detail' => $detail,
        ];
    }

    /**
     * Extrae tipo, primera línea (mensaje) y texto completo (traza) de un nodo
     * <failure>/<error>/<warning>.
     *
     * @return array{0:string,1:string,2:string}
     */
    private static function issue(\SimpleXMLElement $node): array
    {
        $type = (string)($node->attributes()['type'] ?? '');
        $detail = trim((string)$node);
        $message = $detail === '' ? '' : strtok($detail, "\n");
        return [$type, (string)$message, $detail];
    }

    private static function emptyTotals(): array
    {
        return [
            'tests' => 0,
            'pass' => 0,
            'fail' => 0,
            'error' => 0,
            'skip' => 0,
            'warning' => 0,
            'assertions' => 0,
            'time' => 0.0,
        ];
    }
}
