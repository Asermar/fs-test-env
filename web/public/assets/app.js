'use strict';

const PLUGINS = window.__PLUGINS__ || [];
const sidebar = document.getElementById('sidebar');
const content = document.getElementById('content');

// --- indicador global de "trabajando" (barra superior + aviso en la cabecera) ---
let busyCount = 0;
function busyInc() {
    busyCount++;
    document.body.classList.add('busy');
}
function busyDec() {
    busyCount = Math.max(0, busyCount - 1);
    if (busyCount === 0) document.body.classList.remove('busy');
}

// --- helpers ---
function el(tag, attrs = {}, children = []) {
    const node = document.createElement(tag);
    for (const [k, v] of Object.entries(attrs)) {
        if (k === 'class') node.className = v;
        else if (k === 'text') node.textContent = v;
        else if (k.startsWith('on') && typeof v === 'function') node.addEventListener(k.slice(2), v);
        else node.setAttribute(k, v);
    }
    for (const c of [].concat(children)) {
        if (c) node.appendChild(typeof c === 'string' ? document.createTextNode(c) : c);
    }
    return node;
}

function fmtTime(s) {
    const ms = s * 1000;
    return ms < 1000 ? ms.toFixed(0) + ' ms' : s.toFixed(2) + ' s';
}

// Bloque con HTML de markdown ya renderizado en servidor (Parsedown, modo seguro).
function mdBox(cls, htmlStr) {
    const node = document.createElement('div');
    node.className = cls;
    node.innerHTML = htmlStr;
    return node;
}

// Índice claseTest -> { método -> {name,title,desc} } para cruzar los resultados de
// PHPUnit con las descripciones extraídas de cada fichero de test.
function buildMethodDesc(plugins) {
    const map = {};
    for (const p of plugins) {
        for (const s of (p.subs || [])) {
            for (const f of (s.files || [])) {
                const cls = f.name.replace(/\.php$/, '');
                const methods = {};
                for (const m of (f.methods || [])) methods[m.name] = m;
                map[cls] = methods;
            }
        }
    }
    return map;
}
const METHOD_DESC = buildMethodDesc(PLUGINS);

// --- sidebar ---
function renderSidebar() {
    if (PLUGINS.length === 0) {
        sidebar.appendChild(el('div', { class: 'placeholder', text: 'Ningún plugin con tests.' }));
        return;
    }
    let firstItem = null, firstPlugin = null;
    for (const p of PLUGINS) {
        const badge = el('span', { class: 'badge' });
        p._badge = badge;               // referencia para actualizar el contador al ejecutar
        p._runTotals = {};              // clave de unidad ejecutada -> {pass, fail}
        updatePluginBadge(p);           // pinta el nº de tests existentes
        const head = el('div', { class: 'plugin-head' }, [
            el('span', {}, [
                p.isCore ? el('span', { class: 'core-mark', text: '⚙ ' }) : null,
                p.plugin,
                p.version ? el('span', { class: 'plugin-ver', text: ' (' + p.version + ')' }) : null
            ]),
            badge
        ]);
        const item = el('div', { class: 'plugin-item' + (p.isCore ? ' is-core' : '') }, [head]);
        head.addEventListener('click', () => selectPlugin(p, item));
        sidebar.appendChild(item);
        if (!firstItem) { firstItem = item; firstPlugin = p; }
    }
    // seleccionamos el primer plugin para que los tests se vean al entrar
    if (firstItem) selectPlugin(firstPlugin, firstItem);
}

// Pinta el badge del lateral: nº de ficheros de test y, si ya se han ejecutado,
// el acumulado de casos pasados (✓) y fallados (✗) de las unidades ejecutadas.
function updatePluginBadge(p) {
    const badge = p._badge;
    if (!badge) return;
    const total = p.tests != null ? p.tests : p.total; // nº de tests (métodos), no de ficheros
    const totals = p._runTotals || {};
    let pass = 0, fail = 0, any = false;
    for (const k in totals) { any = true; pass += totals[k].pass; fail += totals[k].fail; }
    badge.innerHTML = '';
    badge.appendChild(el('span', { class: 'badge-total', text: String(total) }));
    if (any) {
        badge.appendChild(el('span', { class: 'badge-pass', text: '✓' + pass + '/' + total }));
        if (fail > 0) {
            badge.appendChild(el('span', { class: 'badge-fail', text: '✗' + fail + '/' + total }));
        }
    }
}

function selectPlugin(p, item) {
    document.querySelectorAll('.plugin-item.active').forEach(n => n.classList.remove('active'));
    item.classList.add('active');
    renderPluginView(p);
}

// --- main content: plugin view ---
function renderPluginView(p) {
    content.innerHTML = '';

    const runAllBtn = el('button', { class: 'run danger', text: '▶ Ejecutar todos', title: 'Se ejecutan todos los test del Core/Plugin. Puede tardar mucho tiempo' });
    const clearBtn = el('button', { class: 'ghost', text: '🧹 Limpiar' });
    content.appendChild(el('div', { class: 'content-head' }, [
        el('h2', {}, [
            p.isCore ? el('span', { class: 'core-mark', text: '⚙ ' }) : null,
            p.plugin,
            p.version ? el('span', { class: 'plugin-ver', text: ' (' + p.version + ')' }) : null
        ]),
        el('div', { class: 'head-actions' }, [clearBtn, runAllBtn])
    ]));

    // closures que "Ejecutar todos" lanza en secuencia.
    const runners = [];
    // todos los paneles de resultados del view, para poder limpiarlos de golpe.
    const slots = [];

    // registro de resultados por unidad ejecutada, para el contador del lateral.
    // - fichero de plugin  -> clave "sub/fichero"
    // - fichero de core    -> clave = su path (Test/Core/.../XTest.php)
    // - carpeta de core    -> clave = "Test/<sub>"
    // Para no contar doble en el core, ejecutar una carpeta olvida los ficheros
    // de esa carpeta y ejecutar un fichero olvida el registro de su carpeta.
    const record = (key, data) => {
        if (!data) return;
        const t = data.totals || {};
        p._runTotals[key] = { pass: t.pass || 0, fail: (t.fail || 0) + (t.error || 0) };
        updatePluginBadge(p);
    };
    const forget = (pred) => {
        for (const k of Object.keys(p._runTotals)) {
            if (pred(k)) delete p._runTotals[k];
        }
    };

    for (const s of p.subs) {
        const block = el('div', { class: 'sub-block' });
        const cards = [];                 // tarjetas de esta carpeta (para colapsar/expandir)
        const subRunners = [];            // runners por fichero de esta carpeta (plugins)
        const folderTests = s.files.reduce((a, f) => a + (f.tests || 0), 0);

        // cuerpo de la carpeta (tarjetas + panel de carpeta), que el caret muestra u oculta.
        const subBody = el('div', { class: 'sub-body' });
        const folder = {
            expand() {
                subBody.classList.remove('collapsed');
                folderCaret.textContent = '▾';
            }
        };

        // caret "expandir/colapsar carpeta", delante del nombre: oculta o muestra las tarjetas.
        const folderCaret = el('span', { class: 'folder-caret', text: '▾' });
        const folderToggle = el('button', { class: 'ghost folder-toggle', title: 'Expandir/colapsar carpeta' }, [folderCaret]);
        folderToggle.addEventListener('click', () => {
            const collapsed = subBody.classList.toggle('collapsed');
            folderCaret.textContent = collapsed ? '▸' : '▾';
        });

        // botones de carpeta: agregado (naranja, una sola ejecución de PHPUnit) y
        // fichero a fichero (verde, ejecuta cada tarjeta en secuencia con feedback incremental).
        const folderBtn = el('button', { class: 'run folder', text: `▶ Ejecutar Tests en Carpeta (${folderTests})`, title: 'Ejecutar los tests de esta carpeta. Puede tardar mucho tiempo' });
        const fileByFileBtn = el('button', { class: 'run', text: '▶ Fichero a fichero', title: 'Ejecutar los test por archivo, actualización más frecuente' });
        const toggleBtn = el('button', { class: 'ghost', text: '⊕ Expandir Tests' });
        const subActions = el('div', { class: 'sub-actions' }, [toggleBtn, folderBtn, fileByFileBtn]);
        const subHead = el('div', { class: 'sub-name' }, [
            folderToggle,
            el('span', { text: s.sub + (s.deps ? ' · deps: ' + s.deps.replace(/\s+/g, ', ') : '') }),
            subActions
        ]);

        // ejecuta en secuencia los runners por fichero de la carpeta, con indicador global.
        const runSubRunners = async (btn) => {
            if (btn) btn.disabled = true;
            busyInc();
            try {
                for (const r of subRunners) {
                    await r();
                }
            } finally {
                busyDec();
                if (btn) btn.disabled = false;
            }
        };

        // expandir/colapsar el contenido de todas las tarjetas de la carpeta
        toggleBtn.addEventListener('click', () => {
            folder.expand(); // si la carpeta está oculta, la mostramos para ver las tarjetas
            const anyCollapsed = cards.some(c => c.classList.contains('collapsed'));
            cards.forEach(c => c.classList.toggle('collapsed', !anyCollapsed));
            toggleBtn.textContent = anyCollapsed ? '⊖ Colapsar Tests' : '⊕ Expandir Tests';
        });

        // panel de resultados agregado de la carpeta (una única ejecución de PHPUnit).
        const subSlot = makeSlot(p.isCore ? 'Test/' + s.sub : p.plugin + '/' + s.sub);
        subSlot.folder = folder;
        slots.push(subSlot);
        const folderKey = p.isCore ? 'Test/' + s.sub : s.sub;
        const runFolder = async (btn) => {
            const data = p.isCore
                ? await runCoreTests('Test/' + s.sub, btn, subSlot)
                : await runTests(p.plugin, s.sub, '', btn, subSlot);
            forget(k => k.indexOf(folderKey + '/') === 0); // olvida ficheros de esta carpeta
            record(folderKey, data);
        };
        folderBtn.addEventListener('click', () => runFolder(folderBtn));
        fileByFileBtn.addEventListener('click', () => runSubRunners(fileByFileBtn));
        // "Ejecutar todos": en el core, agregados por carpeta (rápido); en plugins,
        // fichero a fichero (los runners por fichero se registran en el bucle de tarjetas).
        if (p.isCore) runners.push(() => runFolder(null));
        block.appendChild(subHead);
        for (const f of s.files) {
            const runBtn = el('button', { class: 'run', text: '▶ Ejecutar', title: 'Ejecutar los tests de este archivo' });
            const actions = [runBtn];
            // cada tarjeta (fichero) tiene su propio panel desplegable de resultados.
            const cardSlot = makeSlot('Resumen y salida de PHPUnit');
            cardSlot.folder = folder;
            slots.push(cardSlot);
            // el resultado compacto (badge) se muestra en la cabecera, junto al nombre.
            const headerResult = cardSlot.badge;

            if (p.isCore) {
                const runFile = async (btn) => {
                    const data = await runCoreTests(f.path, btn, cardSlot);
                    forget(k => k === 'Test/' + s.sub); // olvida el registro de su carpeta
                    record(f.path, data);
                };
                runBtn.addEventListener('click', () => runFile(runBtn));
                subRunners.push(() => runFile(null)); // "Fichero a fichero"
            } else {
                // plugin: "Ejecutar" lanza SOLO este fichero -> resultado dentro de su tarjeta.
                const runFile = async (btn) => {
                    const data = await runTests(p.plugin, s.sub, f.name, btn, cardSlot);
                    forget(k => k === s.sub); // olvida el registro agregado de la carpeta
                    record(s.sub + '/' + f.name, data);
                };
                runBtn.addEventListener('click', () => runFile(runBtn));
                runners.push(() => runFile(null));      // "Ejecutar todos" (cabecera)
                subRunners.push(() => runFile(null));   // "Fichero a fichero"
                // "Ver código" se despliega en el mismo panel de la tarjeta.
                const srcBtn = el('button', { class: 'ghost', text: '</> Ver código' });
                srcBtn.addEventListener('click', () => viewSource(p.plugin, s.sub, f.name, cardSlot));
                actions.unshift(srcBtn);
            }

            // caret para plegar/desplegar la tarjeta (oculta descripción, métodos y resultado).
            const caret = el('span', { class: 'card-caret', text: '▾' });
            // título de la tarjeta: si el test tiene título, se usa con el .php entre
            // paréntesis; si no, el nombre del fichero como hasta ahora.
            const titleParts = [el('span', { class: 'test-file', text: f.title || f.name })];
            if (f.title) {
                titleParts.push(el('span', { class: 'test-filename', text: '(' + f.name + ')' }));
            }
            const nTests = f.tests != null ? f.tests : (f.methods ? f.methods.length : 0);
            titleParts.push(el('span', { class: 'test-count', text: nTests + (nTests === 1 ? ' test' : ' tests') }));
            const info = el('div', { class: 'test-info' }, [
                caret,
                el('span', { class: 'test-icon', text: '🧪' }),
                ...titleParts
            ]);
            const top = el('div', { class: 'test-card-top' }, [
                info,
                headerResult,
                el('div', { class: 'test-actions' }, actions)
            ]);

            // el panel de resumen + salida cruda va justo bajo la cabecera.
            const bodyChildren = [cardSlot.details];
            if (f.desc) bodyChildren.push(mdBox('test-desc', f.desc));
            const methodResults = {}; // nombre de método -> contenedor de su resultado
            if (f.methods && f.methods.length) {
                const list = el('div', { class: 'method-list' });
                for (const m of f.methods) {
                    const item = el('div', { class: 'method-item' }, [
                        el('div', { class: 'method-title', text: m.title, title: m.name })
                    ]);
                    if (m.desc) item.appendChild(mdBox('method-desc', m.desc));
                    const res = el('div', { class: 'method-result' }); // resultado bajo el método
                    item.appendChild(res);
                    methodResults[m.name] = res;
                    list.appendChild(item);
                }
                bodyChildren.push(list);
            }
            // si hay métodos, los resultados se reparten bajo cada uno; el panel queda de resumen.
            cardSlot.methodResults = Object.keys(methodResults).length ? methodResults : null;

            const card = el('div', { class: 'test-card collapsed' }, [
                top,
                el('div', { class: 'test-card-body' }, bodyChildren)
            ]);
            cardSlot.card = card; // para poder desplegar la tarjeta al ejecutar
            // pulsar en la zona del nombre pliega/despliega la tarjeta (los botones no).
            info.addEventListener('click', () => card.classList.toggle('collapsed'));
            cards.push(card);
        }
        appendCards(subBody, cards); // pagina si hay más de PAGE_SIZE tarjetas

        if (subSlot) {
            subBody.appendChild(subSlot.details); // resultados de "carpeta" (core), tras las tarjetas
        }
        block.appendChild(subBody);
        content.appendChild(block);
    }

    runAllBtn.addEventListener('click', () => {
        runAllBtn.disabled = true;
        busyInc();
        (async () => {
            try {
                for (const run of runners) {
                    await run();
                }
            } finally {
                busyDec();
                runAllBtn.disabled = false;
            }
        })();
    });

    // Limpiar: oculta y vacía todos los paneles de resultados y reinicia el contador.
    clearBtn.addEventListener('click', () => {
        for (const slot of slots) {
            slot.details.hidden = true;
            slot.details.open = false;
            slot.body.innerHTML = '';
            if (slot.methodResults) {
                for (const k in slot.methodResults) slot.methodResults[k].innerHTML = '';
            }
            setSlotBadge(slot, '', '');
        }
        p._runTotals = {};
        updatePluginBadge(p);
    });
}

// --- paginación de tarjetas ---
// Si hay más de PAGE_SIZE tarjetas, se muestran de PAGE_SIZE en PAGE_SIZE con un
// paginador. Las tarjetas se construyen una sola vez y se ocultan/muestran (no se
// reconstruyen), de modo que los resultados ejecutados se conservan al cambiar de página.
const PAGE_SIZE = 10;

function appendCards(block, cards) {
    if (cards.length <= PAGE_SIZE) {
        cards.forEach(c => block.appendChild(c));
        return;
    }

    const wrap = el('div', { class: 'cards-wrap' });
    cards.forEach(c => wrap.appendChild(c));
    block.appendChild(wrap);

    const pager = el('div', { class: 'pager' });
    block.appendChild(pager);

    const pages = Math.ceil(cards.length / PAGE_SIZE);
    let current = 0;

    const render = () => {
        cards.forEach((c, i) => {
            c.style.display = (Math.floor(i / PAGE_SIZE) === current) ? '' : 'none';
        });
        pager.innerHTML = '';
        const prev = el('button', { class: 'pg', text: '‹ Anterior' });
        prev.disabled = current === 0;
        prev.addEventListener('click', () => { current--; render(); });
        pager.appendChild(prev);

        for (let i = 0; i < pages; i++) {
            const b = el('button', { class: 'pg' + (i === current ? ' active' : ''), text: String(i + 1) });
            b.addEventListener('click', () => { current = i; render(); });
            pager.appendChild(b);
        }

        const next = el('button', { class: 'pg', text: 'Siguiente ›' });
        next.disabled = current === pages - 1;
        next.addEventListener('click', () => { current++; render(); });
        pager.appendChild(next);

        const from = current * PAGE_SIZE + 1;
        const to = Math.min(cards.length, (current + 1) * PAGE_SIZE);
        pager.appendChild(el('span', { class: 'pg-count', text: `${from}–${to} de ${cards.length}` }));
    };
    render();
}

// --- panel de resultados desplegable (<details>) ---
// Devuelve { details, summary, titleEl, badge, body }. Oculto hasta la primera ejecución.
function makeSlot(title) {
    const caret = el('span', { class: 'slot-caret', text: '▸' });
    const titleEl = el('span', { class: 'slot-title', text: title });
    const badge = el('span', { class: 'slot-badge' });
    const summary = el('summary', { class: 'slot-summary' }, [caret, titleEl, badge]);
    const body = el('div', { class: 'result-slot-body' });
    const details = el('details', { class: 'result-slot' }, [summary, body]);
    details.hidden = true;
    return { details, summary, titleEl, badge, body };
}

function setSlotBadge(slot, text, kind) {
    slot.badge.textContent = text;
    slot.badge.className = 'slot-badge' + (kind ? ' ' + kind : '');
}

// abre el panel, lo vacía y muestra el spinner mientras corre.
function slotStart(slot, label) {
    if (slot.folder) slot.folder.expand();                  // muestra la carpeta si estaba oculta
    if (slot.card) slot.card.classList.remove('collapsed'); // despliega la tarjeta al ejecutar
    slot.details.hidden = false;
    slot.details.open = true;
    slot.body.innerHTML = '';
    if (slot.methodResults) {
        for (const k in slot.methodResults) slot.methodResults[k].innerHTML = '';
    }
    setSlotBadge(slot, 'ejecutando…', 'running');
    slot.body.appendChild(el('div', { class: 'suite-title' }, [
        el('span', { class: 'spinner' }), ' Ejecutando ' + label + ' …'
    ]));
}

// etiqueta compacta en el summary a partir de los totales.
function slotDone(slot, data) {
    const t = data.totals || {};
    const fails = (t.fail || 0) + (t.error || 0);
    if (fails > 0) {
        setSlotBadge(slot, `${fails} fallo${fails > 1 ? 's' : ''} · ${t.pass || 0}/${t.tests || 0}`, 'fail');
    } else {
        setSlotBadge(slot, `${t.pass || 0}/${t.tests || 0} OK · ${fmtTime(t.time || 0)}`, 'ok');
    }
}

// --- view source (se despliega dentro de la tarjeta) ---
async function viewSource(plugin, sub, file, slot) {
    if (slot.card) slot.card.classList.remove('collapsed');
    slot.details.hidden = false;
    slot.details.open = true;
    slot.body.innerHTML = '';
    setSlotBadge(slot, 'código', '');
    const pre = el('pre');
    const code = el('code', { class: 'language-php' });
    pre.appendChild(code);
    slot.body.appendChild(pre);

    busyInc();
    try {
        const url = `?action=source&plugin=${encodeURIComponent(plugin)}&sub=${encodeURIComponent(sub)}&file=${encodeURIComponent(file)}`;
        const res = await fetch(url);
        const data = await res.json();
        if (!data.ok) throw new Error(data.error || 'Error');
        code.textContent = data.source;
        if (window.hljs) hljs.highlightElement(code);
    } catch (e) {
        slot.body.innerHTML = '';
        setSlotBadge(slot, 'error', 'fail');
        slot.body.appendChild(el('div', { class: 'error-box', text: 'No se pudo cargar el código: ' + e.message }));
    } finally {
        busyDec();
    }
}

// --- run (plugin: un fichero de test concreto de la carpeta) ---
async function runTests(plugin, sub, file, btn, slot) {
    if (btn) btn.disabled = true;
    busyInc();
    slotStart(slot, plugin + '/' + sub + (file ? '/' + file : ''));
    try {
        const body = new URLSearchParams({ plugin, sub, file: file || '' });
        const res = await fetch('?action=run', { method: 'POST', body });
        const data = await res.json();
        if (!data.ok) { slot.body.innerHTML = ''; throw new Error(data.error || 'Error de ejecución'); }
        showResult(slot, data);
        slotDone(slot, data);
        return data;
    } catch (e) {
        slot.body.innerHTML = '';
        setSlotBadge(slot, 'error', 'fail');
        slot.body.appendChild(el('div', { class: 'error-box', text: 'Error: ' + e.message }));
        return null;
    } finally {
        if (btn) btn.disabled = false;
        busyDec();
        if (slot.card) slot.card.classList.add('collapsed'); // se colapsa al terminar
    }
}

// ejecuta un test del CORE (fichero o carpeta bajo Test/Core); path relativo a la raíz del core.
async function runCoreTests(path, btn, slot) {
    if (btn) btn.disabled = true;
    busyInc();
    slotStart(slot, path);
    try {
        const body = new URLSearchParams({ core: '1', path });
        const res = await fetch('?action=run', { method: 'POST', body });
        const data = await res.json();
        if (!data.ok) { slot.body.innerHTML = ''; throw new Error(data.error || 'Error de ejecución'); }
        showResult(slot, data);
        slotDone(slot, data);
        return data;
    } catch (e) {
        slot.body.innerHTML = '';
        setSlotBadge(slot, 'error', 'fail');
        slot.body.appendChild(el('div', { class: 'error-box', text: 'Error: ' + e.message }));
        return null;
    } finally {
        if (btn) btn.disabled = false;
        busyDec();
        if (slot.card) slot.card.classList.add('collapsed'); // se colapsa al terminar
    }
}

// Pinta el resultado en el panel del slot. Si el slot tiene mapa de métodos
// (slot.methodResults), coloca cada caso bajo la sección de su método en la tarjeta,
// y en el panel deja solo el resumen + casos sin método + salida cruda.
function showResult(slot, data) {
    slot.body.innerHTML = '';
    if (slot.methodResults) {
        for (const k in slot.methodResults) {
            slot.methodResults[k].innerHTML = '';
        }
        const extras = [];
        for (const suite of data.suites || []) {
            for (const c of suite.cases) {
                const target = slot.methodResults[caseMethodName(c.name)] || slot.methodResults[c.name];
                if (target) {
                    target.appendChild(renderCase(c));
                } else {
                    extras.push(c);
                }
            }
        }
        slot.body.appendChild(resultSummary(data));
        if (extras.length) {
            slot.body.appendChild(el('div', { class: 'suite-title', text: 'Otros casos' }));
            extras.forEach(c => slot.body.appendChild(renderCase(c)));
        }
        slot.body.appendChild(rawOutput(data));
    } else {
        renderResult(data, slot.body);
    }
}

// nombre del método a partir del nombre del caso ("testX with data set #0 (...)" -> "testX").
function caseMethodName(name) {
    const m = /^([A-Za-z_]\w*)/.exec(name || '');
    return m ? m[1] : name;
}

function resultSummary(data) {
    const t = data.totals || {};
    const label = data.file || data.path || data.sub || '';
    return el('div', { class: 'summary' }, [
        el('span', { class: 'chip', text: `${label} · ${t.tests || 0} tests` }),
        el('span', { class: 'chip pass', text: `${t.pass || 0} OK` }),
        el('span', { class: 'chip fail', text: `${(t.fail || 0) + (t.error || 0)} fallos` }),
        el('span', { class: 'chip skip', text: `${t.skip || 0} omitidos` }),
        el('span', { class: 'chip', text: `${t.assertions || 0} aserciones` }),
        el('span', { class: 'chip', text: fmtTime(t.time || 0) })
    ]);
}

function rawOutput(data) {
    return el('details', { class: 'raw' }, [
        el('summary', { text: 'Salida cruda de PHPUnit' }),
        el('pre', {}, [el('code', { text: (data.installLog ? data.installLog + '\n\n' : '') + (data.stdout || '') })])
    ]);
}

function renderResult(data, results) {
    results.appendChild(resultSummary(data));

    if ((data.suites || []).length === 0) {
        results.appendChild(el('div', { class: 'error-box' }, [
            el('div', { text: 'PHPUnit no devolvió casos (código de salida ' + data.exitCode + ').' })
        ]));
    }

    for (const suite of data.suites || []) {
        results.appendChild(el('div', { class: 'suite-title', text: suite.name }));
        for (const c of suite.cases) {
            results.appendChild(renderCase(c));
        }
    }

    results.appendChild(rawOutput(data));
}

function renderCase(c) {
    const hasDetail = c.detail && c.detail.length > 0;
    const statusLabel = { pass: 'OK', fail: 'FALLO', error: 'ERROR', skip: 'OMIT', warning: 'AVISO' }[c.status] || c.status;

    const head = el('div', { class: 'case-head' }, [
        el('span', { class: 'case-status', text: statusLabel }),
        el('span', { class: 'case-name', text: c.name }),
        el('span', { class: 'case-meta', text: `${c.assertions} asrt · ${fmtTime(c.time)}` })
    ]);

    const children = [head];

    // descripción del método (extraída del fichero de test) bajo el nombre del caso
    const caseClass = (c.class || '').split('\\').pop();
    const meta = (METHOD_DESC[caseClass] || {})[c.name];
    if (meta && meta.desc) children.push(mdBox('case-desc', meta.desc));

    if (hasDetail) {
        const detail = el('div', { class: 'case-detail' });
        if (c.message) detail.appendChild(el('div', { class: 'msg', text: c.message }));
        detail.appendChild(el('pre', {}, [el('code', { text: c.detail })]));
        children.push(detail);
    }

    const cls = 'case ' + c.status + (hasDetail ? ' has-detail' : '');
    const node = el('div', { class: cls }, children);
    if (hasDetail) {
        head.addEventListener('click', () => node.classList.toggle('open'));
    }
    return node;
}

renderSidebar();

// botón "volver arriba" del pie
const toTop = document.getElementById('toTop');
if (toTop) {
    toTop.addEventListener('click', () => window.scrollTo({ top: 0, behavior: 'smooth' }));
}
