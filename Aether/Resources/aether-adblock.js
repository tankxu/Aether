// Aether 广告过滤：网页内脚本引擎（page world，document start，所有 frame）。
// 执行规则表里 WebKit 内容拦截器做不到的部分：
//   1. 脚本规则（uBO scriptlet）：改写网页全局变量 / 定时器 / fetch，对付反广告检测和 YouTube 这类内嵌广告
//   2. 过程式选择器（:has-text、:upward、:matches-css…）
//   3. :style() 样式注入
// 规则数据由原生层在 "/*AETHER_DATA*/" 处注入。
(() => {
  'use strict';
  if (window.__aetherAdblock) return;
  try { Object.defineProperty(window, '__aetherAdblock', { value: true }); } catch (_) { return; }

  const DATA = /*AETHER_DATA*/null;
  if (!DATA || !DATA.r) return;

  // ------------------------------------------------------------ 选出适用于当前域名的规则

  const host = location.hostname.toLowerCase();
  const suffixes = [];
  for (let h = host; h; ) {
    suffixes.push(h);
    const dot = h.indexOf('.');
    if (dot < 0) break;
    h = h.slice(dot + 1);
  }
  const matchesDomain = (d) => suffixes.includes(d);
  const labels = host.split('.');
  // example.* 匹配 example.com / www.example.co.uk（顶级域按 1–2 段算）
  const matchesEntity = (base) => {
    for (let n = 1; n <= 2 && n < labels.length; n++) {
      const rest = labels.slice(0, labels.length - n).join('.');
      if (rest === base || rest.endsWith('.' + base)) return true;
    }
    return false;
  };

  const picked = new Set();
  for (const s of suffixes) for (const i of DATA.d[s] || []) picked.add(i);
  for (const base in DATA.e) if (matchesEntity(base)) for (const i of DATA.e[base]) picked.add(i);
  for (const i of DATA.g) picked.add(i);
  if (!picked.size) return;

  const disabled = new Set();
  for (const s of suffixes.concat(['*'])) for (const k of DATA.x[s] || []) disabled.add(k);

  const scriptlets = [], procedural = [], styles = [];
  for (const i of picked) {
    const [kind, payload, exclude] = DATA.r[i];
    if (exclude.some(matchesDomain)) continue;
    if (kind === 's') {
      if (disabled.has('*') || disabled.has(payload.join('\u0001'))) continue;
      scriptlets.push(payload);
    } else if (kind === 'p') {
      if (!disabled.has('p:' + payload[0])) procedural.push(payload[0]);
    } else if (kind === 'c') {
      styles.push(payload);
    }
  }

  // ------------------------------------------------------------ 工具

  // 页面可能改写全局对象，先把原生方法存下来
  const $ = {
    defineProperty: Object.defineProperty, getOwnPropertyDescriptor: Object.getOwnPropertyDescriptor,
    JSONparse: JSON.parse, JSONstringify: JSON.stringify, Reflect, Proxy, RegExp, Error,
    fetch: window.fetch, Response: window.Response,
    setTimeout: window.setTimeout, setInterval: window.setInterval,
    MutationObserver: window.MutationObserver,
  };

  const magic = String.fromCharCode(Date.now() % 26 + 97) + Math.floor(Math.random() * 982451653 + 982451653).toString(36);
  window.addEventListener('error', (e) => {
    if (typeof e.message === 'string' && e.message.includes(magic)) e.preventDefault();
  }, true);
  const abort = () => { throw new ReferenceError(magic); };

  function toRegex(pattern, flags) {
    if (pattern === undefined || pattern === '') return /^/;
    const m = /^\/(.+)\/([gimsuy]*)$/.exec(pattern);
    if (m) {
      try { return new $.RegExp(m[1], flags !== undefined ? flags : m[2]); } catch (_) { return /^\b$/; }
    }
    return new $.RegExp(pattern.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'), flags || '');
  }

  /// "!xxx" 表示取反
  function needle(pattern) {
    let not = false;
    if (typeof pattern === 'string' && pattern.startsWith('!')) { not = true; pattern = pattern.slice(1); }
    const re = toRegex(pattern);
    return { test: (s) => re.test(s) !== not, empty: !pattern };
  }

  function constantValue(raw) {
    switch (raw) {
      case 'undefined': return undefined;
      case 'false': return false;
      case 'true': return true;
      case 'null': return null;
      case "''": case 'emptyStr': case '': return '';
      case '[]': case 'emptyArr': return [];
      case '{}': case 'emptyObj': return {};
      case 'noopFunc': return function () {};
      case 'trueFunc': return function () { return true; };
      case 'falseFunc': return function () { return false; };
      case 'throwFunc': return function () { throw new Error(); };
      case 'noopCallbackFunc': return function () { return function () {}; };
      case 'yes': case 'no': case 'on': case 'off': case 'ok': case 'accept': case 'reject': case 'allowed': case 'denied':
        return raw;
      default:
        if (/^-?\d+$/.test(raw) && Math.abs(+raw) <= 0x7FFF) return +raw;
        return Symbol.for('aether-invalid');
    }
  }

  /// 在属性链上设陷阱：链上的对象还不存在时，等它被赋值再往下挂
  function trapChain(chain, leaf) {
    const trap = (owner, path) => {
      const pos = path.indexOf('.');
      if (pos === -1) { leaf(owner, path); return; }
      const prop = path.slice(0, pos);
      const rest = path.slice(pos + 1);
      if (prop === '[]') { // 数组/对象的每个元素
        if (owner instanceof Object) for (const k of Object.keys(owner)) trap(owner[k], rest);
        return;
      }
      const v = owner[prop];
      if (v instanceof Object || (typeof v === 'object' && v !== null)) { trap(v, rest); return; }
      const desc = $.getOwnPropertyDescriptor(owner, prop);
      if (desc && desc.configurable === false) return;
      let stored = v;
      try {
        $.defineProperty(owner, prop, {
          configurable: true,
          get() { return stored; },
          set(a) {
            stored = a;
            if (a instanceof Object) trap(a, rest);
          },
        });
      } catch (_) {}
    };
    trap(window, chain);
  }

  function onDomReady(fn) {
    if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', fn, { once: true });
    else fn();
  }

  function observe(fn) {
    let scheduled = false;
    const run = () => { scheduled = false; try { fn(); } catch (_) {} };
    onDomReady(run);
    new $.MutationObserver(() => {
      if (scheduled) return;
      scheduled = true;
      $.setTimeout.call(window, run, 100);
    }).observe(document, { childList: true, subtree: true, attributes: false });
  }

  // ------------------------------------------------------------ JSON 裁剪

  function hasPath(obj, segs, i) {
    if (i >= segs.length) return true;
    if (obj === null || typeof obj !== 'object') return false;
    const seg = segs[i];
    if (seg === '[]' || seg === '*' || seg === '[-]') return Object.keys(obj).some((k) => hasPath(obj[k], segs, i + 1));
    return seg in obj && hasPath(obj[seg], segs, i + 1);
  }

  function prunePath(obj, segs, i) {
    if (obj === null || typeof obj !== 'object') return false;
    const seg = segs[i];
    const last = i === segs.length - 1;
    if (seg === '[-]') {
      if (!Array.isArray(obj)) return false;
      let hit = false;
      for (let k = obj.length - 1; k >= 0; k--) {
        if (hasPath(obj[k], segs, i + 1)) { obj.splice(k, 1); hit = true; }
      }
      return hit;
    }
    if (seg === '[]' || seg === '*') {
      let hit = false;
      for (const k of Object.keys(obj)) {
        if (last) { delete obj[k]; hit = true; } else if (prunePath(obj[k], segs, i + 1)) hit = true;
      }
      return hit;
    }
    if (last) {
      if (seg in obj) { delete obj[seg]; return true; }
      return false;
    }
    return prunePath(obj[seg], segs, i + 1);
  }

  function makePruner(rawPrune, rawNeedles) {
    const prune = (rawPrune || '').split(/ +/).filter(Boolean).map((p) => p.split('.'));
    const needles = (rawNeedles || '').split(/ +/).filter(Boolean).map((p) => p.split('.'));
    return (obj) => {
      if (!obj || typeof obj !== 'object') return false;
      if (needles.length && !needles.every((n) => hasPath(obj, n, 0))) return false;
      let hit = false;
      for (const p of prune) if (prunePath(obj, p, 0)) hit = true;
      return hit;
    };
  }

  /// propsToMatch：`url:/re/ method:POST` 或直接是网址规则
  function requestMatcher(props) {
    if (!props) return () => true;
    const conds = [];
    for (const part of props.split(/\s+/)) {
      if (!part) continue;
      const m = /^(\w+):(.+)$/.exec(part);
      if (m) conds.push([m[1], needle(m[2])]); else conds.push(['url', needle(part)]);
    }
    return (req) => conds.every(([k, n]) => n.test(String(req[k] || '')));
  }

  function requestInfo(input, init) {
    let url = '', method = 'GET';
    if (typeof input === 'string' || input instanceof URL) url = String(input);
    else if (input && typeof input === 'object') { url = input.url || ''; method = input.method || method; }
    if (init && init.method) method = init.method;
    return { url, method: String(method).toUpperCase() };
  }

  function rewriteFetch(match, transform) {
    window.fetch = new $.Proxy(window.fetch, {
      apply(target, thisArg, args) {
        const p = $.Reflect.apply(target, thisArg, args);
        if (!match(requestInfo(args[0], args[1]))) return p;
        return p.then((resp) => resp.clone().text().then((text) => {
          const out = transform(text);
          if (out === text) return resp;
          const r = new $.Response(out, { status: resp.status, statusText: resp.statusText, headers: resp.headers });
          try {
            $.defineProperty(r, 'url', { value: resp.url });
            $.defineProperty(r, 'type', { value: resp.type });
          } catch (_) {}
          return r;
        }).catch(() => resp));
      },
    });
  }

  function rewriteXHR(match, transform) {
    const info = new WeakMap();
    const proto = XMLHttpRequest.prototype;
    proto.open = new $.Proxy(proto.open, {
      apply(target, xhr, args) {
        info.set(xhr, { url: String(args[1] || ''), method: String(args[0] || 'GET').toUpperCase() });
        return $.Reflect.apply(target, xhr, args);
      },
    });
    const textDesc = $.getOwnPropertyDescriptor(proto, 'responseText');
    const respDesc = $.getOwnPropertyDescriptor(proto, 'response');
    const cache = new WeakMap();
    const rewritten = (xhr) => {
      const meta = info.get(xhr);
      if (!meta || xhr.readyState !== 4 || !match(meta)) return null;
      if (cache.has(xhr)) return cache.get(xhr);
      const type = xhr.responseType;
      if (type !== '' && type !== 'text' && type !== 'json') return null;
      let text = type === 'json' ? $.JSONstringify(respDesc.get.call(xhr)) : textDesc.get.call(xhr);
      text = transform(text);
      cache.set(xhr, text);
      return text;
    };
    $.defineProperty(proto, 'responseText', {
      configurable: true,
      get() { const t = rewritten(this); return t !== null ? t : textDesc.get.call(this); },
    });
    $.defineProperty(proto, 'response', {
      configurable: true,
      get() {
        const t = rewritten(this);
        if (t === null) return respDesc.get.call(this);
        if (this.responseType === 'json') { try { return $.JSONparse(t); } catch (_) { return null; } }
        return t;
      },
    });
  }

  function jsonTransform(pruner) {
    return (text) => {
      try {
        const obj = $.JSONparse(text);
        return pruner(obj) ? $.JSONstringify(obj) : text;
      } catch (_) { return text; }
    };
  }

  function replaceTransform(pattern, replacement) {
    const re = toRegex(pattern, /^\/.+\/[a-z]*$/.test(pattern) ? undefined : 'g');
    if (pattern.startsWith('/') && !re.global) {
      // uBO 对正则形式默认全局替换
      try { return (t) => t.replace(new $.RegExp(re.source, re.flags + 'g'), replacement || ''); } catch (_) {}
    }
    return (t) => t.replace(re, replacement || '');
  }

  function wrapTimer(name, test, mutate) {
    window[name] = new $.Proxy(window[name], {
      apply(target, thisArg, args) {
        const [fn, delay] = args;
        const code = typeof fn === 'function' ? Function.prototype.toString.call(fn) : String(fn);
        if (test(code, delay)) {
          if (mutate) mutate(args);
          else args[0] = function () {};
        }
        return $.Reflect.apply(target, thisArg, args);
      },
    });
  }

  function storageValue(raw) {
    const ok = ['undefined', 'false', 'true', 'null', 'emptyObj', 'emptyArr', '', 'yes', 'no', 'on', 'off', '$remove$'];
    if (raw === 'emptyObj') return '{}';
    if (raw === 'emptyArr') return '[]';
    if (ok.includes(raw) || /^\d+$/.test(raw)) return raw;
    return null;
  }

  // ------------------------------------------------------------ 脚本规则

  const S = {
    'set-constant'(chain, raw, ...extra) {
      let value = constantValue(raw);
      if (value === Symbol.for('aether-invalid')) return;
      if (extra.includes('asFunction')) { const v = value; value = function () { return v; }; }
      else if (extra.includes('asCallback')) { const v = value; value = function () { return function () { return v; }; }; }
      else if (extra.includes('asResolved')) value = Promise.resolve(value);
      else if (extra.includes('asRejected')) value = Promise.reject(value);
      trapChain(chain, (owner, prop) => {
        const desc = $.getOwnPropertyDescriptor(owner, prop);
        if (desc && desc.configurable === false) return;
        const prev = owner[prop];
        // 类型不一致说明网页用法变了，不改免得弄坏页面
        if (prev !== undefined && prev !== null && value !== undefined && value !== null && typeof prev !== typeof value) return;
        try {
          $.defineProperty(owner, prop, { configurable: false, get: () => value, set: () => {} });
        } catch (_) {}
      });
    },

    'abort-on-property-read'(chain) {
      trapChain(chain, (owner, prop) => {
        try { $.defineProperty(owner, prop, { configurable: false, get: abort, set: () => {} }); } catch (_) {}
      });
    },

    'abort-on-property-write'(chain) {
      trapChain(chain, (owner, prop) => {
        try { $.defineProperty(owner, prop, { configurable: false, get: () => undefined, set: abort }); } catch (_) {}
      });
    },

    'abort-current-script'(chain, search, context) {
      const n = needle(search || '');
      const ctx = context ? toRegex(context) : null;
      const me = document.currentScript;
      const check = () => {
        const s = document.currentScript;
        if (!(s instanceof HTMLScriptElement) || s === me) return;
        if (ctx && !ctx.test(s.src)) return;
        const text = s.src && !s.textContent ? s.src : s.textContent;
        if (search && !n.test(text)) return;
        abort();
      };
      trapChain(chain, (owner, prop) => {
        const desc = $.getOwnPropertyDescriptor(owner, prop) || {};
        if (desc.configurable === false) return;
        let value = owner[prop];
        try {
          $.defineProperty(owner, prop, {
            configurable: true,
            get() { check(); return desc.get ? desc.get.call(this) : value; },
            set(a) { check(); if (desc.set) desc.set.call(this, a); else value = a; },
          });
        } catch (_) {}
      });
    },

    'abort-on-stack-trace'(chain, search) {
      const n = needle(search || '');
      const check = () => { if (n.test(new $.Error().stack || '')) abort(); };
      trapChain(chain, (owner, prop) => {
        let value = owner[prop];
        try {
          $.defineProperty(owner, prop, {
            configurable: true,
            get() { check(); return value; },
            set(a) { check(); value = a; },
          });
        } catch (_) {}
      });
    },

    'addEventListener-defuser'(type, search) {
      const t = needle(type || ''), n = needle(search || '');
      const proto = EventTarget.prototype;
      proto.addEventListener = new $.Proxy(proto.addEventListener, {
        apply(target, thisArg, args) {
          const [evt, fn] = args;
          const code = typeof fn === 'function' ? Function.prototype.toString.call(fn) : String(fn);
          if (t.test(String(evt)) && n.test(code)) return;
          return $.Reflect.apply(target, thisArg, args);
        },
      });
    },

    'no-setTimeout-if'(search, delay) { timerDefuser('setTimeout', search, delay); },
    'no-setInterval-if'(search, delay) { timerDefuser('setInterval', search, delay); },

    'adjust-setTimeout'(search, delay, boost) { timerBooster('setTimeout', search, delay, boost); },
    'adjust-setInterval'(search, delay, boost) { timerBooster('setInterval', search, delay, boost); },

    'no-window-open-if'(search) {
      const n = needle(search || '');
      window.open = new $.Proxy(window.open, {
        apply(target, thisArg, args) {
          if (!n.test(String(args[0] || ''))) return $.Reflect.apply(target, thisArg, args);
          return new $.Proxy({}, { get: (_, k) => (k === 'closed' ? false : function () {}), set: () => true });
        },
      });
    },

    'json-prune'(prune, needles) {
      const pruner = makePruner(prune, needles);
      JSON.parse = new $.Proxy(JSON.parse, {
        apply(target, thisArg, args) {
          const obj = $.Reflect.apply(target, thisArg, args);
          pruner(obj);
          return obj;
        },
      });
      const json = $.Response.prototype.json;
      $.Response.prototype.json = new $.Proxy(json, {
        apply(target, thisArg, args) {
          return $.Reflect.apply(target, thisArg, args).then((obj) => { pruner(obj); return obj; });
        },
      });
    },

    'json-prune-fetch-response'(prune, needles, ...rest) {
      rewriteFetch(requestMatcher(extraArg(rest, 'propsToMatch')), jsonTransform(makePruner(prune, needles)));
    },

    'json-prune-xhr-response'(prune, needles, ...rest) {
      rewriteXHR(requestMatcher(extraArg(rest, 'propsToMatch')), jsonTransform(makePruner(prune, needles)));
    },

    'trusted-replace-fetch-response'(pattern, replacement, props) {
      if (!pattern) return;
      rewriteFetch(requestMatcher(props), replaceTransform(pattern, replacement));
    },

    'trusted-replace-xhr-response'(pattern, replacement, props) {
      if (!pattern) return;
      rewriteXHR(requestMatcher(props), replaceTransform(pattern, replacement));
    },

    'no-fetch-if'(props, body) {
      const match = requestMatcher(props);
      const text = body === 'emptyObj' ? '{}' : body === 'emptyArr' ? '[]' : body === 'true' ? 'true' : '';
      window.fetch = new $.Proxy(window.fetch, {
        apply(target, thisArg, args) {
          if (!props || !match(requestInfo(args[0], args[1]))) return $.Reflect.apply(target, thisArg, args);
          return Promise.resolve(new $.Response(text, { status: 200, statusText: 'OK' }));
        },
      });
    },

    'no-xhr-if'(props) {
      const match = requestMatcher(props);
      const blocked = new WeakSet();
      const proto = XMLHttpRequest.prototype;
      proto.open = new $.Proxy(proto.open, {
        apply(target, xhr, args) {
          if (props && match({ url: String(args[1] || ''), method: String(args[0] || 'GET').toUpperCase() })) blocked.add(xhr);
          return $.Reflect.apply(target, xhr, args);
        },
      });
      proto.send = new $.Proxy(proto.send, {
        apply(target, xhr, args) {
          if (!blocked.has(xhr)) return $.Reflect.apply(target, xhr, args);
          for (const [k, v] of [['readyState', 4], ['status', 200], ['statusText', 'OK'], ['responseText', ''], ['response', '']]) {
            try { $.defineProperty(xhr, k, { value: v, configurable: true }); } catch (_) {}
          }
          $.setTimeout.call(window, () => {
            for (const t of ['readystatechange', 'load', 'loadend']) xhr.dispatchEvent(new Event(t));
          }, 1);
        },
      });
    },

    'noeval-if'(search) {
      const n = needle(search || '');
      window.eval = new $.Proxy(window.eval, {
        apply(target, thisArg, args) {
          if (n.test(String(args[0]))) return;
          return $.Reflect.apply(target, thisArg, args);
        },
      });
    },

    'remove-attr'(attrs, selector) {
      const list = (attrs || '').split(/\s*\|\s*/).filter(Boolean);
      if (!list.length) return;
      const sel = selector || list.map((a) => `[${CSS.escape(a)}]`).join(',');
      observe(() => {
        for (const el of document.querySelectorAll(sel)) for (const a of list) el.removeAttribute(a);
      });
    },

    'remove-class'(classes, selector) {
      const list = (classes || '').split(/\s*\|\s*/).filter(Boolean);
      if (!list.length) return;
      const sel = selector || list.map((c) => '.' + CSS.escape(c)).join(',');
      observe(() => {
        for (const el of document.querySelectorAll(sel)) el.classList.remove(...list);
      });
    },

    'remove-node-text'(nodeName, condition) {
      const name = toRegex(nodeName || '');
      const cond = needle(condition || '');
      const scan = (node) => {
        if (name.test(node.nodeName.toLowerCase()) && cond.test(node.textContent)) node.textContent = '';
      };
      new $.MutationObserver((muts) => {
        for (const m of muts) for (const n of m.addedNodes) scan(n);
      }).observe(document, { childList: true, subtree: true });
    },

    'nowebrtc'() {
      for (const k of ['RTCPeerConnection', 'webkitRTCPeerConnection']) {
        if (!window[k]) continue;
        window[k] = function () { return { close() {}, createDataChannel() {}, createOffer() { return Promise.reject(); }, setLocalDescription() {} }; };
      }
    },

    'set-cookie'(name, value, path) {
      const v = storageValue(value);
      if (!name || v === null) return;
      document.cookie = `${encodeURIComponent(name)}=${encodeURIComponent(v)}; path=${path === 'none' ? '' : '/'}`;
    },

    'set-local-storage-item'(key, value) { setStorage(localStorage, key, value); },
    'set-session-storage-item'(key, value) { setStorage(sessionStorage, key, value); },
  };

  function extraArg(rest, name) {
    const i = rest.indexOf(name);
    return i >= 0 ? rest[i + 1] : undefined;
  }

  function setStorage(store, key, value) {
    const v = storageValue(value);
    if (!key || v === null) return;
    try { if (v === '$remove$') store.removeItem(key); else store.setItem(key, v); } catch (_) {}
  }

  function timerDefuser(name, search, delay) {
    const n = needle(search || '');
    let d = null;
    if (delay) {
      const not = delay.startsWith('!');
      const ms = parseInt(not ? delay.slice(1) : delay, 10);
      if (!isNaN(ms)) d = (x) => ((+x === ms) !== not);
    }
    wrapTimer(name, (code, ms) => n.test(code) && (!d || d(ms)));
  }

  function timerBooster(name, search, delay, boost) {
    const n = needle(search || '');
    const target = delay === '*' ? null : parseInt(delay || '1000', 10);
    let factor = parseFloat(boost || '0.05');
    if (!isFinite(factor)) factor = 0.05;
    factor = Math.min(50, Math.max(0.001, factor));
    wrapTimer(name, (code, ms) => n.test(code) && (target === null || +ms === target), (args) => { args[1] = (+args[1] || 0) * factor; });
  }

  for (const [name, ...args] of scriptlets) {
    const fn = S[name];
    if (fn) { try { fn(...args); } catch (_) {} }
  }

  // ------------------------------------------------------------ :style()

  if (styles.length) {
    const css = styles.map(([sel, decl]) => `${sel} { ${decl} }`).join('\n');
    const add = () => {
      const style = document.createElement('style');
      style.textContent = css;
      (document.head || document.documentElement).appendChild(style);
    };
    if (document.documentElement) add(); else onDomReady(add);
  }

  // ------------------------------------------------------------ 过程式选择器

  const OPS = new Set(['has-text', 'upward', 'xpath', 'matches-css', 'matches-css-before', 'matches-css-after',
    'min-text-length', 'matches-path', 'remove', 'style', 'remove-attr', 'remove-class', 'nth-ancestor',
    'watch-attr', 'has', 'not', 'if', 'if-not', 'matches-attr', 'matches-prop', 'others', 'matches-media']);
  const PROCEDURAL_RE = /:(has-text|upward|xpath|matches-css(-before|-after)?|min-text-length|matches-path|remove|style|remove-attr|remove-class|nth-ancestor|watch-attr|if|if-not|matches-attr|matches-prop|others|matches-media)\(/;

  /// "div.a:has-text(x):upward(2)" → { css: "div.a", tasks: [["has-text","x"],["upward","2"]] }
  function compileSelector(src) {
    const tasks = [];
    let css = '';
    let i = 0;
    let current = '';
    const flushCss = () => {
      if (!current) return;
      if (!tasks.length) css += current; else tasks.push(['spath', current]);
      current = '';
    };
    while (i < src.length) {
      const c = src[i];
      if (c === '\\') { current += src.slice(i, i + 2); i += 2; continue; }
      if (c === ':') {
        const m = /^:([a-z-]+)\(/.exec(src.slice(i));
        if (m && OPS.has(m[1])) {
          // 找到匹配的右括号
          let depth = 1, j = i + m[0].length, quote = null;
          for (; j < src.length && depth; j++) {
            const ch = src[j];
            if (ch === '\\') { j++; continue; }
            if (quote) { if (ch === quote) quote = null; continue; }
            if (ch === '"' || ch === "'") quote = ch;
            else if (ch === '(') depth++;
            else if (ch === ')') depth--;
          }
          const arg = src.slice(i + m[0].length, j - 1);
          let op = m[1];
          if ((op === 'has' || op === 'not') && !PROCEDURAL_RE.test(arg)) {
            current += src.slice(i, j); // 普通 CSS 的 :has / :not
            i = j;
            continue;
          }
          if (op === 'if') op = 'has';
          if (op === 'if-not') op = 'not';
          flushCss();
          if (!css && !tasks.length) css = '*';
          tasks.push([op, arg]);
          i = j;
          continue;
        }
      }
      current += c;
      i++;
    }
    flushCss();
    return { css: css.trim() || '*', tasks };
  }

  function textMatcher(arg) {
    return toRegex(arg.replace(/^(['"])(.*)\1$/, '$2'));
  }

  function run(compiled, root) {
    let nodes;
    try { nodes = Array.from((root || document).querySelectorAll(compiled.css)); } catch (_) { return { nodes: [], action: null }; }
    let action = null;
    for (const [op, arg] of compiled.tasks) {
      if (!nodes.length) break;
      switch (op) {
        case 'has-text': { const re = textMatcher(arg); nodes = nodes.filter((n) => re.test(n.textContent)); break; }
        case 'min-text-length': { const len = parseInt(arg, 10) || 0; nodes = nodes.filter((n) => n.textContent.length >= len); break; }
        case 'has': { const inner = compileSelector(arg.replace(/^\s*>/, ':scope >')); nodes = nodes.filter((n) => run(inner, n).nodes.length > 0); break; }
        case 'not': { const inner = compileSelector(arg); const bad = new Set(run(inner, document).nodes); nodes = nodes.filter((n) => !bad.has(n)); break; }
        case 'upward': case 'nth-ancestor': {
          const k = parseInt(arg, 10);
          nodes = nodes.map((n) => {
            if (!isNaN(k) && String(k) === arg.trim()) { let p = n; for (let x = 0; x < k && p; x++) p = p.parentElement; return p; }
            return n.parentElement ? n.parentElement.closest(arg) : null;
          }).filter(Boolean);
          break;
        }
        case 'matches-css': case 'matches-css-before': case 'matches-css-after': {
          const pseudo = op === 'matches-css' ? null : '::' + op.split('-').pop();
          const m = /^\s*([\w-]+)\s*:\s*(.+?)\s*$/.exec(arg);
          if (!m) { nodes = []; break; }
          const re = textMatcher(m[2]);
          nodes = nodes.filter((n) => re.test(getComputedStyle(n, pseudo).getPropertyValue(m[1])));
          break;
        }
        case 'matches-path': { if (!textMatcher(arg).test(location.pathname + location.search)) nodes = []; break; }
        case 'xpath': {
          const out = [];
          for (const n of nodes) {
            try {
              const r = document.evaluate(arg, n, null, XPathResult.ORDERED_NODE_SNAPSHOT_TYPE, null);
              for (let x = 0; x < r.snapshotLength; x++) if (r.snapshotItem(x).nodeType === 1) out.push(r.snapshotItem(x));
            } catch (_) {}
          }
          nodes = out;
          break;
        }
        case 'spath': {
          const out = [];
          for (const n of nodes) { try { out.push(...n.querySelectorAll(':scope' + arg)); } catch (_) {} }
          nodes = out;
          break;
        }
        case 'remove': case 'style': case 'remove-attr': case 'remove-class':
          action = [op, arg];
          break;
        default:
          break; // watch-attr / others 等：忽略算子本身
      }
    }
    return { nodes, action };
  }

  if (procedural.length) {
    const compiled = procedural.map(compileSelector);
    const done = new WeakSet();
    observe(() => {
      for (const c of compiled) {
        const { nodes, action } = run(c);
        for (const n of nodes) {
          if (!action) {
            if (done.has(n)) continue;
            done.add(n);
            n.style.setProperty('display', 'none', 'important');
          } else if (action[0] === 'remove') n.remove();
          else if (action[0] === 'style') n.setAttribute('style', (n.getAttribute('style') || '') + ';' + action[1]);
          else if (action[0] === 'remove-attr') n.removeAttribute(action[1]);
          else if (action[0] === 'remove-class') n.classList.remove(action[1]);
        }
      }
    });
  }
})();
