# fs-test-env

<p align="center">
  <a href="#changelog"><img alt="Versión" src="https://img.shields.io/badge/Versi%C3%B3n-3.0.0-2E7D6E?style=for-the-badge"></a>
  <img alt="FacturaScripts" src="https://img.shields.io/badge/FacturaScripts-2026%2B-0C7C59?style=for-the-badge">
  <img alt="PHPUnit" src="https://img.shields.io/badge/PHPUnit-9.6-6E9B34?style=for-the-badge">
</p>

Tooling reutilizable para montar un **entorno de pruebas de FacturaScripts** (PHPUnit) y
ejecutar los tests de los plugins, con un **runner web** navegable — sin tocar la instalación ni
la base de datos de trabajo del proyecto.

Pensado para montarse como **submódulo git** (`test-bin/`) en cualquier proyecto FacturaScripts.
No contiene ningún valor específico de un proyecto: la configuración del despliegue se genera con
`init-project.sh` en un fichero `.fs-test-env.env` del proyecto.

## Manual de uso

El **manual de uso del runner web** —con el recorrido por la interfaz (listado de plugins,
escenarios, los cuatro modos de ejecución, lectura de resultados y ver código)— está en
**[`docs/manual.html`](docs/manual.html)**. Ábrelo en el navegador: es autocontenido (mockups de
la interfaz incluidos), no requiere servidor.

## Contenido

- `bin/init-project.sh` — genera `.fs-test-env.env` y renderiza el vhost apache y el servicio
  compose desde `templates/`.
- `bin/test-env-provision.sh` — provisión no interactiva: clona/actualiza el core, `composer
  install`, crea la BD de pruebas, enlaza los plugins, construye el esquema (warm-up) y deja el
  entorno con todos los plugins **desactivados**. Genera dentro del core de pruebas
  `warmup-schema.php`, `phpunit-webrunner.xml` y un `Test/install-plugins.php` que **sincroniza**
  al conjunto exacto de `Test/Plugins/install-plugins.txt` (activa/desactiva) — así funcionan los
  tests de *ausencia* de un plugin.
- `bin/setup-test-env.sh` — front interactivo para el host (deps, prompts) que delega en la provisión.
- `bin/up.sh` — levanta el contenedor del entorno de test de forma **idempotente**: si ya está
  corriendo no hace nada; si está parado o no existe, lo levanta con el compose del proyecto
  (`<engine>-compose up -d <servicio>`), y el arranque provisiona/actualiza el entorno.
  No interactivo (pensado para un botón, p.ej. la sección Scripts de OkoGit).
- `bin/plugin-topo-order.php` — ordena plugins por sus dependencias `require`.
- `web/` — runner web (PHP plano + JS): lista los plugins con tests, muestra la **descripción
  markdown** (`@description`) de cada test y ejecuta las suites mostrando los resultados.
- `templates/` — plantillas del vhost apache y del servicio compose, con placeholders `@@VAR@@`.
- `config.env.example` — todas las variables del despliegue, documentadas.

## Cómo montarlo en un proyecto FacturaScripts

```bash
# 1) añadir como submódulo
git submodule add git@github.com:Asermar/fs-test-env.git test-bin

# 2) generar la configuración del despliegue (interactivo)
test-bin/bin/init-project.sh
#    -> crea .fs-test-env.env  y  .fs-test-env/{test.conf,service.yaml}

# 3) integrar en tu compose el servicio de .fs-test-env/service.yaml y levantarlo
#    podman-compose up -d <servicio>     # si CONTAINER_ENGINE=podman
#    docker compose up -d <servicio>     # si CONTAINER_ENGINE=docker
#    (monta .fs-test-env/test.conf como sitio apache del contenedor)

# 4) provisionar el entorno
test-bin/bin/setup-test-env.sh          # en el host (interactivo)
#    o dejar que el contenedor lo haga al arrancar (TESTENV_AUTO_PROVISION=1)
```

### Podman o Docker

`init-project.sh` pregunta el motor (`CONTAINER_ENGINE`, def. `podman`) y renderiza el
servicio desde la plantilla correspondiente:

- **podman**: incluye `userns_mode: keep-id` y el sysctl de puertos no privilegiados
  (necesarios en podman rootless para ligar el 80).
- **docker**: sin esas claves (el contenedor arranca como root y liga el 80). En Docker
  rootful, si los ficheros que el contenedor escribe en `test-env/` te dan problemas de
  permisos, ejecuta el servicio con `user: "UID:GID"` de tu usuario.

El resto del servicio (red, volúmenes, comando de provisión, labels de traefik) es idéntico.

## Levantar el entorno (contenedor)

```bash
test-bin/bin/up.sh
#  - si el contenedor ya está corriendo: no toca nada
#  - si no: <engine>-compose up -d <servicio>  (crea/arranca y auto-provisiona)
```

Localiza el compose automáticamente bajo la raíz del proyecto (según `CONTAINER_ENGINE`:
`podman/podman-compose.yaml` o `docker-compose.yaml`, entre otros). Si tu compose está en
otra ruta, define **`TESTENV_COMPOSE_FILE`** (absoluta o relativa a la raíz) en
`.fs-test-env.env` o por entorno.

## Configuración

Prioridad de lectura: **variables de entorno** → `<proyecto>/.fs-test-env.env` → **defaults**.
Variables principales (ver `config.env.example`): `FS_CORE_DIR` (layout del core: `src` o `.`),
`TESTENV_REPO_PATH` (ruta absoluta idéntica host/contenedor), `TEST_DB`, `CORE_REPO`/`CORE_BRANCH`,
`FS_LANG`/`FS_TIMEZONE`, `TEST_WEB_TITLE`, y las de contenedor/red/proxy (`TESTENV_*`).

**Versión del core (`CORE_BRANCH`)**: acepta una **rama** o un **tag** de versión. Si se deja
vacío, el provisionador usa el **tag de la versión instalada** (`v<Kernel::version()>`, p.ej.
`v2026.3`), con fallback a `master`. El provisionador interactivo (`setup-test-env.sh`) ofrece,
además de la instalada, las **5 versiones (tags) más recientes** del repo de origen.

## Ejecutar los tests

- Web: el host configurado en `TESTENV_HOST` (runner navegable).
- CLI: `cd <TESTENV_DIR> && vendor/bin/phpunit Plugins/<Plugin>/Test`.
- **API HTTP** (`web/public/index.php`, `TestRunner::run()`): pensada para lanzar un escenario de
  test sin navegador (scripts, agentes). Replica el mismo flujo que la web y que `fsmaker
  run-tests` — copia `Test/<sub>` a `Test/Plugins/`, sincroniza los plugins activos vía
  `install-plugins.php` y lanza PHPUnit con `--log-junit` — serializado con `flock` (comparte
  BD y carpeta con la web y con cualquier otra ejecución concurrente).

  ```bash
  curl -s -X POST "http://<TESTENV_HOST>/?action=run" \
      --data-urlencode "plugin=BusCanarias" \
      --data-urlencode "sub=main"
  ```

  Parámetros (todos por POST, `x-www-form-urlencoded`):
  - `plugin` — nombre del plugin (carpeta bajo `Plugins/`).
  - `sub` — escenario, o sea la subcarpeta de su `Test/` (`main`, `ships`…). Un solo escenario
    por llamada; para varios, una llamada por escenario.
  - `file` (opcional) — nombre de un `*Test.php` concreto dentro de `sub`, para ejecutar solo
    ese fichero (el resto del escenario se copia y activa igual, pero no se ejecuta).
  - `core=1` + `path=Test/Core/...` — variante para un test del **core** en vez de un plugin
    (`TestRunner::runCore()`); no copia ni activa nada.

  Devuelve JSON. En éxito (`"ok": true`):
  ```json
  {
    "ok": true, "plugin": "BusCanarias", "sub": "main", "file": "",
    "config": "phpunit-webrunner.xml", "exitCode": 0, "stdout": "...",
    "installLog": "...",
    "totals": {"tests": 11, "pass": 11, "fail": 0, "error": 0, "skip": 0,
               "warning": 0, "assertions": 113, "time": 1.68}
  }
  ```
  `exitCode` es el de PHPUnit (0 = todo verde); `totals` viene de parsear el `--log-junit`
  (`JUnitParser`), así que es fiable aunque `stdout` se trunque. En fallo de parámetros/entorno
  (`"ok": false`) trae `error` con el motivo, sin `totals`.

## Testing de mutación

La cobertura dice qué líneas se ejecutaron; **no** dice si los tests fallarían con el código mal.
Para eso está `bin/test-env-mutacion.sh`: introduce fallos de verdad —invierte una condición, cambia
un operador, quita una llamada— y cuenta cuántos caza la suite. Un fallo que ningún test detecta es
un **mutante escapado**, y cada escapado es una comprobación que creíamos tener y no tenemos.

```bash
bin/test-env-mutacion.sh OSBCae                  # todo el plugin, escenario main
bin/test-env-mutacion.sh OSBCae main Lib         # sólo Lib/
bin/test-env-mutacion.sh BusCanarias rutas Lib/Rutas
MSI_MINIMO=80 bin/test-env-mutacion.sh OSBCae main Lib   # y falla si baja de ahí
```

Requiere `composer install` en este repo una vez: **Infection vive aquí y no en el core del
test-env**, porque ese core es un clon al que la provisión hace `git pull` y `composer install`, así
que una dependencia añadida allí se perdería o daría conflicto.

Tres cosas que el script hace por ti y que son justo donde se falla a mano:

- **Sincroniza la activación del escenario antes de medir.** Sin eso el plugin no está activo, su
  código no se ejecuta y la cobertura sale a cero: Infection concluiría que no hay nada que mutar.
- **Sustituye temporalmente `phpunit.xml`** por uno acotado a `Test/Plugins`, con respaldo y
  restauración garantizada. Infection sólo sabe usar ese nombre, y el del core apunta a `Test/Core`,
  que en este entorno no pasa; sin esto se niega a arrancar.
- **Comprueba que el código fuente quedó intacto** al terminar. Los plugins entran en el core por
  symlink, así que la comprobación no es paranoia: es la diferencia entre mutar y estropear.

Va a **un solo hilo** a propósito: los tests comparten una base de datos y con varios hilos los
mutantes mueren por colisión de clave única en vez de por el fallo introducido, lo que infla la
métrica en la dirección cómoda.

## Versión del entorno

El tooling se versiona con el fichero **`VERSION`** (semver) en la raíz del repo, replicado en
un **tag** `vX.Y.Z` por release. La web lo muestra en la cabecera (`entorno vX.Y.Z`).

Para saber si los scripts instalados están al día respecto al remoto:

```bash
test-bin/bin/version.sh
#  Entorno de test instalado: v1.0.0
#  Entorno de test remoto:    v1.0.1
#  => Hay una versión más reciente (v1.0.1). Actualiza el submódulo test-bin: ...
```

Al hacer cambios en el tooling, sube el número de `VERSION` y crea el tag correspondiente.

## Convención de descripciones de test

Cada `*Test.php` puede documentar clase y métodos con un bloque `@description` (markdown) en su
docblock; si no lo tiene, se usa el propio docblock como descripción. El runner web lo renderiza.
Si la descripción de la clase empieza por un encabezado markdown (`## ...`), ese texto se usa como
**título de la tarjeta** (con el nombre del `.php` entre paréntesis).

### Ejemplo: docblock sin `@description`

Se usa **todo** el docblock como descripción (ignorando líneas de tags `@...`):

```php
/**
 * ## Alias polimórficos
 *
 * Valida el modelo base `Alias` y sus reglas:
 * - **Un solo favorito** por entidad.
 * - Alias **único** por tipo.
 */
class AliasTest extends TestCase
{
    /** Comprueba que el favorito es único por entidad. */
    public function testUnFavoritoPorEntidad(): void
    {
        // ...
    }
}
```

### Ejemplo: docblock con `@description`

Solo el texto **tras `@description`** (hasta el siguiente `@tag` o el final) es la descripción; el
resto de tags (`@author`, etc.) se ignora:

```php
/**
 * @author Alexis Serafín <alexis@okodex.com>
 *
 * @description
 * ## Importación de repostajes — CSVimport activado
 *
 * Verifica que, con `CSVimport` activado, la importación en `ListFuelKm`:
 * 1. Queda **disponible** (`csvImportAvailable()` es `true`).
 * 2. `Init::init()` registra la plantilla manual `FuelKm`.
 */
class CsvImportPresentTest extends TestCase
{
    /**
     * @description Con CSVimport activado, la importación debe estar disponible.
     */
    public function testImportEnabledWhenCsvImportEnabled(): void
    {
        // ...
    }
}
```

## Changelog

Cambios destacados por versión (la versión es la de `VERSION`, único punto de verdad). Este
changelog nace en la 2.2.1: lo anterior está en el historial de git, sin bloques por versión.

### 3.0.0 — El arnés sale del proyecto que prueba

Cambio **mayor** porque rompe a quien lo invocaba por su ruta anterior: el arnés ya no vive dentro de
cada instalación como `test-bin/`, sino aparte —en la instalación de herramientas de la casa— y
compartido por los proyectos que lo usan. Quien lo llamara como `test-bin/bin/…` tiene que apuntar a
donde esté instalado.

- **Vivía dentro del proyecto que prueba y daba por hecho que el proyecto estaba justo encima.** La
  raíz salía de subir niveles desde su propia carpeta; fuera, eso ya no lleva a ningún proyecto.
  Ahora **la dice quien invoca** (`FS_PROJECT_ROOT`) y, si no la dice, se prueba el directorio
  actual.
- **Las tres derivaciones que se rompían fallan con mensaje en vez de resolver a la carpeta
  equivocada.** `init-project.sh` deduce la raíz del **repositorio** —lo único que no se mueve al
  mudar carpetas— y se niega si eso resuelve al propio arnés; `test-env-provision.sh` se niega si la
  raíz no tiene `.fs-test-env.env`; y el runner web ya no sube tres niveles. El del runner era el
  peor de los tres: callarse ahí no daba error, daba una lista de tests **vacía**, que se lee como
  «este proyecto no tiene tests».
- **Las plantillas montan el arnés aparte y de solo lectura**, bajo su misma ruta del host. En solo
  lectura porque lo comparten varios proyectos y ninguno debe poder modificar la herramienta del
  otro; bajo su misma ruta por lo mismo que ya se monta así el proyecto: que una ruta signifique lo
  mismo dentro y fuera del contenedor.
- **Nombre.** `test-bin` sonaba a la instalación de pruebas, y la instalación de pruebas es
  `test-env`, que es otra cosa y la sigue creando el arnés dentro de cada proyecto.

### 2.2.1 — El arnés deja de callarse, y la contraseña deja de salir

- **2.2.1** — **El warm-up del esquema fallaba en silencio.** Iba envuelto en `2>/dev/null` y sin
  comprobar el resultado, así que una provisión podía dejar la base a medias y seguir como si nada:
  ni funcionaba ni lo decía. Ahora **habla siempre** y sólo es **fatal en la ronda final**
  (`--exigir`) — porque la primera ronda *puede* fallar por diseño: hay plugins cuyo post-enable
  necesita un esquema que aún no existe, y de eso van justamente las dos rondas.
- **2.2.1** — **Las activaciones de plugins dejan pasar el `stderr`.** Tres invocaciones de
  `install-plugins.php` iban a `>/dev/null 2>&1`; se conserva el `|| true`, que es de su diseño,
  pero el error se ve. Una de las tres es la de la pizarra limpia: si falla, deja el entorno con
  plugins activos que nadie pidió.
- **2.2.1** — **La contraseña de la base ya no se puede leer desde fuera.** Iba como *argumento*
  de `php -r` en la provisión y en el teardown, y un argumento es visible en la lista de procesos
  para cualquier usuario de la máquina (`/proc/<pid>/cmdline` es legible por todos). Ahora va por
  variable de entorno, que sólo lee su dueño. Y el `echo` que la volcaba en la cabecera de cada
  ejecución de tests —**que viene del core oficial de FacturaScripts**, no de aquí— se retira en el
  parche del bootstrap que este arnés ya aplicaba, de forma idempotente: el core lo restaura en
  cada actualización, así que comprobar y quitar tiene que ocurrir en cada provisión.

