'use strict';

const PLUGINS = window.__PLUGINS__ || [];
const sidebar = document.getElementById('sidebar');
const content = document.getElementById('content');

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

    const runAllBtn = el('button', { class: 'primary', text: 'Ejecutar todos' });
    content.appendChild(el('div', { class: 'content-head' }, [
        el('h2', {}, [
            p.isCore ? el('span', { class: 'core-mark', text: '⚙ ' }) : null,
            p.plugin,
            p.version ? el('span', { class: 'plugin-ver', text: ' (' + p.version + ')' }) : null
        ]),
        runAllBtn
    ]));

    // closures que "Ejecutar todos" lanza en secuencia.
    const runners = [];

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
        const subHead = el('div', { class: 'sub-name' }, [
            el('span', { text: s.sub + (s.deps ? ' · deps: ' + s.deps.replace(/\s+/g, ', ') : '') })
        ]);

        // panel de resultados a nivel de carpeta: solo para el botón "carpeta" del core.
        // (En plugins cada fichero muestra su resultado dentro de su propia tarjeta.)
        let subSlot = null;
        if (p.isCore) {
            subSlot = makeSlot('Test/' + s.sub);
            const folderPath = 'Test/' + s.sub;
            const runFolder = async (btn) => {
                const data = await runCoreTests(folderPath, btn, subSlot);
                forget(k => k.indexOf(folderPath + '/') === 0); // olvida ficheros de esta carpeta
                record(folderPath, data);
            };
            const folderBtn = el('button', { class: 'ghost', text: '▶ carpeta' });
            folderBtn.addEventListener('click', () => runFolder(folderBtn));
            subHead.appendChild(folderBtn);
            runners.push(() => runFolder(null));
        }
        block.appendChild(subHead);

        const cards = [];
        for (const f of s.files) {
            const runBtn = el('button', { class: 'run', text: '▶ Ejecutar' });
            const actions = [runBtn];
            // cada tarjeta (fichero) tiene su propio panel desplegable de resultados.
            const cardSlot = makeSlot(p.isCore ? f.path : p.plugin + '/' + s.sub + '/' + f.name);

            if (p.isCore) {
                const runFile = async (btn) => {
                    const data = await runCoreTests(f.path, btn, cardSlot);
                    forget(k => k === 'Test/' + s.sub); // olvida el registro de su carpeta
                    record(f.path, data);
                };
                runBtn.addEventListener('click', () => runFile(runBtn));
            } else {
                // plugin: "Ejecutar" lanza SOLO este fichero -> resultado dentro de su tarjeta.
                const runFile = async (btn) => {
                    const data = await runTests(p.plugin, s.sub, f.name, btn, cardSlot);
                    record(s.sub + '/' + f.name, data);
                };
                runBtn.addEventListener('click', () => runFile(runBtn));
                runners.push(() => runFile(null));
                // "Ver código" se despliega en el mismo panel de la tarjeta.
                const srcBtn = el('button', { class: 'ghost', text: '</> Ver código' });
                srcBtn.addEventListener('click', () => viewSource(p.plugin, s.sub, f.name, cardSlot));
                actions.unshift(srcBtn);
            }

            const top = el('div', { class: 'test-card-top' }, [
                el('div', { class: 'test-info' }, [
                    el('span', { class: 'test-icon', text: '🧪' }),
                    el('span', { class: 'test-file', text: f.name })
                ]),
                el('div', { class: 'test-actions' }, actions)
            ]);

            const cardChildren = [top];
            if (f.desc) cardChildren.push(mdBox('test-desc', f.desc));
            if (f.methods && f.methods.length) {
                const list = el('div', { class: 'method-list' });
                for (const m of f.methods) {
                    const item = el('div', { class: 'method-item' }, [
                        el('div', { class: 'method-title', text: m.title, title: m.name })
                    ]);
                    if (m.desc) item.appendChild(mdBox('method-desc', m.desc));
                    list.appendChild(item);
                }
                cardChildren.push(list);
            }
            if (cardSlot) cardChildren.push(cardSlot.details);
            cards.push(el('div', { class: 'test-card' }, cardChildren));
        }
        appendCards(block, cards); // pagina si hay más de PAGE_SIZE tarjetas

        if (subSlot) {
            block.appendChild(subSlot.details); // resultados de "carpeta" (core), tras las tarjetas
        }
        content.appendChild(block);
    }

    runAllBtn.addEventListener('click', () => {
        runAllBtn.disabled = true;
        (async () => {
            for (const run of runners) {
                await run();
            }
            runAllBtn.disabled = false;
        })();
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
    slot.details.hidden = false;
    slot.details.open = true;
    slot.body.innerHTML = '';
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
    slot.details.hidden = false;
    slot.details.open = true;
    slot.body.innerHTML = '';
    setSlotBadge(slot, 'código', '');
    const pre = el('pre');
    const code = el('code', { class: 'language-php' });
    pre.appendChild(code);
    slot.body.appendChild(pre);

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
    }
}

// --- run (plugin: un fichero de test concreto de la carpeta) ---
async function runTests(plugin, sub, file, btn, slot) {
    if (btn) btn.disabled = true;
    slotStart(slot, plugin + '/' + sub + (file ? '/' + file : ''));
    try {
        const body = new URLSearchParams({ plugin, sub, file: file || '' });
        const res = await fetch('?action=run', { method: 'POST', body });
        const data = await res.json();
        slot.body.innerHTML = '';
        if (!data.ok) throw new Error(data.error || 'Error de ejecución');
        renderResult(data, slot.body);
        slotDone(slot, data);
        return data;
    } catch (e) {
        slot.body.innerHTML = '';
        setSlotBadge(slot, 'error', 'fail');
        slot.body.appendChild(el('div', { class: 'error-box', text: 'Error: ' + e.message }));
        return null;
    } finally {
        if (btn) btn.disabled = false;
    }
}

// ejecuta un test del CORE (fichero o carpeta bajo Test/Core); path relativo a la raíz del core.
async function runCoreTests(path, btn, slot) {
    if (btn) btn.disabled = true;
    slotStart(slot, path);
    try {
        const body = new URLSearchParams({ core: '1', path });
        const res = await fetch('?action=run', { method: 'POST', body });
        const data = await res.json();
        slot.body.innerHTML = '';
        if (!data.ok) throw new Error(data.error || 'Error de ejecución');
        renderResult(data, slot.body);
        slotDone(slot, data);
        return data;
    } catch (e) {
        slot.body.innerHTML = '';
        setSlotBadge(slot, 'error', 'fail');
        slot.body.appendChild(el('div', { class: 'error-box', text: 'Error: ' + e.message }));
        return null;
    } finally {
        if (btn) btn.disabled = false;
    }
}

function renderResult(data, results) {
    const t = data.totals || {};
    const label = data.file || data.path || data.sub || '';
    const summary = el('div', { class: 'summary' }, [
        el('span', { class: 'chip', text: `${label} · ${t.tests || 0} tests` }),
        el('span', { class: 'chip pass', text: `${t.pass || 0} OK` }),
        el('span', { class: 'chip fail', text: `${(t.fail || 0) + (t.error || 0)} fallos` }),
        el('span', { class: 'chip skip', text: `${t.skip || 0} omitidos` }),
        el('span', { class: 'chip', text: `${t.assertions || 0} aserciones` }),
        el('span', { class: 'chip', text: fmtTime(t.time || 0) })
    ]);
    results.appendChild(summary);

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

    // salida cruda colapsable
    const raw = el('details', { class: 'raw' }, [
        el('summary', { text: 'Salida cruda de PHPUnit' }),
        el('pre', {}, [el('code', { text: (data.installLog ? data.installLog + '\n\n' : '') + (data.stdout || '') })])
    ]);
    results.appendChild(raw);
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
