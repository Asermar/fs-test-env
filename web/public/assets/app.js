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

// --- sidebar ---
function renderSidebar() {
    if (PLUGINS.length === 0) {
        sidebar.appendChild(el('div', { class: 'placeholder', text: 'Ningún plugin con tests.' }));
        return;
    }
    let firstItem = null, firstPlugin = null;
    for (const p of PLUGINS) {
        const head = el('div', { class: 'plugin-head' }, [
            el('span', { text: p.plugin }),
            el('span', { class: 'badge', text: String(p.total) })
        ]);
        const item = el('div', { class: 'plugin-item' }, [head]);
        head.addEventListener('click', () => selectPlugin(p, item));
        sidebar.appendChild(item);
        if (!firstItem) { firstItem = item; firstPlugin = p; }
    }
    // seleccionamos el primer plugin para que los tests se vean al entrar
    if (firstItem) selectPlugin(firstPlugin, firstItem);
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
        el('h2', { text: p.plugin }),
        runAllBtn
    ]));

    const results = el('div', { id: 'results' });

    for (const s of p.subs) {
        const block = el('div', { class: 'sub-block' });
        block.appendChild(el('div', { class: 'sub-name', text: s.sub + (s.deps ? ' · deps: ' + s.deps.replace(/\s+/g, ', ') : '') }));
        for (const f of s.files) {
            const runBtn = el('button', { class: 'run', text: '▶ Ejecutar' });
            runBtn.addEventListener('click', () => runTests(p.plugin, s.sub, runBtn, results));
            const srcBtn = el('button', { class: 'ghost', text: '</> Ver código' });
            srcBtn.addEventListener('click', () => viewSource(p.plugin, s.sub, f));

            const card = el('div', { class: 'test-card' }, [
                el('div', { class: 'test-info' }, [
                    el('span', { class: 'test-icon', text: '🧪' }),
                    el('span', { class: 'test-file', text: f })
                ]),
                el('div', { class: 'test-actions' }, [srcBtn, runBtn])
            ]);
            block.appendChild(card);
        }
        content.appendChild(block);
    }

    runAllBtn.addEventListener('click', () => {
        // ejecuta cada subcarpeta (normalmente solo "main")
        runAllBtn.disabled = true;
        const subs = p.subs.map(s => s.sub);
        (async () => {
            results.innerHTML = '';
            for (const sub of subs) {
                await runTests(p.plugin, sub, null, results, true);
            }
            runAllBtn.disabled = false;
        })();
    });

    content.appendChild(results);
}

// --- view source ---
async function viewSource(plugin, sub, file) {
    const results = document.getElementById('results');
    results.innerHTML = '';
    const box = el('div');
    box.appendChild(el('div', { class: 'suite-title', text: `${plugin}/Test/${sub}/${file}` }));
    const pre = el('pre');
    const code = el('code', { class: 'language-php' });
    pre.appendChild(code);
    box.appendChild(pre);
    results.appendChild(box);

    try {
        const url = `?action=source&plugin=${encodeURIComponent(plugin)}&sub=${encodeURIComponent(sub)}&file=${encodeURIComponent(file)}`;
        const res = await fetch(url);
        const data = await res.json();
        if (!data.ok) throw new Error(data.error || 'Error');
        code.textContent = data.source;
        if (window.hljs) hljs.highlightElement(code);
    } catch (e) {
        results.innerHTML = '';
        results.appendChild(el('div', { class: 'error-box', text: 'No se pudo cargar el código: ' + e.message }));
    }
}

// --- run ---
async function runTests(plugin, sub, btn, results, append = false) {
    if (btn) btn.disabled = true;
    if (!append) results.innerHTML = '';

    const loading = el('div', { class: 'suite-title' }, [
        el('span', { class: 'spinner' }),
        ' Ejecutando ' + plugin + '/' + sub + ' …'
    ]);
    results.appendChild(loading);

    try {
        const body = new URLSearchParams({ plugin, sub });
        const res = await fetch('?action=run', { method: 'POST', body });
        const data = await res.json();
        loading.remove();
        if (!data.ok) throw new Error(data.error || 'Error de ejecución');
        renderResult(data, results);
    } catch (e) {
        loading.remove();
        results.appendChild(el('div', { class: 'error-box', text: 'Error: ' + e.message }));
    } finally {
        if (btn) btn.disabled = false;
    }
}

function renderResult(data, results) {
    const t = data.totals || {};
    const summary = el('div', { class: 'summary' }, [
        el('span', { class: 'chip', text: `${data.sub} · ${t.tests || 0} tests` }),
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
