// Aether 元素屏蔽选择器：在独立 content world 里运行，网页脚本碰不到。
// 点选页面元素 → 高亮所有匹配项 → 原生底栏里扩大/缩小范围 → 确认后生成 CSS 选择器。
(() => {
  if (window.__aetherPicker) { window.__aetherPicker.start(); return; }
  const post = (m) => webkit.messageHandlers.aetherPicker.postMessage(m);
  const Z = '2147483647';

  const shield = document.createElement('div');
  shield.setAttribute('style', `position:fixed;inset:0;z-index:${Z};background:transparent;touch-action:none;-webkit-user-select:none`);
  const layer = document.createElement('div');
  layer.setAttribute('style', `position:fixed;inset:0;z-index:${Z};pointer-events:none`);

  let chain = [];      // 当前元素及逐级扩大的祖先
  let selector = '';

  const stable = (s) => /^[A-Za-z_-][\w-]*$/.test(s) && !/\d{4,}/.test(s) && s.length < 40;

  function part(el) {
    if (el.id && stable(el.id)) return '#' + CSS.escape(el.id);
    let s = el.localName;
    const cls = Array.from(el.classList).filter(stable).slice(0, 3);
    if (cls.length) return s + cls.map((c) => '.' + CSS.escape(c)).join('');
    const parent = el.parentElement;
    if (parent) {
      const same = Array.from(parent.children).filter((c) => c.localName === el.localName);
      if (same.length > 1) s += `:nth-of-type(${same.indexOf(el) + 1})`;
    }
    return s;
  }

  function count(sel) {
    try { return document.querySelectorAll(sel).length; } catch (_) { return 0; }
  }

  /// 从元素往上拼，直到选择器只匹配到少量元素
  function selectorFor(el) {
    let sel = part(el);
    let node = el;
    for (let depth = 0; depth < 5 && !sel.startsWith('#') && count(sel) > 1; depth++) {
      const parent = node.parentElement;
      if (!parent || parent === document.body || parent === document.documentElement) break;
      const p = part(parent);
      sel = p + ' > ' + sel;
      node = parent;
      if (p.startsWith('#')) break;
    }
    return sel;
  }

  function draw(sel) {
    layer.textContent = '';
    let nodes = [];
    try { nodes = Array.from(document.querySelectorAll(sel)).slice(0, 60); } catch (_) {}
    for (const n of nodes) {
      const r = n.getBoundingClientRect();
      if (!r.width || !r.height) continue;
      const box = document.createElement('div');
      box.setAttribute('style', `position:fixed;left:${r.left}px;top:${r.top}px;width:${r.width}px;height:${r.height}px;` +
        'border:2px solid #ff3b30;background:rgba(255,59,48,.18);border-radius:4px;box-sizing:border-box');
      layer.appendChild(box);
    }
  }

  function select(el) {
    selector = selectorFor(el);
    draw(selector);
    const r = el.getBoundingClientRect();
    post({ type: 'pick', selector, count: count(selector), width: Math.round(r.width), height: Math.round(r.height) });
  }

  function pickAt(x, y) {
    shield.style.pointerEvents = 'none';
    const el = document.elementFromPoint(x, y);
    shield.style.pointerEvents = 'auto';
    if (!el || el === document.documentElement || el === document.body) return;
    chain = [el];
    select(el);
  }

  const onTouch = (e) => {
    e.preventDefault();
    e.stopPropagation();
    const t = e.touches ? e.touches[0] || e.changedTouches[0] : e;
    if (t) pickAt(t.clientX, t.clientY);
  };

  function start() {
    chain = [];
    selector = '';
    layer.textContent = '';
    document.documentElement.append(shield, layer);
  }

  function stop() {
    shield.remove();
    layer.remove();
  }

  shield.addEventListener('touchstart', onTouch, { passive: false });
  shield.addEventListener('touchmove', onTouch, { passive: false });
  shield.addEventListener('click', onTouch);
  window.addEventListener('scroll', () => { if (selector) draw(selector); }, { passive: true });

  window.__aetherPicker = {
    start,
    expand() {
      const top = chain[chain.length - 1];
      const parent = top && top.parentElement;
      if (!parent || parent === document.body || parent === document.documentElement) return;
      chain.push(parent);
      select(parent);
    },
    shrink() {
      if (chain.length < 2) return;
      chain.pop();
      select(chain[chain.length - 1]);
    },
    confirm() {
      const sel = selector;
      stop();
      if (!sel) return '';
      try {
        for (const n of document.querySelectorAll(sel)) n.style.setProperty('display', 'none', 'important');
      } catch (_) {}
      return sel;
    },
    cancel: stop,
  };
  start();
})();
