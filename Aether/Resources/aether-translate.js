// 网页翻译。跑在独立的 content world（aether-translate），网页自己的脚本碰不到也改不了。
// 目标是“文字只要显示出来就翻译”：
//   - 所有文本节点，包括开放的 shadow DOM 和每个 iframe（脚本注入到所有框架）
//   - placeholder / title / alt / aria-label 和按钮的 value
//   - 后加载、点开、切换出来的内容（MutationObserver + 定时补扫）
//   - 图片、canvas、CSS 背景图里的文字：原生截图识别后盖一层译文（只在主框架）
// 云端引擎（lazy）只翻译屏幕附近的内容，滚到哪翻到哪；系统翻译整页一次翻完。
(() => {
  if (window.__aetherT) return;
  const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.aetherTranslate;
  if (!handler) return;
  const isTop = window === window.top;

  const SKIP_TAGS = new Set(['SCRIPT', 'STYLE', 'NOSCRIPT', 'TEMPLATE', 'TEXTAREA', 'CODE', 'PRE', 'KBD', 'SAMP', 'VAR',
    'IFRAME', 'OBJECT', 'EMBED', 'MATH']);
  const ATTRS = ['placeholder', 'title', 'alt', 'aria-label'];
  const BUTTON_TYPES = new Set(['submit', 'button', 'reset']);
  const LETTER = /\p{L}/u;
  const MARK = 'data-aether-t';

  let state = { active: false };
  let generation = 0;
  /** Text 节点 → { orig, applied, extra } */
  const textRecords = new Map();
  /** 元素 → { 属性名: { orig, applied } } */
  const attrRecords = new Map();
  const pendingTexts = new Set();
  /** 元素 → Set(属性名) */
  const pendingAttrs = new Map();
  const observedRoots = new Set();
  let rescanTimer = null;

  // MARK: - 收集

  function rejected(el) {
    return SKIP_TAGS.has(el.tagName) || el.hasAttribute(MARK) || el.getAttribute('translate') === 'no' ||
      el.classList.contains('notranslate') || el.isContentEditable;
  }

  /** 节点所在的祖先链（穿过 shadow root）里有不翻译的元素 */
  function skipped(node) {
    for (let e = node && (node.nodeType === 1 ? node : node.parentElement); e;) {
      if (rejected(e)) return true;
      if (e.parentElement) e = e.parentElement;
      else { const root = e.getRootNode(); e = root && root.host; }
    }
    return false;
  }

  function addText(node) {
    const value = node.nodeValue;
    if (!value || !LETTER.test(value)) return;
    const record = textRecords.get(node);
    // 没变（还在翻译中，或者已经是自己改出来的值）就不算新内容；重扫时换掉记录会让译文回来后被当成新原文再翻一遍
    if (record && (value === record.applied || value === record.orig)) return;
    if (record && record.extra) record.extra.remove();
    textRecords.set(node, { orig: value, applied: null, extra: null });
    pendingTexts.add(node);
  }

  function collectAttrs(el) {
    const names = el.tagName === 'INPUT' && BUTTON_TYPES.has((el.type || '').toLowerCase()) ? [...ATTRS, 'value'] : ATTRS;
    for (const name of names) {
      const value = el.getAttribute(name);
      if (!value || !LETTER.test(value)) continue;
      const records = attrRecords.get(el) || {};
      if (records[name] && (value === records[name].applied || value === records[name].orig)) continue;
      records[name] = { orig: value, applied: null };
      attrRecords.set(el, records);
      if (!pendingAttrs.has(el)) pendingAttrs.set(el, new Set());
      pendingAttrs.get(el).add(name);
    }
  }

  function scan(root) {
    if (root.nodeType === 3) { if (!skipped(root)) addText(root); return; }
    if (root.nodeType === 1 && skipped(root)) return;
    const walker = document.createTreeWalker(root, NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT, {
      acceptNode: (n) => (n.nodeType === 1 && rejected(n) ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_ACCEPT),
    });
    for (let n = walker.currentNode; n; n = walker.nextNode()) {
      if (n.nodeType === 3) { addText(n); continue; }
      if (n.nodeType !== 1) continue;
      collectAttrs(n);
      if (n.shadowRoot) { observe(n.shadowRoot); scan(n.shadowRoot); }
    }
  }

  // MARK: - 变化

  const ours = (n) => n.nodeType === 1 && n.hasAttribute(MARK);

  const observer = new MutationObserver((mutations) => {
    if (!state.active) return;
    let changed = false;
    for (const m of mutations) {
      // 自己插入、删除的译文和图片译文框不算网页变化，否则会不停地重新识别图片
      if (m.type === 'childList' && [...m.addedNodes, ...m.removedNodes].every(ours)) continue;
      if (ours(m.target) || (m.target.parentElement && m.target.parentElement.closest(`[${MARK}]`))) continue;
      changed = true;
      if (m.type === 'childList') {
        for (const n of m.addedNodes) if (n.nodeType === 1 || n.nodeType === 3) scan(n);
      } else if (m.type === 'characterData') {
        if (!skipped(m.target)) addText(m.target);
      } else if (m.type === 'attributes' && (ATTRS.includes(m.attributeName) || m.attributeName === 'value')) {
        if (!skipped(m.target)) collectAttrs(m.target);
      }
      // class / style / hidden / open 变化：可能有原本隐藏的内容显示出来了，下面的 schedule 会重新检查
    }
    if (!changed) return;
    schedule();
    scheduleImages(600);
  });

  function observe(root) {
    if (observedRoots.has(root)) return;
    observedRoots.add(root);
    observer.observe(root, {
      childList: true, subtree: true, characterData: true, attributes: true,
      attributeFilter: [...ATTRS, 'value', 'class', 'style', 'hidden', 'open'],
    });
  }

  // MARK: - 翻译

  function nearViewport(el) {
    if (!el || !el.isConnected) return false;
    const r = el.getBoundingClientRect();
    if (r.width === 0 && r.height === 0) return false;
    const vw = innerWidth, vh = innerHeight;
    return r.bottom > -vh * 0.5 && r.top < vh * 1.8 && r.right > -vw * 0.5 && r.left < vw * 1.5;
  }

  function hostElement(node) {
    if (node.parentElement) return node.parentElement;
    const root = node.parentNode;
    return root && root.host;
  }

  let flushTimer = null;
  function schedule(delay = state.lazy ? 400 : 150) {
    if (!state.active) return;
    clearTimeout(flushTimer);
    flushTimer = setTimeout(flush, delay);
  }

  function flush() {
    if (!state.active) return;
    const items = [];
    for (const node of pendingTexts) {
      if (!node.isConnected) { pendingTexts.delete(node); textRecords.delete(node); continue; }
      if (state.lazy && !nearViewport(hostElement(node))) continue;
      pendingTexts.delete(node);
      const record = textRecords.get(node);
      const text = record && record.orig.trim();
      if (text) items.push({ node, record, text });
    }
    for (const [el, names] of pendingAttrs) {
      if (!el.isConnected) { pendingAttrs.delete(el); attrRecords.delete(el); continue; }
      if (state.lazy && !nearViewport(el)) continue;
      pendingAttrs.delete(el);
      const records = attrRecords.get(el) || {};
      for (const name of names) {
        const record = records[name];
        const text = record && record.orig.trim();
        if (text) items.push({ el, name, record, text });
      }
    }
    if (!state.lazy) { send(items, 60, 4000); return; }
    // 云端引擎按请求次数限额，一次多装些；看得见的单独一批先发，回来得快
    const visible = [], near = [];
    for (const item of items) (inViewport(item.node ? hostElement(item.node) : item.el) ? visible : near).push(item);
    send(visible, 100, 6000);
    send(near, 100, 6000);
  }

  function send(items, maxCount, maxChars) {
    let batch = [], chars = 0;
    for (const item of items) {
      batch.push(item);
      chars += item.text.length;
      if (batch.length >= maxCount || chars > maxChars) { translateBatch(batch); batch = []; chars = 0; }
    }
    if (batch.length) translateBatch(batch);
  }

  function inViewport(el) {
    if (!el || !el.isConnected) return false;
    const r = el.getBoundingClientRect();
    return r.bottom > 0 && r.top < innerHeight && r.right > 0 && r.left < innerWidth;
  }

  async function translateBatch(items) {
    const gen = generation;
    const texts = [...new Set(items.map((i) => i.text))];
    let output;
    try {
      output = await handler.postMessage({ type: 'translate', texts });
    } catch (e) {
      output = null; // 原生已经提示过错误，下面安排重试
    }
    if (gen !== generation || !state.active) return;
    const map = new Map(texts.map((t, i) => [t, Array.isArray(output) ? output[i] : null]));
    const failed = [];
    for (const item of items) {
      const translated = map.get(item.text);
      if (translated == null) { failed.push(item); continue; }
      if (translated === item.text) continue;
      if (item.node) applyText(item.node, item.record, translated);
      else if (item.el.getAttribute(item.name) === item.record.orig) {
        item.record.applied = translated;
        item.el.setAttribute(item.name, translated);
      }
    }
    if (failed.length) retry(failed, gen);
  }

  /** 没翻成的（额度、网络）过一会儿放回队列，最多试 3 次 */
  function retry(items, gen) {
    const later = items.filter((item) => (item.record.tries = (item.record.tries || 0) + 1) < 3);
    if (!later.length) return;
    setTimeout(() => {
      if (gen !== generation || !state.active) return;
      for (const item of later) {
        if (item.node) { if (textRecords.get(item.node) === item.record) pendingTexts.add(item.node); }
        else {
          if (!pendingAttrs.has(item.el)) pendingAttrs.set(item.el, new Set());
          pendingAttrs.get(item.el).add(item.name);
        }
      }
      schedule(0);
    }, later[0].record.tries * 8000);
  }

  function applyText(node, record, translated) {
    if (node.nodeValue !== record.orig || !node.isConnected) return;
    if (state.display === 'bilingual') {
      const parent = node.parentElement;
      const block = parent && parent.childElementCount === 0 && parent.tagName !== 'TITLE' &&
        !getComputedStyle(parent).display.startsWith('inline');
      const extra = document.createElement('font');
      extra.setAttribute(MARK, '');
      extra.textContent = block ? translated : ` (${translated})`;
      extra.style.cssText = block ? 'display:block;opacity:.75;font-size:.92em;margin-top:.15em' : 'opacity:.75';
      if (parent && parent.tagName === 'TITLE') { node.nodeValue = `${record.orig} (${translated})`; record.applied = node.nodeValue; return; }
      node.after(extra);
      record.extra = extra;
      return;
    }
    const lead = record.orig.match(/^\s*/)[0], trail = record.orig.match(/\s*$/)[0];
    record.applied = lead + translated + trail;
    node.nodeValue = record.applied;
  }

  // MARK: - 开关

  function start() {
    generation += 1;
    observe(document.documentElement);
    scan(document.documentElement);
    schedule(0);
    // shadow root 晚挂上、或者内容被整块替换没有触发观察时，定时补扫一遍（已记录的节点会很快跳过）
    clearInterval(rescanTimer);
    rescanTimer = setInterval(() => { scan(document.documentElement); schedule(); }, 3000);
    scheduleImages(400);
  }

  function stop() {
    generation += 1;
    clearInterval(rescanTimer);
    clearTimeout(flushTimer);
    observer.disconnect();
    observedRoots.clear();
    for (const [node, record] of textRecords) {
      if (record.extra) record.extra.remove();
      else if (record.applied && node.nodeValue === record.applied) node.nodeValue = record.orig;
    }
    for (const [el, records] of attrRecords) {
      for (const name in records) {
        const r = records[name];
        if (r.applied && el.getAttribute(name) === r.applied) el.setAttribute(name, r.orig);
      }
    }
    textRecords.clear();
    attrRecords.clear();
    pendingTexts.clear();
    pendingAttrs.clear();
    clearOverlays();
  }

  function setState(next) {
    const was = state.active;
    const changed = was && next.active &&
      (next.target !== state.target || next.display !== state.display || next.lazy !== state.lazy);
    if (was && (!next.active || changed)) stop();
    state = next;
    if (next.active && (!was || changed)) start();
    else if (next.active && !next.images) clearOverlays();
    // 转给子框架（子框架里同一个 world 的脚本收到后照做，再往下传）
    for (const frame of document.querySelectorAll('iframe, frame')) {
      try { frame.contentWindow.postMessage({ __aetherT: next }, '*'); } catch (e) {}
    }
  }

  // MARK: - 图片里的文字（主框架）

  /** 元素 → { container, key, kind, dirty } */
  const overlays = new Map();
  const processed = new Map();
  const ocrTries = new WeakMap();
  let imageTimer = null;
  let ocrRunning = false;

  function scheduleImages(delay) {
    if (!isTop || !state.active || !state.images) return;
    clearTimeout(imageTimer);
    imageTimer = setTimeout(scanImages, delay);
  }

  function imageKey(el, r) {
    const size = `${Math.round(r.width)}x${Math.round(r.height)}`;
    if (el.tagName === 'IMG') return `${el.currentSrc || el.src}|${size}`;
    if (el.tagName === 'CANVAS') return `canvas|${size}|${Math.round(r.left)}|${Math.round(r.top)}`;
    return `${getComputedStyle(el).backgroundImage}|${size}`;
  }

  /** 在画面上撒点，找出显示中的图片、canvas、带背景图的元素 */
  function visibleImages() {
    const found = new Set();
    const vw = innerWidth, vh = innerHeight;
    for (let y = 0.06; y < 1; y += 0.11) {
      for (let x = 0.08; x < 1; x += 0.14) {
        const stack = document.elementsFromPoint(x * vw, y * vh);
        for (let i = 0; i < stack.length && i < 6; i++) {
          const el = stack[i];
          if (el.hasAttribute(MARK) || el.closest(`[${MARK}]`)) continue;
          if (el.tagName === 'IMG' || el.tagName === 'CANVAS' || el.tagName === 'image') { found.add(el); break; }
          const bg = getComputedStyle(el).backgroundImage;
          if (bg && bg.includes('url(') && !bg.includes('gradient')) { found.add(el); break; }
        }
      }
    }
    return [...found].filter((el) => {
      const r = el.getBoundingClientRect();
      if (r.width < 60 || r.height < 28) return false;
      if (el.tagName === 'IMG' && !(el.complete && el.naturalWidth > 0)) return false;
      return true;
    });
  }

  async function scanImages() {
    if (ocrRunning || !state.active || !state.images) return;
    ocrRunning = true;
    try {
      for (const el of visibleImages()) {
        if (!state.active) break;
        const r = el.getBoundingClientRect();
        const key = imageKey(el, r);
        if (processed.get(el) === key) continue;
        processed.set(el, key);
        await recognize(el);
      }
    } finally {
      ocrRunning = false;
    }
  }

  async function recognize(el) {
    const gen = generation;
    const old = overlays.get(el);
    if (old) { old.container.remove(); overlays.delete(el); }
    const r = el.getBoundingClientRect();
    const x0 = Math.max(r.left, 0), y0 = Math.max(r.top, 0);
    const x1 = Math.min(r.right, innerWidth), y1 = Math.min(r.bottom, innerHeight);
    if (x1 - x0 < 40 || y1 - y0 < 20) { processed.delete(el); return; }
    const vv = window.visualViewport;
    const s = vv ? vv.scale : 1, ox = vv ? vv.offsetLeft : 0, oy = vv ? vv.offsetTop : 0;
    let boxes;
    try {
      boxes = await handler.postMessage({ type: 'ocr', rect: { x: (x0 - ox) * s, y: (y0 - oy) * s, w: (x1 - x0) * s, h: (y1 - y0) * s, scale: s } });
    } catch (e) { return; }
    if (gen !== generation || !el.isConnected) return;
    if (boxes === null) {
      // 没翻成，过一会儿重新识别，最多 3 次
      const tries = (ocrTries.get(el) || 0) + 1;
      ocrTries.set(el, tries);
      if (tries < 3) setTimeout(() => { if (processed.get(el) && gen === generation) { processed.delete(el); scheduleImages(0); } }, tries * 8000);
      return;
    }
    if (!Array.isArray(boxes) || !boxes.length) return;

    const container = document.createElement('div');
    container.setAttribute(MARK, '');
    container.style.cssText = 'position:fixed;left:0;top:0;pointer-events:none;z-index:2147483646;contain:layout;';
    const dx = x0 - r.left, dy = y0 - r.top;
    for (const b of boxes) {
      const box = document.createElement('div');
      const size = Math.max(8, b.h * 0.78);
      box.textContent = b.text;
      box.style.cssText = `position:absolute;left:${dx + b.x - 1}px;top:${dy + b.y - 1}px;width:${b.w + 2}px;height:${b.h + 2}px;` +
        `background:${b.bg};color:${b.fg};font:600 ${size}px/1.1 -apple-system,system-ui,sans-serif;` +
        'display:flex;align-items:center;white-space:nowrap;overflow:hidden;border-radius:2px;';
      container.appendChild(box);
    }
    document.documentElement.appendChild(container);
    // 译文比原文长时缩小字号塞进原来的框
    for (const box of container.children) {
      if (box.scrollWidth > box.clientWidth) {
        const size = parseFloat(box.style.fontSize) * box.clientWidth / box.scrollWidth;
        box.style.fontSize = `${Math.max(7, size)}px`;
        if (size < 7) { box.style.whiteSpace = 'normal'; box.style.lineHeight = '1'; }
      }
    }
    overlays.set(el, { container, kind: el.tagName });
    positionOverlays();
  }

  function positionOverlays() {
    for (const [el, overlay] of overlays) {
      if (!el.isConnected) { overlay.container.remove(); overlays.delete(el); continue; }
      const r = el.getBoundingClientRect();
      overlay.container.style.transform = `translate(${r.left}px, ${r.top}px)`;
    }
  }

  function clearOverlays() {
    for (const { container } of overlays.values()) container.remove();
    overlays.clear();
    processed.clear();
  }

  // 滚动时跟着图片走；canvas 的内容会在原地变化（Flutter 等整页画在 canvas 里），滚动时先藏起来，停下后重新识别
  let positionFrame = 0;
  let idleTimer = null;
  function onMove() {
    if (!state.active) return;
    if (overlays.size && !positionFrame) {
      positionFrame = requestAnimationFrame(() => { positionFrame = 0; positionOverlays(); });
    }
    for (const [el, overlay] of overlays) {
      if (overlay.kind === 'CANVAS') { overlay.container.remove(); overlays.delete(el); processed.delete(el); }
    }
    if (state.lazy) schedule(250);
    clearTimeout(idleTimer);
    idleTimer = setTimeout(() => scheduleImages(0), 500);
  }
  addEventListener('scroll', onMove, { passive: true, capture: true });
  addEventListener('resize', onMove, { passive: true });
  addEventListener('touchmove', onMove, { passive: true, capture: true });
  addEventListener('wheel', onMove, { passive: true, capture: true });
  // 点一下也可能让 canvas 重画（切换分类、翻页），稍后重新识别
  addEventListener('click', () => {
    if (!state.active) return;
    let stale = false;
    for (const [el, overlay] of overlays) if (overlay.kind === 'CANVAS') { overlay.container.remove(); overlays.delete(el); processed.delete(el); stale = true; }
    if (stale) scheduleImages(700);
  }, { passive: true, capture: true });
  addEventListener('load', (e) => { if (e.target && e.target.tagName === 'IMG') scheduleImages(300); }, true);

  // MARK: - 启动

  addEventListener('message', (e) => {
    if (e.source === window.parent && e.data && e.data.__aetherT) setState(e.data.__aetherT);
  });

  window.__aetherT = { set: setState };
  handler.postMessage({ type: 'state' }).then((s) => { if (s && s.active) setState(s); }).catch(() => {});
})();
