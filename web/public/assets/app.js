'use strict';

const PLUGINS = window.__PLUGINS__ || [];
const sidebar = document.getElementById('sidebar');
const content = document.getElementById('content');

// orden de plugins en el lateral (líder seguido de sus hijos) y miembros por grupo
// (nombreLíder -> [líder, ...hijos]). Se rellenan en renderSidebar. Si OkoGit no está
// presente, ORDERED conserva el orden original y GROUP_MEMBERS queda vacío.
let ORDERED = [];
const GROUP_MEMBERS = {};

// Ordena los plugins agrupando cada líder con sus hijos. Core(s) primero; luego cada líder
// (en orden original) seguido de sus hijos; al final, independientes y huérfanos.
function orderPlugins(list) {
    const core = list.filter(p => p.isCore);
    const rest = list.filter(p => !p.isCore);
    const out = [];
    const done = new Set();
    for (const leader of rest.filter(p => p.isLeader)) {
        out.push(leader);
        done.add(leader);
        const kids = rest.filter(p => !p.isLeader && p.group === leader.plugin);
        GROUP_MEMBERS[leader.plugin] = [leader, ...kids];
        for (const k of kids) { out.push(k); done.add(k); }
    }
    for (const p of rest) {
        if (!done.has(p)) out.push(p);
    }
    return core.concat(out);
}

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

    ORDERED = orderPlugins(PLUGINS);

    // --- barra de herramientas: selección múltiple + ejecución en lote ---
    const selCount = el('span', { class: 'sel-count' });
    const allBtn = el('button', { class: 'ghost', text: 'Todos' });
    const noneBtn = el('button', { class: 'ghost', text: 'Ninguno' });
    const clearAllBtn = el('button', { class: 'ghost', text: '🧹 Limpiar', title: 'Borra los contadores de resultados de todos los plugins' });
    const runSelBtn = el('button', { class: 'run', title: 'Ejecuta, fichero a fichero, los tests de todos los plugins marcados' });
    const status = el('div', { class: 'batch-status' });
    const tools = el('div', { class: 'sidebar-tools' }, [
        el('div', { class: 'tools-row' }, [allBtn, noneBtn, clearAllBtn, selCount]),
        runSelBtn,
        status
    ]);
    sidebar.appendChild(tools);
    clearAllBtn.addEventListener('click', () => { clearAll(); status.textContent = ''; });

    const updateSelCount = () => {
        const n = ORDERED.filter(p => p._cb && p._cb.checked).length;
        selCount.textContent = n + ' sel.';
        runSelBtn.textContent = '▶ Ejecutar seleccionados' + (n ? ' (' + n + ')' : '');
        runSelBtn.disabled = n === 0;
    };
    const setAll = (checked) => {
        for (const p of ORDERED) if (p._cb) p._cb.checked = checked;
        updateSelCount();
    };
    allBtn.addEventListener('click', () => setAll(true));
    noneBtn.addEventListener('click', () => setAll(false));

    let firstItem = null, firstPlugin = null;
    for (const p of ORDERED) {
        const badge = el('span', { class: 'badge' });
        p._badge = badge;               // referencia para actualizar el contador al ejecutar
        p._runTotals = {};              // clave de unidad ejecutada -> {pass, fail}
        updatePluginBadge(p);           // pinta el nº de tests existentes

        const cb = el('input', { type: 'checkbox', class: 'plugin-cb', title: 'Marcar para ejecución en lote' });
        cb.addEventListener('change', updateSelCount);
        p._cb = cb;

        // marcador: ⚙ core · ★ líder · ↳ hijo · (nada) independiente
        let mark = null;
        if (p.isCore) mark = el('span', { class: 'core-mark', text: '⚙ ' });
        else if (p.isLeader) mark = el('span', { class: 'group-mark leader', text: '★ ' });
        else if (p.group) mark = el('span', { class: 'group-mark child', text: '↳ ' });

        const nameSpan = el('span', { class: 'plugin-name' }, [
            mark,
            p.plugin,
            p.version ? el('span', { class: 'plugin-ver', text: ' (' + p.version + ')' }) : null
        ]);

        const headChildren = [cb, nameSpan];
        // botón "+ hijos" solo en líderes con hijos: marca/desmarca todo el grupo.
        if (p.isLeader && (GROUP_MEMBERS[p.plugin] || []).length > 1) {
            const groupBtn = el('button', { class: 'ghost group-btn', text: '+ hijos', title: 'Marcar/desmarcar el líder y sus plugins hijos' });
            groupBtn.addEventListener('click', () => {
                const members = GROUP_MEMBERS[p.plugin] || [];
                const allChecked = members.every(m => m._cb && m._cb.checked);
                for (const m of members) if (m._cb) m._cb.checked = !allChecked;
                updateSelCount();
            });
            headChildren.push(groupBtn);
        }
        headChildren.push(badge);

        const head = el('div', { class: 'plugin-head' }, headChildren);
        const item = el('div', {
            class: 'plugin-item' + (p.isCore ? ' is-core' : '') + (p.group && !p.isLeader ? ' is-child' : '')
        }, [head]);
        // pinchar en la fila selecciona el plugin, salvo si el click viene del checkbox o de un botón.
        head.addEventListener('click', (e) => {
            if (e.target.closest('.plugin-cb, button')) return;
            selectPlugin(p, item);
        });
        p._item = item;
        sidebar.appendChild(item);
        if (!firstItem) { firstItem = item; firstPlugin = p; }
    }

    updateSelCount();
    runSelBtn.addEventListener('click', () => runSelected(runSelBtn, status));

    // seleccionamos el primer plugin para que los tests se vean al entrar
    if (firstItem) selectPlugin(firstPlugin, firstItem);
}

// Ejecuta en lote, fichero a fichero, los tests de todos los plugins marcados. Abre cada
// plugin en el panel derecho al ejecutarlo (progreso en vivo) y deja el resumen ✓/✗ en el
// badge del lateral de cada uno (persiste al cambiar de vista).
async function runSelected(btn, status) {
    const marked = ORDERED.filter(p => p._cb && p._cb.checked);
    if (!marked.length) return;
    btn.disabled = true;
    busyInc();
    try {
        let i = 0;
        for (const p of marked) {
            status.textContent = `Ejecutando ${++i}/${marked.length}: ${p.plugin}`;
            selectPlugin(p, p._item);      // renderiza la vista y fija p._runAll
            if (p._runAll) await p._runAll();
        }
        const n = marked.length;
        status.textContent = `Hecho: ${n} plugin${n > 1 ? 's' : ''} ejecutado${n > 1 ? 's' : ''}`;
    } finally {
        busyDec();
        btn.disabled = false;
    }
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
            const failBadge = el('span', { class: 'badge-fail', text: '✗' + fail + '/' + total, title: 'Ver los tests fallidos' });
            failBadge.addEventListener('click', (e) => { e.stopPropagation(); revealFailures(p); });
            badge.appendChild(failBadge);
        }
    }
}

function selectPlugin(p, item) {
    document.querySelectorAll('.plugin-item.active').forEach(n => n.classList.remove('active'));
    item.classList.add('active');
    // la vista se construye una vez y se cachea: así los resultados de cada fichero/carpeta
    // sobreviven al cambiar de plugin (hasta la siguiente ejecución o hasta limpiar).
    if (!p._view) p._view = renderPluginView(p);
    content.innerHTML = '';
    content.appendChild(p._view);
}

// Selecciona el plugin y abre/expande sus tests fallidos (para llegar a ellos desde el
// contador ✗ del lateral). Aprovecha que la vista está cacheada y conserva los resultados.
function revealFailures(p) {
    selectPlugin(p, p._item);
    const view = p._view;
    if (!view) return;
    const failed = view.querySelectorAll('.case.fail, .case.error');
    let first = null;
    failed.forEach(c => {
        const block = c.closest('.sub-block');
        if (block) {
            const body = block.querySelector('.sub-body');
            if (body) body.classList.remove('collapsed');
            const caret = block.querySelector('.folder-caret');
            if (caret) caret.textContent = '▾';
        }
        const card = c.closest('.test-card');
        if (card) card.classList.remove('collapsed');
        const det = c.closest('details.result-slot');
        if (det) { det.hidden = false; det.open = true; }
        if (c.classList.contains('has-detail')) c.classList.add('open');
        if (!first) first = c;
    });
    if (first) first.scrollIntoView({ behavior: 'smooth', block: 'center' });
}

// Limpia los contadores/resultados de todos los plugins (los del lateral y los de cada vista
// ya construida). Los que nunca se abrieron solo necesitan resetear su contador.
function clearAll() {
    for (const p of ORDERED) {
        if (p._clear) p._clear();
        else { p._runTotals = {}; updatePluginBadge(p); }
    }
}

// --- main content: plugin view ---
function renderPluginView(p) {
    const view = el('div', { class: 'plugin-view' });

    const runAllBtn = el('button', { class: 'run danger', text: '▶ Ejecutar todos', title: 'Se ejecutan todos los test del Core/Plugin. Puede tardar mucho tiempo' });
    const clearBtn = el('button', { class: 'ghost', text: '🧹 Limpiar' });
    view.appendChild(el('div', { class: 'content-head' }, [
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
        const fileByFileBtn = el('button', { class: 'run', text: '▶ Fichero a fichero', title: 'Ejecutar los tests de la carpeta archivo a archivo. Actualización más frecuente' });
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
        view.appendChild(block);
    }

    // Limpia: oculta y vacía todos los paneles de resultados y reinicia el contador.
    const clearView = () => {
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
    };
    p._clear = clearView;

    // ejecuta en secuencia todos los runners del plugin (fichero a fichero en plugins, por
    // carpeta en el core). Limpia primero (juego de tests nuevo). Se expone en el objeto
    // plugin para la ejecución en lote.
    const runAll = async () => {
        clearView();
        for (const run of runners) {
            await run();
        }
    };
    p._runAll = runAll;
    runAllBtn.addEventListener('click', () => {
        runAllBtn.disabled = true;
        busyInc();
        (async () => {
            try {
                await runAll();
            } finally {
                busyDec();
                runAllBtn.disabled = false;
            }
        })();
    });

    clearBtn.addEventListener('click', clearView);

    return view;
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
setupSidebarResize();

// Hace redimensionable la columna izquierda arrastrando su borde derecho. El ancho se guarda
// en localStorage y se restaura entre sesiones.
function setupSidebarResize() {
    const app = document.getElementById('app');
    if (!app) return;
    const KEY = 'testrunner.sidebarW';
    const MIN = 200, MAX = 800;

    const saved = parseInt(localStorage.getItem(KEY) || '', 10);
    if (saved >= MIN && saved <= MAX) app.style.setProperty('--sidebar-w', saved + 'px');

    const resizer = el('div', { class: 'resizer', title: 'Arrastra para redimensionar la columna' });
    app.appendChild(resizer);

    let dragging = false;
    const onMove = (e) => {
        if (!dragging) return;
        const rect = app.getBoundingClientRect();
        const w = Math.max(MIN, Math.min(MAX, e.clientX - rect.left));
        app.style.setProperty('--sidebar-w', w + 'px');
    };
    const onUp = () => {
        if (!dragging) return;
        dragging = false;
        document.body.classList.remove('resizing');
        window.removeEventListener('mousemove', onMove);
        window.removeEventListener('mouseup', onUp);
        const w = parseInt(app.style.getPropertyValue('--sidebar-w'), 10);
        if (w) localStorage.setItem(KEY, String(w));
    };
    resizer.addEventListener('mousedown', (e) => {
        e.preventDefault();
        dragging = true;
        document.body.classList.add('resizing');
        window.addEventListener('mousemove', onMove);
        window.addEventListener('mouseup', onUp);
    });
}

// botón "volver arriba" del pie
const toTop = document.getElementById('toTop');
if (toTop) {
    toTop.addEventListener('click', () => window.scrollTo({ top: 0, behavior: 'smooth' }));
}
