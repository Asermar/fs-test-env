# fs-test-env

<p align="center">
  <a href="#changelog"><img alt="Versión" src="https://img.shields.io/badge/Versi%C3%B3n-3.1.0-2E7D6E?style=for-the-badge"></a>
  <img alt="FacturaScripts" src="https://img.shields.io/badge/FacturaScripts-2026%2B-0C7C59?style=for-the-badge">
  <img alt="PHPUnit" src="https://img.shields.io/badge/PHPUnit-9.6-6E9B34?style=for-the-badge">
</p>

Tooling reutilizable para montar un **entorno de pruebas de FacturaScripts** (PHPUnit) y
ejecutar los tests de los plugins, con un **runner web** navegable — sin tocar la instalación ni
la base de datos de trabajo del proyecto.

Se instala **una vez** —en la instalación de herramientas de la casa, `~/Dev/Tooling/fs-test`— y lo
comparten los proyectos que lo usan; hasta la v3.0.0 era un submódulo `test-bin/` dentro de cada uno.
No contiene ningún valor específico de un proyecto: la configuración del despliegue se genera con
`init-project.sh` en un fichero `.fs-test-env.env` del proyecto, a partir del registro de
instalaciones (`config/instalaciones.conf`).

> En los ejemplos de este README, **`$FS_TEST` es donde está instalado el arnés** — en la flota,
> `~/Dev/Tooling/fs-test`. Se apunta ahí; no se copia dentro del proyecto.

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
  tests de *ausencia* de un plugin. Con **`--recrear-bd`** tira la BD antes de crearla (ver
  [Refrescar la BD de pruebas](#refrescar-la-bd-de-pruebas)).
- `bin/test-env-teardown.sh` — el inverso: borra el directorio del entorno **y la BD de pruebas**.
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
# 1) generar la configuración del despliegue
$FS_TEST/bin/init-project.sh
#    -> crea .fs-test-env.env  y  .fs-test-env/{test.conf,service.yaml}
#    (una copia de trabajo hereda la configuración de producto de su ancla en el registro;
#     un proyecto nuevo pregunta lo que no se puede inferir y se da de alta)

# 2) integrar en tu compose el servicio de .fs-test-env/service.yaml y levantarlo
#    podman-compose up -d <servicio>     # si CONTAINER_ENGINE=podman
#    docker compose up -d <servicio>     # si CONTAINER_ENGINE=docker
#    (monta .fs-test-env/test.conf como sitio apache, y el arnés en solo lectura)

# 3) provisionar el entorno
$FS_TEST/bin/setup-test-env.sh          # en el host (interactivo)
#    o dejar que el contenedor lo haga al arrancar (TESTENV_AUTO_PROVISION=1)
```

> El entorno de test vive en una **copia de trabajo**, no en el checkout principal: el provisionador
> se niega ahí (con escape `--en-el-principal`, que avisa). Lo normal es no invocarlo a mano —
> `okoworktree add <nombre> --db-mode fresh` crea la copia, su stack y su entorno de test.

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
$FS_TEST/bin/up.sh
#  - si el contenedor ya está corriendo: no toca nada
#  - si no: <engine>-compose up -d <servicio>  (crea/arranca y auto-provisiona)
```

Localiza el compose automáticamente bajo la raíz del proyecto (según `CONTAINER_ENGINE`:
`podman/podman-compose.yaml` o `docker-compose.yaml`, entre otros). Si tu compose está en
otra ruta, define **`TESTENV_COMPOSE_FILE`** (absoluta o relativa a la raíz) en
`.fs-test-env.env` o por entorno.

## Configuración

Prioridad de lectura: `<proyecto>/.fs-test-env.env` → **variables de entorno** → **defaults**.

**Y el orden importa más de lo que parece: el fichero PISA el entorno.** Los scripts lo sourcean
*después* de leer las variables y sus asignaciones son incondicionales (`TEST_DB="…"`, no
`TEST_DB="${TEST_DB:-…}"`), así que `TEST_DB=otra bin/test-env-provision.sh` **no cambia la base** si
el fichero la declara — el provisionador imprime en su cabecera la que usa de verdad, y ahí se ve.
Para cambiar un valor que el fichero fija, se edita el fichero. Las variables de entorno sólo ganan
sobre lo que el fichero **no** declara.
Variables principales (ver `config.env.example`): `FS_CORE_DIR` (layout del core: `src` o `.`),
`TESTENV_REPO_PATH` (ruta absoluta idéntica host/contenedor), `TEST_DB`, `CORE_REPO`/`CORE_BRANCH`,
`FS_LANG`/`FS_TIMEZONE`, `TEST_WEB_TITLE`, y las de contenedor/red/proxy (`TESTENV_*`).

**Versión del core (`CORE_BRANCH`)**: acepta una **rama** o un **tag** de versión. Si se deja
vacío, el provisionador usa el **tag de la versión instalada** (`v<Kernel::version()>`, p.ej.
`v2026.3`), con fallback a `master`. El provisionador interactivo (`setup-test-env.sh`) ofrece,
además de la instalada, las **5 versiones (tags) más recientes** del repo de origen.

## Refrescar la BD de pruebas

`test-env-provision.sh` es idempotente y **reusa** la BD que encuentra, así que los datos de una
corrida anterior sobreviven a todos los reaprovisionamientos. Eso es cómodo hasta que un test cuenta
filas sin filtrar: entonces el «verde» es un verde **sobre una base sucia**, y sólo se nota cuando ya
ha dado una respuesta equivocada.

```bash
$FS_TEST/bin/test-env-provision.sh --recrear-bd
```

Tira la BD de pruebas y la vuelve a crear vacía —`utf8mb4` / `utf8mb4_unicode_520_ci`, la misma
colación que una base recién creada—, **conservando el clon del core y su `vendor`**. Es el caso
frecuente: *los ficheros están bien y los datos están sucios*.

> **No es más rápido que la vía larga, y conviene saberlo antes de elegir.** Medido en Mesa/FS el
> 28-ago-2026, misma copia, una pasada de cada una: `--recrear-bd` **105,6 s**; `teardown` (0,8 s) +
> provisión completa (98,7 s) = **99,5 s**. Casi todo el coste es el **warm-up del esquema** —activar
> los plugins e instanciar los ~290 modelos, 89 s— y **las dos vías lo pagan igual**. Lo que el
> refresco se ahorra es sólo el clon del core (**6 s**) y el `composer install` (**3 s**, medido en
> frío y sin caché en la máquina), que se pierden en la variación entre pasadas.
>
> Lo que sí aporta, y es por lo que está: es **una** orden en vez de dos, así que no hay una ventana
> en la que el entorno no exista —si alguien hace el teardown y olvida provisionar, se queda sin
> entorno—, y deja la base vacía **sin tocar el árbol**, que es lo que un consumidor como el
> `db_fresh` de `okoworktree` necesita. Si el ahorro de tiempo es lo que buscas, no lo hay.

**No deja la base vacía al terminar**, y eso es lo que se quiere: sólo cambia el paso de creación, y
el resto de la provisión —config, enlaces, activación y warm-up— se ejecuta igual, así que la base
acaba **con su esquema** y con todos los plugins desactivados, indistinguible de una recién creada.

Las dos vías, y cuál es cada una:

| lo que está mal | qué hace falta | orden | medido |
|---|---|---|---|
| los **datos** están sucios | rehacer la base; los ficheros valen | `test-env-provision.sh --recrear-bd` | 105,6 s |
| el **core o el `vendor`** están mal o desfasados | rehacer los ficheros; la base también | `test-env-teardown.sh` y después `test-env-provision.sh` | 99,5 s |

Dos guardas que conviene conocer antes de usarlo:

- **Nunca puede alcanzar la BD de trabajo**: si el `TEST_DB` derivado coincide con el `FS_DB_NAME` del
  proyecto, se niega antes de escribir nada.
- **Comprueba el efecto, no que el comando volviera**: mira el retorno del `DROP` y del `CREATE`, y
  después **pregunta por consulta** que la base quedó a 0 tablas. Sin eso, un `DROP` sin permisos
  seguido de un `CREATE IF NOT EXISTS` que no hace nada imprimiría «BD lista» con la basura dentro:
  un fallo reportado como éxito.

### `--keep-db` se retiró, y pasarlo FALLA

`test-env-teardown.sh` elimina la BD de pruebas **siempre**. El flag `--keep-db`, que la conservaba,
ya no existe: el único escenario que lo justificaba —rehacer los ficheros sin rehacer la base— vale
menos que el riesgo de un verde sobre datos contaminados.

Pasarlo **no se ignora: falla** con rc 2 y sin tocar nada. Ignorarlo haría que el teardown tirase la
base justo cuando quien lo invocó pedía conservarla, en silencio, y quien lo tuviera escrito en un
guion o en un botón no se enteraría nunca de que su suposición dejó de valer.

Por el mismo motivo, **los dos scripts rechazan cualquier opción que no reconozcan** en vez de
ignorarla, que es lo que hacían antes: un `--recrear-bd` mal escrito se tragaría, la provisión
seguiría **sin refrescar** la base y saldría 0. Si ves «opción desconocida», la herramienta no está
rota — está diciendo que ese flag no significa lo que crees.

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

## Las baterías del arnés

**`test/registro.sh`** — comprueba el **registro de instalaciones**: que una copia hereda la
configuración de producto de su ancla, que una instalación nueva de verdad sigue preguntando, que una
copia sin ancla falla en vez de registrarse, y que las guardas de la base de test siguen viendo a las
copias. **22 comprobaciones, en torno a un segundo.**

**`test/provision.sh`** — comprueba las dos decisiones del provisionador: que **el entorno de test
vive en una copia, no en el checkout principal**, y que **`--recrear-bd` se acepta mientras lo
desconocido se rechaza** (incluido el caso que lo motiva: un typo `--recrear-db`, que antes se
ignoraba en silencio). **19 comprobaciones, ~0,2 s.**

**`test/teardown.sh`** — comprueba que **`--keep-db` se retiró y pasarlo falla sin borrar nada**, y
que la raíz del proyecto sale del directorio actual. Lleva su **control positivo** —la invocación sin
opciones, que sí borra—, porque «no hizo nada» se cumple también con un script que no hace nada
nunca. **15 comprobaciones.**

```bash
test/registro.sh                  # desde la raíz del arnés
test/provision.sh
test/teardown.sh
test/registro.sh /ruta/al/arnes   # o diciéndole dónde está
```

Sale **0** si todo está en verde y **1** si algo falla, así que sirve de puerta en un script.

**Son autocontenidas**: se fabrican sus instalaciones y sus repos de pega en un temporal y lo borran
al salir, así que **no tocan el registro versionado, ni el fichero de máquina, ni ningún proyecto
real**. No necesitan contenedores, ni base de datos, ni red — se pueden correr en cualquier momento,
también con el entorno apagado.

> **Este repo no tiene CI, ni Makefile, ni hook que la ejecute**, y `okorelease` tampoco la exige. O
> sea que la única forma de que se ejecute es que alguien la invoque: pásalas **antes de cerrar una
> rama** que toque `bin/init-project.sh`, `bin/lib/registro.sh`, `bin/test-env-provision.sh` o
> `bin/test-env-teardown.sh`.

> **`registro.sh` y `provision.sh` nacieron después del código que comprueban**, así que su valor es
> de **regresión**: atrapan lo que se rompa de aquí en adelante, no acreditan que lo ya escrito se
> hiciera con ellas delante. Está dicho también en su propia cabecera, que es donde lo leerá quien la
> abra. **`teardown.sh` es la primera que nació con su cambio**, en la misma rama que retira
> `--keep-db`.

> **Y lo que NO cubren, porque no cabe sin una base de datos**: que el `DROP` de `--recrear-bd`
> ocurra de verdad y que el teardown borre la BD. Las baterías comprueban el *parseo* y el
> *rechazo*; el refresco se verifica contra un entorno real, en una copia de trabajo. «Todas en
> verde» aquí no acredita el refresco.

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
$FS_TEST/bin/version.sh
#  Entorno de test instalado: v1.0.0
#  Entorno de test remoto:    v1.0.1
#  => Hay una versión más reciente (v1.0.1). Actualiza el arnés: ...
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

### 3.1.0 — La configuración del entorno de test sale del repo del cliente

- **El `.fs-test-env.env` y sus dos piezas renderizadas dejan de estar versionados en el repo de cada
  cliente.** Guardaban rutas absolutas de la máquina y el nombre de la base **dentro** del repo del
  cliente, así que una copia de trabajo nacía sucia solo por existir y podía apuntar al entorno de
  test del original — lo que ya causó una contaminación real. Ahora los **genera** `init-project.sh`
  desde el registro, y antes de desversionarlos se comprobó que salen **byte a byte idénticos**.
- **Un registro de instalaciones, `config/instalaciones.conf`, indexado por INSTALACIÓN y no por
  máquina** — porque un worktree es una instalación más. Guarda solo configuración de producto: lo
  que es de la máquina no viaja a ningún repo, y lo derivable se deriva en vez de guardarse.
- **Una copia hereda de su ancla la configuración de producto**, así que `okoworktree add` —que es no
  interactivo por diseño— ya no se queda pidiendo nueve valores por teclado. El corte del id va por
  el **primer** `-wt-`, que acierta también en una copia de una copia sin necesidad de recursión.
- **Una copia sin ancla falla y pide crearla**, en vez de darse de alta ella misma: si lo hiciera, la
  entrada quedaría con el nombre de la copia y ninguna copia siguiente encontraría a su padre.
- **El provisionador se niega en el checkout principal.** El entorno de test vive en la copia, y la
  existencia de la copia es su declaración de propiedad. La señal es de git —`--absolute-git-dir`
  frente a `--git-common-dir`—, no el nombre de la carpeta: un worktree hecho a mano sin la
  convención es legítimo, y una carpeta llamada `…-wt-…` que es un repo normal no lo es. Con escape
  explícito, `--en-el-principal`, que avisa por stderr cada vez que se usa.
- **Los dos primeros tests que este repo ha tenido**: `test/registro.sh` (22 comprobaciones, ~1 s) y
  `test/provision.sh` (12, ~0,15 s). Autocontenidos: se fabrican sus instalaciones de pega en un
  temporal, no necesitan contenedor ni base ni red, y no tocan el registro ni ningún proyecto real.
- **Arreglo**: un compose **sin router de traefik** mataba al generador con `unbound variable` al
  escribir `TEST_WEB_URL`. Ahora los derivados que no se pueden calcular quedan **vacíos**, que es lo
  que significan. Le habría pasado de lleno a una instalación local o con docker.

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

