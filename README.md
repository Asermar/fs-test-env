# fs-test-env

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
