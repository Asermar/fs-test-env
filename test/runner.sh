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

# --- la contraseña de la base no sale en la respuesta ----------------------------------------
# Se mira la SALIDA, no quién la imprime: un phpunit de pega que la escribe (como haría el bootstrap del
# core, un Init o un test) y la respuesta no tiene que llevarla, sino «***» y un aviso. Contra TestRunner
# REAL. Para PostgreSQL, una copia del arnés con un pg-esquema.php de pega cuyo JSON la lleva.
printf '\n\033[1;36m— la contraseña de la base no sale en la respuesta —\033[0m\n'
CLAVE="ClaveDePrueba$$"
P="$BASE/proyecto"
for E in "$P/test-env/facturascripts" "$P/test-env/facturascripts-postgresql"; do
    mkdir -p "$E/Core" "$E/vendor/bin" "$E/Test/Core" "$E/Test/Plugins"
    : > "$E/Core/Kernel.php"; : > "$E/Test/Core/PegaTest.php"; printf '<?php\n' > "$E/vendor/bin/phpunit"
    printf '%s\n' '<?php' "define('FS_DB_PASS', '$CLAVE');" > "$E/config.php"
done
mkdir -p "$P/src/Plugins/Pega/Test/main"
A="$BASE/arnes"; mkdir -p "$A/web/src" "$A/bin"; cp "$T"/web/src/*.php "$A/web/src/"
printf '%s\n' '<?php' "echo json_encode(['ok' => false, 'error' => 'el Init de Pega dijo $CLAVE', 'errores' => []]), \"\\n\";" > "$A/bin/pg-esquema.php"
cat > "$BASE/bootstrap.php" <<'PHP'
<?php
[, $arnes, $proyecto, $motor, $que] = $argv;
require $arnes . '/web/src/JUnitParser.php';
require $arnes . '/web/src/TestRunner.php';
$t = new TestWeb\TestRunner($proyecto, $motor);
echo json_encode($que === 'core' ? $t->runCore('Test/Core/PegaTest.php') : $t->run('Pega', 'main')), "\n";
PHP
vuelca() { printf '%s\n' '<?php' "echo 'Clave: ' . '$CLAVE' . \"\\n\";" > "$P/test-env/facturascripts/vendor/bin/phpunit"; }
callado() { printf '%s\n' '<?php' "echo \"nada que ver\\n\";" > "$P/test-env/facturascripts/vendor/bin/phpunit"; }
redactada() { ! grep -qF "$CLAVE" <<<"$sal" && grep -qF '***' <<<"$sal" && grep -qF '"aviso"' <<<"$sal"; }
vuelca
sal="$(php "$BASE/bootstrap.php" "$T" "$P" mysql run 2>&1)"
redactada && ok "run(): un test que imprime la clave sale con *** y aviso, sin la clave" || mal "run() devolvió la clave o no avisó: $sal"
sal="$(php "$BASE/bootstrap.php" "$T" "$P" mysql core 2>&1)"
redactada && ok "runCore(): lo mismo" || mal "runCore() devolvió la clave o no avisó: $sal"
callado
sal="$(php "$BASE/bootstrap.php" "$T" "$P" mysql run 2>&1)"
! grep -qF '"aviso"' <<<"$sal" && grep -qF 'nada que ver' <<<"$sal" && ok "control: sin la clave en la salida, ni aviso ni nada cambiado" \
    || mal "control: run() avisa o cambia la salida sin motivo: $sal"
sal="$(php "$BASE/bootstrap.php" "$A" "$P" postgresql run 2>&1)"
redactada && grep -qF '"fase":"esquema"' <<<"$sal" && ok "PostgreSQL: la clave en lo que devuelve pg-esquema tampoco sale" \
    || mal "PostgreSQL: la respuesta del esquema llevaba la clave o no avisó: $sal"
sal="$(php "$BASE/bootstrap.php" "$A" "$P" postgresql core 2>&1)"
redactada && ok "PostgreSQL, runCore(): tampoco" || mal "PostgreSQL runCore() llevaba la clave: $sal"
# Sólo los campos de texto libre: una clave que coincide con parte del nombre de la configuración no la
# cambia (la respuesta mentiría sobre qué se ejecutó), pero sí se redacta en stdout.
pon_clave() { printf '%s\n' '<?php' "define('FS_DB_PASS', '$1');" > "$P/test-env/facturascripts/config.php"; }
CLAVE=unit-plugins; pon_clave "$CLAVE"; vuelca
sal="$(php "$BASE/bootstrap.php" "$T" "$P" mysql run 2>&1)"
grep -qF '"config":"phpunit-plugins.xml"' <<<"$sal" && grep -qF '"stdout":"Clave: ***' <<<"$sal" \
    && ok "la clave sólo se redacta en el texto libre: config sigue diciendo phpunit-plugins.xml" \
    || mal "la redacción tocó un campo que no es texto libre o no redactó stdout: $sal"
# Una clave corta no se redacta (taparía trozos de cualquier texto): se avisa de que no se pudo comprobar.
CLAVE=corta1; pon_clave "$CLAVE"; vuelca
sal="$(php "$BASE/bootstrap.php" "$T" "$P" mysql run 2>&1)"
grep -qF 'clave demasiado corta para redactarla' <<<"$sal" && grep -qF "Clave: $CLAVE" <<<"$sal" \
    && ok "clave de menos de 8: no se redacta y avisa de que no se pudo comprobar" \
    || mal "con una clave corta debía avisar sin redactar: $sal"
# La clave se lee cargando el config.php en un subproceso: vale cualquier forma de escribirla.
CLAVE="ClaveDePrueba$$"
printf '%s\n' '<?php' "DEFINE(\"FS_DB_PASS\", \"Clave\" . \"DePrueba$$\");" > "$P/test-env/facturascripts/config.php"; vuelca
sal="$(php "$BASE/bootstrap.php" "$T" "$P" mysql run 2>&1)"
redactada && ok "config.php con DEFINE, comillas dobles y concatenación: se lee y se redacta" \
    || mal "con otra forma de definir la clave no la redactó: $sal"
# Y si lo menciona pero no se puede cargar, se dice: la salida va sin redactar.
printf '%s\n' '<?php' "throw new Exception('roto');" "define('FS_DB_PASS', '$CLAVE');" > "$P/test-env/facturascripts/config.php"
sal="$(php "$BASE/bootstrap.php" "$T" "$P" mysql run 2>&1)"
grep -qF 'No pude leer la clave' <<<"$sal" && ok "config.php que no carga: avisa de que la salida no se ha redactado" \
    || mal "con un config.php que no carga debía avisar: $sal"

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
