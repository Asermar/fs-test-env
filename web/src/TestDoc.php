<?php
/**
 * Extrae descripciones (markdown -> HTML) de un fichero *Test.php SIN ejecutarlo.
 *
 * La app web no tiene cargado el framework FacturaScripts ni PHPUnit, así que no se
 * puede instanciar la clase de test: se tokeniza el fichero con token_get_all() y se
 * asocia cada docblock a la clase o al método test*() que le sigue.
 *
 * Convención (las dos soluciones):
 *   - Si el docblock contiene un tag @description, se usa el texto que va tras él
 *     (hasta el próximo @tag o el final del bloque).
 *   - Si no hay tag, se usa TODO el texto del docblock (ignorando otras líneas @...).
 * El texto resultante se interpreta como markdown y se renderiza a HTML con Parsedown
 * en modo seguro.
 */

namespace TestWeb;

require_once __DIR__ . '/Parsedown.php';

class TestDoc
{
    /**
     * Devuelve las descripciones de un fichero de test:
     *   [
     *     'class'   => '<html>...</html>' | null,
     *     'methods' => [
     *        ['name' => 'testX', 'title' => 'X', 'desc' => '<html>...' | null],
     *        ...
     *     ],
     *   ]
     *
     * @return array<string, mixed>
     */
    public static function forFile(string $path): array
    {
        $out = ['class' => null, 'methods' => []];

        $code = @file_get_contents($path);
        if ($code === false || $code === '') {
            return $out;
        }

        $tokens = token_get_all($code);
        $pendingDoc = null;

        for ($i = 0, $n = count($tokens); $i < $n; $i++) {
            $tok = $tokens[$i];

            // los tokens de un carácter (llaves, ; etc.) son strings, no arrays
            if (!is_array($tok)) {
                continue;
            }

            switch ($tok[0]) {
                case T_DOC_COMMENT:
                    $pendingDoc = $tok[1];
                    break;

                case T_CLASS:
                    if ($pendingDoc !== null) {
                        $out['class'] = self::render($pendingDoc);
                        $pendingDoc = null;
                    }
                    break;

                case T_FUNCTION:
                    $name = self::nextName($tokens, $i);
                    if ($name !== null && strncmp($name, 'test', 4) === 0) {
                        $out['methods'][] = [
                            'name' => $name,
                            'title' => self::humanize($name),
                            'desc' => $pendingDoc !== null ? self::render($pendingDoc) : null,
                        ];
                    }
                    $pendingDoc = null;
                    break;

                // cualquier otro token con contenido (no espacios) rompe la adyacencia
                // del docblock, salvo los modificadores que pueden ir entre medias.
                case T_WHITESPACE:
                case T_ABSTRACT:
                case T_FINAL:
                case T_PUBLIC:
                case T_PROTECTED:
                case T_PRIVATE:
                case T_STATIC:
                case T_ATTRIBUTE:
                    break;

                default:
                    $pendingDoc = null;
                    break;
            }
        }

        return $out;
    }

    /** Nombre (T_STRING) que sigue a un T_FUNCTION, saltando espacios y '&' de retorno por referencia. */
    private static function nextName(array $tokens, int $i): ?string
    {
        $n = count($tokens);
        for ($j = $i + 1; $j < $n; $j++) {
            $t = $tokens[$j];
            if (is_array($t)) {
                if ($t[0] === T_WHITESPACE) {
                    continue;
                }
                if ($t[0] === T_STRING) {
                    return $t[1];
                }
                return null;
            }
            if ($t === '&') {
                continue;
            }
            return null;
        }
        return null;
    }

    /** Convierte el texto de un docblock en HTML de markdown (o null si queda vacío). */
    private static function render(string $docblock): ?string
    {
        $text = self::extractText($docblock);
        if ($text === '') {
            return null;
        }

        $parsedown = new \Parsedown();
        $parsedown->setSafeMode(true);
        $html = trim($parsedown->text($text));

        return $html === '' ? null : $html;
    }

    /**
     * Limpia el docblock (quita las marcas de comentario) y devuelve el markdown:
     * el bloque tras @description si existe, o todo el texto sin líneas @tag en caso
     * contrario.
     */
    private static function extractText(string $docblock): string
    {
        // quitamos /** y */
        $body = preg_replace('#^\s*/\*\*?#', '', $docblock);
        $body = preg_replace('#\*/\s*$#', '', (string)$body);

        // limpiamos el ' * ' inicial de cada línea
        $lines = preg_split('/\R/', (string)$body) ?: [];
        $clean = [];
        foreach ($lines as $line) {
            $clean[] = preg_replace('/^\s*\*?[ \t]?/', '', $line);
        }

        // ¿hay tag @description? tomamos desde ahí hasta el próximo @tag o el final
        $inDesc = false;
        $collected = [];
        $usedTag = false;
        foreach ($clean as $line) {
            if (preg_match('/^@description\b[ \t]*(.*)$/i', $line, $m)) {
                $usedTag = true;
                $inDesc = true;
                if (trim($m[1]) !== '') {
                    $collected[] = $m[1];
                }
                continue;
            }
            if ($inDesc) {
                if (preg_match('/^@\w+/', trim($line))) {
                    $inDesc = false; // otro tag corta la descripción
                    continue;
                }
                $collected[] = $line;
            }
        }

        if (!$usedTag) {
            // fallback: todo el docblock, descartando líneas de tags @...
            $collected = array_filter($clean, static fn($l) => !preg_match('/^\s*@\w+/', $l));
        }

        return trim(implode("\n", $collected));
    }

    /** "testImportDisabledWhenCsvImport" -> "Import disabled when csv import". */
    private static function humanize(string $method): string
    {
        $name = preg_replace('/^test/', '', $method);
        $name = preg_replace('/(?<=[a-z0-9])(?=[A-Z])/', ' ', (string)$name);
        $name = str_replace('_', ' ', (string)$name);
        $name = trim((string)$name);
        if ($name === '') {
            return $method;
        }
        return ucfirst(strtolower($name));
    }
}
