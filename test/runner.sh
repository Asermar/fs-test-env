#!/usr/bin/env bash
# =============================================================================
# Batería del RUNNER WEB: `TestRunner::exec()` vuelve por mucho que el hijo
# escriba, y devuelve lo mismo que antes.
#
#   test/runner.sh                 # desde la raíz del arnés
#   test/runner.sh /ruta/al/arnes  # o diciéndole dónde está
#
# ## POR QUÉ EXISTE
#
# `exec()` leía stdout entero y sólo después stderr. Con muchos tests en rojo,
# phpunit llena el búfer del pipe de stderr (64 KB) antes de cerrar stdout, se
# queda en `pipe_write` y el runner espera a stdout para siempre: el
# `POST /?action=run` no vuelve nunca. Esta batería falla con ese código —se
# comprobó contra él— y pasa con la lectura simultánea.
#
# ## CÓMO SE PRUEBA
#
# Contra el `exec()` REAL, no una copia: se carga `web/src/TestRunner.php` y se
# invoca el método privado por reflexión, con un hijo `php -r` que escribe lo que
# se le pida por cada salida. Cada caso va dentro de `timeout`, para que un
# cuelgue se lea como cuelgue (rc 124) y no como una batería que no termina.
#
# **AUTOCONTENIDA**: sin contenedores, sin base de datos y sin red. Sólo `php`.
# =============================================================================
set -uo pipefail

T="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
[ -f "$T/web/src/TestRunner.php" ] || { echo "ERROR: no encuentro el runner en $T" >&2; exit 1; }

BASE="$(mktemp -d "${TMPDIR:-/tmp}/fs-test-runner-XXXXXX")"
trap 'rm -rf "$BASE"' EXIT

OK=0; FALLOS=0
ok()  { OK=$((OK+1));         printf '  \033[1;32m✓\033[0m %s\n' "$*"; }
mal() { FALLOS=$((FALLOS+1)); printf '  \033[1;31m✗\033[0m %s\n' "$*"; }

# Sonda: llama a exec() con un hijo que escribe <out> bytes 'o' por stdout, <err> bytes 'e' por
# stderr y sale con <rc>; e imprime lo que exec() devolvió, ya comprobado contra lo esperado.
cat > "$BASE/sonda.php" <<'PHP'
<?php
[, $arnes, $out, $err, $rc] = $argv;
require $arnes . '/web/src/TestRunner.php';
putenv('TESTENV_DIR=' . sys_get_temp_dir());   // exec() trabaja ahí: tiene que existir
$r = new TestWeb\TestRunner(sys_get_temp_dir());
$hijo = "fwrite(STDERR, str_repeat('e', $err)); echo str_repeat('o', $out); exit($rc);";
[$exit, $mezcla, $stderr] = (new ReflectionMethod($r, 'exec'))->invoke($r, 'php -r ' . escapeshellarg($hijo));
$o = str_repeat('o', (int)$out);
$e = str_repeat('e', (int)$err);
echo 'exit=', $exit === (int)$rc ? 'bien' : "mal($exit)", ' ';
echo 'mezcla=', $mezcla === $o . $e ? 'bien' : 'mal(' . strlen($mezcla) . ')', ' ';
echo 'stderr=', $stderr === $e ? 'bien' : 'mal(' . strlen($stderr) . ')', "\n";
PHP

# caso <título> <out> <err> <rc>
caso() {
    local titulo="$1" out="$2" err="$3" rc="$4" sal r
    printf '\n\033[1;36m— %s —\033[0m\n' "$titulo"
    sal="$(timeout 20 php "$BASE/sonda.php" "$T" "$out" "$err" "$rc" 2>&1)"; r=$?
    if [ "$r" -eq 124 ]; then mal "NO VUELVE: timeout a los 20 s (el interbloqueo de los pipes)"; return; fi
    [ "$r" -eq 0 ] && ok "vuelve" || { mal "la sonda falló (rc $r): $(tail -1 <<<"$sal")"; return; }
    sal="$(tail -1 <<<"$sal")"
    grep -qF 'exit=bien' <<<"$sal" && ok "devuelve el código de salida del hijo ($rc)" || mal "código de salida: $sal"
    grep -qF 'mezcla=bien' <<<"$sal" && ok "el segundo elemento es stdout seguido de stderr, entero" || mal "stdout.stderr: $sal"
    grep -qF 'stderr=bien' <<<"$sal" && ok "el tercer elemento es stderr, entero" || mal "stderr: $sal"
}

# Control positivo primero: salida pequeña, que también volvía con el código viejo. Sin él, un
# verde en el caso grande no distinguiría «lee bien» de «la sonda no mide nada».
caso "CONTROL POSITIVO: salida pequeña"                  3      1024   0
caso "stderr de 200 KB (más que el búfer del pipe)"      3      200000 1
caso "stdout de 200 KB y stderr de 200 KB a la vez"      200000 200000 2
caso "sin salida ninguna"                                0      0      0

# --- `failed`: los casos en rojo, con nombre, junto a los totales ---------------------------
# Quien imprime sólo el resumen (`jq '{ok,totals}'`) perdía qué test falló: el dato estaba en
# `suites[].cases[]`. Se pasa por el `JUnitParser::parse()` REAL un JUnit con la forma que emite
# PHPUnit (suite anidada, pass/fail/error/skip/warning).
printf '\n\033[1;36m— failed: los casos fail/error con nombre —\033[0m\n'
cat > "$BASE/junit.xml" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<testsuites>
  <testsuite name="Test/Plugins" tests="5">
    <testsuite name="A\ATest" tests="3">
      <testcase name="testBien" class="A\ATest" assertions="1" time="0.1"/>
      <testcase name="testMal" class="A\ATest" assertions="1" time="0.1"><failure type="PHPUnit\Framework\ExpectationFailedException">A\ATest::testMal
Failed asserting that false is true.

/ruta/ATest.php:12</failure></testcase>
      <testcase name="testSalta" class="A\ATest" assertions="0" time="0"><skipped/></testcase>
    </testsuite>
    <testsuite name="B\BTest" tests="2">
      <testcase name="testRevienta" class="B\BTest" assertions="0" time="0.1"><error type="Error">B\BTest::testRevienta
Error: Class "X" not found</error></testcase>
      <testcase name="testAvisa" class="B\BTest" assertions="1" time="0.1"><warning>aviso</warning></testcase>
    </testsuite>
  </testsuite>
</testsuites>
XML
cat > "$BASE/parser.php" <<'PHP'
<?php
[, $arnes, $xml] = $argv;
require $arnes . '/web/src/JUnitParser.php';
$p = TestWeb\JUnitParser::parse((string)file_get_contents($xml));
echo json_encode(['failed' => $p['failed'], 'totals' => $p['totals'], 'vacio' => TestWeb\JUnitParser::parse('')['failed']]), "\n";
PHP
sal="$(php "$BASE/parser.php" "$T" "$BASE/junit.xml" 2>&1)"
fal="$(php -r '$j=json_decode($argv[1],true); foreach($j["failed"] as $f) echo $f["test"],"|",$f["status"],"|",$f["message"],"\n";' "$sal")"
[ "$(wc -l <<<"$fal")" -eq 2 ] && ok "dos casos en failed: el fail y el error, ni el skip ni el warning" || mal "failed no trae exactamente 2: $sal"
grep -qxF 'A\ATest::testMal|fail|Failed asserting that false is true.' <<<"$fal" && ok "el fail, como Clase::metodo, con su status y el motivo (no la línea del nombre)" || mal "falta el fail: $fal"
grep -qxF 'B\BTest::testRevienta|error|Error: Class "X" not found' <<<"$fal" && ok "el error, de una suite distinta" || mal "falta el error: $fal"
grep -qF '"fail":1' <<<"$sal" && grep -qF '"error":1' <<<"$sal" && ok "y concuerda con totals (fail 1, error 1)" || mal "totals no concuerda: $sal"
grep -qF '"vacio":[]' <<<"$sal" && ok "sin JUnit, failed es una lista vacía (no falta la clave)" || mal "JUnit vacío: $sal"
for m in run runCore; do
    n="$(sed -n "/public function $m(/,/^    }/p" "$T/web/src/TestRunner.php" | grep -c "'failed' => \$parsed\['failed'\]")"
    [ "$n" -eq 1 ] && ok "$m() devuelve failed" || mal "$m() no devuelve failed"
done

# --- un bootstrap que vuelca la contraseña no se ejecuta --------------------------------------
# El Test/bootstrap.php del core escribe FS_DB_PASS en la salida y la provisión lo quita; si alguien lo
# pisa, el runner se niega, en los dos motores. Se mira el bootstrap que carga la configuración que se va
# a usar (phpunit-webrunner.xml carga Test/test-plugins.php), no un fichero fijo. Contra TestRunner REAL,
# con un entorno de pega que tiene todo lo que run() y runCore() comprueban antes.
printf '\n\033[1;36m— bootstrap que vuelca la contraseña —\033[0m\n'
P="$BASE/proyecto"; E="$P/test-env/facturascripts"
mkdir -p "$P/src/Plugins/Pega/Test/main" "$E/Core" "$E/vendor/bin" "$E/Test/Core"
: > "$E/Core/Kernel.php"; : > "$E/config.php"; printf '<?php\n' > "$E/vendor/bin/phpunit"; : > "$E/Test/Core/PegaTest.php"
cat > "$BASE/bootstrap.php" <<'PHP'
<?php
[, $arnes, $proyecto, $que] = $argv;
require $arnes . '/web/src/JUnitParser.php';
require $arnes . '/web/src/TestRunner.php';
$t = new TestWeb\TestRunner($proyecto);
$r = $que === 'core' ? $t->runCore('Test/Core/PegaTest.php') : $t->run('Pega', 'main');
echo (string) ($r['error'] ?? ''), "\n";
PHP
vuelca="echo \"\\n\" . 'Clave: ' . FS_DB_PASS;"
printf '%s\n' '<?xml version="1.0"?>' '<phpunit bootstrap="Test/test-plugins.php"></phpunit>' > "$E/phpunit-webrunner.xml"
printf '%s\n' '<?php' "$vuelca" > "$E/Test/test-plugins.php"; printf '%s\n' '<?php' > "$E/Test/bootstrap.php"
sal="$(php "$BASE/bootstrap.php" "$T" "$P" run 2>&1)"
grep -q "usa FS_DB_PASS" <<<"$sal" && ok "run(): el bootstrap de phpunit-webrunner.xml (test-plugins.php) usa FS_DB_PASS, y se niega" \
    || mal "run() no se niega con FS_DB_PASS en el bootstrap de su configuración: $sal"
printf '%s\n' '<?php' > "$E/Test/test-plugins.php"; printf '%s\n' '<?php' "$vuelca" > "$E/Test/bootstrap.php"
sal="$(php "$BASE/bootstrap.php" "$T" "$P" run 2>&1)"
! grep -q "FS_DB_PASS" <<<"$sal" && ok "run(): FS_DB_PASS en un bootstrap que su configuración NO carga no la para" \
    || mal "run() se niega por un fichero que su configuración no carga: $sal"
rm -f "$E/phpunit-webrunner.xml"
printf '%s\n' '<?xml version="1.0"?>' '<phpunit bootstrap="Test/bootstrap.php"></phpunit>' > "$E/phpunit.xml"
sal="$(php "$BASE/bootstrap.php" "$T" "$P" core 2>&1)"
grep -q "phpunit.xml (Test/bootstrap.php) usa FS_DB_PASS" <<<"$sal" && ok "runCore(): sin la del runner usa phpunit.xml, y su bootstrap la para" \
    || mal "runCore() no se niega con FS_DB_PASS en el bootstrap de phpunit.xml: $sal"
printf '%s\n' '<?php' > "$E/Test/bootstrap.php"
sal="$(php "$BASE/bootstrap.php" "$T" "$P" core 2>&1)"
! grep -q "FS_DB_PASS" <<<"$sal" && ok "control: sin FS_DB_PASS, runCore() no lo menciona" || mal "control: sin FS_DB_PASS runCore() se niega igual: $sal"

# --- una ejecución pedida desde OTRA web se rechaza ---------------------------------------------
# Ejecutar escribe en la base de pruebas: una página cualquiera abierta en el navegador no debe poder
# lanzarlo por POST. Contra el `TestRunner::rechazoCruzado()` REAL, con las cabeceras que manda cada
# cliente: la página del runner (mismo origen), curl o run.sh (ninguna) y otra web.
printf '\n\033[1;36m— peticiones de otra web —\033[0m\n'
cat > "$BASE/origen.php" <<'PHP'
<?php
[, $arnes] = $argv;
require $arnes . '/web/src/TestRunner.php';
$h = ['HTTP_HOST' => 'runner.ejemplo'];
foreach ([
    'curl'      => $h,
    'pagina'    => $h + ['HTTP_SEC_FETCH_SITE' => 'same-origin', 'HTTP_ORIGIN' => 'https://runner.ejemplo'],
    'otra'      => $h + ['HTTP_ORIGIN' => 'https://otra.ejemplo'],
    'cruzada'   => $h + ['HTTP_SEC_FETCH_SITE' => 'cross-site'],
    'nulo'      => $h + ['HTTP_ORIGIN' => 'null'],
] as $caso => $server) {
    echo $caso, '=', TestWeb\TestRunner::rechazoCruzado($server) === '' ? 'pasa' : 'rechaza', "\n";
}
PHP
org="$(php "$BASE/origen.php" "$T" 2>&1)"
for esperado in curl=pasa pagina=pasa otra=rechaza cruzada=rechaza nulo=rechaza; do
    grep -qxF "$esperado" <<<"$org" && ok "origen: $esperado" || mal "origen: se esperaba $esperado: $org"
done
grep -q 'rechazoCruzado(\$_SERVER)' "$T/web/public/index.php" && ok "index.php lo consulta antes de action=run" || mal "index.php no consulta rechazoCruzado"

printf '\n'
[ "$FALLOS" -eq 0 ] && { printf '\033[1;32m%s comprobaciones, todas en verde.\033[0m\n' "$OK"; exit 0; }
printf '\033[1;31m%s en verde, %s FALLIDAS.\033[0m\n' "$OK" "$FALLOS"; exit 1
