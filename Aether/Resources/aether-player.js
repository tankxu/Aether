// Aether 全屏接管脚本：注入到所有 frame（page world，document start）。
//
// 网页里的任何全屏请求（requestFullscreen / webkitEnterFullscreen / 原生控件全屏按钮）
// 都不走系统播放器，而是把 <video> 原地铺满视口（伪全屏），由原生层画控制按钮。
// 视频仍由网页自己的管线解码（MSE / HLS / blob 都能用），<track> 字幕也保留。
(() => {
  'use strict';
  if (window.__aether) return;
  const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.aether;
  if (!handler) return;

  const post = (m) => { try { handler.postMessage(m); } catch (_) {} };
  const isTop = window.top === window;
  const MAX_Z = '2147483647';

  // 常见播放器自绘字幕层：容器全屏时让它们保持可见
  const CAPTION_SELECTORS = [
    '.ytp-caption-window-container', '.caption-window',
    '.bpx-player-subtitle-wrap', '.bilibili-player-video-subtitle',
    '.vjs-text-track-display', '.jw-captions', '.jw-text-track-container',
    '.plyr__captions', '.dplayer-subtitle', '.art-subtitle', '.xgplayer-subtitle',
    '.shaka-text-container', '.mejs__captions-layer', '.fp-captions', 'media-captions',
  ].join(',');

  const VideoProto = HTMLVideoElement.prototype;
  const MediaProto = HTMLMediaElement.prototype;
  const ElemProto = Element.prototype;
  const DocProto = Document.prototype;
  const presentationModeDesc = Object.getOwnPropertyDescriptor(VideoProto, 'webkitPresentationMode');
  const native = {
    videoExit: VideoProto.webkitExitFullscreen,
    requestFullscreen: ElemProto.requestFullscreen,
    webkitRequestFullscreen: ElemProto.webkitRequestFullscreen,
    setPresentationMode: VideoProto.webkitSetPresentationMode,
    presentationMode: presentationModeDesc && presentationModeDesc.get,
    play: MediaProto.play,
  };

  // ---------------------------------------------------------------- 样式

  const TARGET_PROPS = {
    position: 'fixed', top: '0', left: '0', right: '0', bottom: '0',
    width: '100%', height: '100%', 'min-width': '0', 'min-height': '0',
    'max-width': 'none', 'max-height': 'none', margin: '0', padding: '0', border: '0',
    transform: 'none', translate: 'none', scale: 'none', rotate: 'none',
    filter: 'none', opacity: '1', 'clip-path': 'none', 'border-radius': '0',
    'z-index': MAX_Z, visibility: 'visible', display: 'block', background: '#000',
    'object-fit': 'contain', 'object-position': '50% 50%',
  };
  // 祖先上这些属性会让 position:fixed 相对祖先定位或把画面变淡，临时清掉
  const ANCESTOR_PROPS = {
    transform: 'none', translate: 'none', scale: 'none', rotate: 'none',
    filter: 'none', 'backdrop-filter': 'none', '-webkit-backdrop-filter': 'none',
    perspective: 'none', contain: 'none', 'container-type': 'normal', 'will-change': 'auto',
    'clip-path': 'none', mask: 'none', '-webkit-mask': 'none', opacity: '1',
    'content-visibility': 'visible', visibility: 'hidden',
  };

  let styleEl = null;
  function ensureStyle() {
    if (styleEl && styleEl.isConnected) return;
    styleEl = document.createElement('style');
    styleEl.textContent = `
      html.__aether-fs, html.__aether-fs > body { overflow: hidden !important; background: #000 !important; }
      html.__aether-fs * { visibility: hidden !important; }
      html.__aether-fs .__aether-target,
      html.__aether-fs .__aether-keep,
      html.__aether-fs .__aether-keep * { visibility: visible !important; }
      html.__aether-fs .__aether-target {
        position: fixed !important; top: 0 !important; left: 0 !important;
        width: 100% !important; height: 100% !important;
        max-width: none !important; max-height: none !important;
        transform: none !important; object-fit: contain !important;
      }`;
    (document.head || document.documentElement).appendChild(styleEl);
  }

  // 以 !important 写行内样式（能穿透 shadow DOM），并记录原值以便还原
  function applyProps(el, props, restores) {
    const prev = [];
    for (const k in props) {
      prev.push([k, el.style.getPropertyValue(k), el.style.getPropertyPriority(k)]);
      el.style.setProperty(k, props[k], 'important');
    }
    restores.push(() => {
      for (const [k, v, p] of prev) {
        if (v) el.style.setProperty(k, v, p); else el.style.removeProperty(k);
      }
    });
  }

  function addClass(el, cls, restores) {
    if (el.classList.contains(cls)) return;
    el.classList.add(cls);
    restores.push(() => el.classList.remove(cls));
  }

  function forEachAncestor(el, fn) {
    let node = el;
    for (;;) {
      let p = node.parentNode;
      if (!p) break;
      if (p instanceof ShadowRoot) p = p.host;
      if (p === document.documentElement || p === document) break;
      if (p.nodeType === 1) fn(p);
      node = p;
    }
  }

  function runRestores(restores) {
    for (let i = restores.length - 1; i >= 0; i--) { try { restores[i](); } catch (_) {} }
    restores.length = 0;
  }

  function syncRootClass() {
    const root = document.documentElement;
    if (!root) return;
    if (active || frameTarget) root.classList.add('__aether-fs');
    else root.classList.remove('__aether-fs');
  }

  // ---------------------------------------------------------------- 状态上报

  const num = (v) => (typeof v === 'number' && isFinite(v) ? v : 0);

  const isSubtitle = (t) => t.kind === 'subtitles' || t.kind === 'captions';

  function trackList(list, accept, isOn) {
    const out = [];
    for (let i = 0; list && i < list.length; i++) {
      const t = list[i];
      if (!accept(t)) continue;
      out.push({ i, label: t.label || t.language || '', lang: t.language || '', on: isOn(t) });
    }
    return out;
  }

  function snapshot(v) {
    let d = v.duration, live = false, ss = 0, se = 0;
    if (!isFinite(d)) {
      live = d === Infinity;
      d = 0;
      if (v.seekable && v.seekable.length) { ss = v.seekable.start(0); se = v.seekable.end(v.seekable.length - 1); }
    }
    let buf = 0;
    const b = v.buffered, t = v.currentTime;
    for (let i = 0; b && i < b.length; i++) {
      if (b.start(i) <= t + 0.5 && b.end(i) >= t) buf = b.end(i);
    }
    return {
      t: num(t), d: num(d), live, ss: num(ss), se: num(se), buf: num(buf),
      paused: !!v.paused, ended: !!v.ended, rate: num(v.playbackRate) || 1,
      w: num(v.videoWidth), h: num(v.videoHeight),
      text: trackList(v.textTracks, isSubtitle, (x) => x.mode === 'showing'),
      audio: trackList(v.audioTracks, () => true, (x) => !!x.enabled),
    };
  }

  function report(type) {
    if (!active) return;
    const s = snapshot(active.video);
    s.type = type;
    post(s);
  }

  let throttleTimer = 0;
  function onMediaEvent(e) {
    if (e.type === 'timeupdate' || e.type === 'progress') {
      if (throttleTimer) return;
      throttleTimer = setTimeout(() => { throttleTimer = 0; report('state'); }, 200);
      return;
    }
    report('state');
  }
  const MEDIA_EVENTS = ['timeupdate', 'progress', 'play', 'pause', 'playing', 'waiting', 'seeked',
    'ratechange', 'durationchange', 'loadedmetadata', 'resize', 'ended', 'emptied'];
  const TRACK_EVENTS = ['addtrack', 'removetrack', 'change'];

  function bindVideo(v, on) {
    const m = on ? 'addEventListener' : 'removeEventListener';
    for (const t of MEDIA_EVENTS) v[m](t, onMediaEvent);
    for (const list of [v.textTracks, v.audioTracks]) {
      if (list) for (const t of TRACK_EVENTS) list[m](t, onMediaEvent);
    }
  }

  // ---------------------------------------------------------------- 进入 / 退出

  let active = null;      // 本 frame 内被接管的视频
  let frameTarget = null; // 父 frame：被铺满的 iframe
  let firing = false;

  function fireChange(el, entering, via) {
    setTimeout(() => {
      firing = true;
      try {
        const target = el.isConnected ? el : document;
        for (const t of ['fullscreenchange', 'webkitfullscreenchange']) {
          target.dispatchEvent(new Event(t, { bubbles: true, composed: true }));
        }
        if (via === 'video') {
          el.dispatchEvent(new Event(entering ? 'webkitbeginfullscreen' : 'webkitendfullscreen', { bubbles: true }));
        }
      } finally { firing = false; }
    }, 0);
  }

  function enter(video, box, reported, via) {
    if (active) {
      if (active.video === video) return true;
      teardown(false);
    }
    ensureStyle();
    const restores = [];
    const saved = { controls: video.controls, x: window.scrollX, y: window.scrollY };

    forEachAncestor(video, (a) => applyProps(a, ANCESTOR_PROPS, restores));
    if (box && box !== video) {
      // 网页请求的是播放器容器：容器也铺满，以保留它自绘的字幕层
      const boxProps = Object.assign({}, TARGET_PROPS, { visibility: 'hidden', background: 'transparent' });
      applyProps(box, boxProps, restores);
      for (const c of box.querySelectorAll(CAPTION_SELECTORS)) {
        addClass(c, '__aether-keep', restores);
        applyProps(c, { visibility: 'visible' }, restores);
      }
    }
    addClass(video, '__aether-target', restores);
    applyProps(video, box && box !== video ? Object.assign({}, TARGET_PROPS, { 'z-index': '0' }) : TARGET_PROPS, restores);
    video.controls = false;

    active = { video, box, reported: reported || video, via, saved, restores };
    syncRootClass();
    bindVideo(video, true);
    report('enter');
    if (!isTop) parent.postMessage({ __aether: 'frame-enter' }, '*');
    fireChange(active.reported, true, via);
    return true;
  }

  function teardown(fromNative) {
    const a = active;
    if (!a) return;
    active = null;
    bindVideo(a.video, false);
    runRestores(a.restores);
    a.video.controls = a.saved.controls;
    syncRootClass();
    window.scrollTo(a.saved.x, a.saved.y);
    if (!fromNative) post({ type: 'exit' });
    if (!isTop) parent.postMessage({ __aether: 'frame-exit' }, '*');
    fireChange(a.reported, false, a.via);
  }

  function enterFrame(iframe) {
    if (frameTarget && frameTarget.iframe === iframe) return;
    exitFrame();
    ensureStyle();
    const restores = [];
    forEachAncestor(iframe, (a) => applyProps(a, ANCESTOR_PROPS, restores));
    addClass(iframe, '__aether-target', restores);
    applyProps(iframe, TARGET_PROPS, restores);
    frameTarget = { iframe, restores, x: window.scrollX, y: window.scrollY };
    syncRootClass();
    if (!isTop) parent.postMessage({ __aether: 'frame-enter' }, '*');
  }

  function exitFrame() {
    const f = frameTarget;
    if (!f) return;
    frameTarget = null;
    runRestores(f.restores);
    syncRootClass();
    window.scrollTo(f.x, f.y);
    if (!isTop) parent.postMessage({ __aether: 'frame-exit' }, '*');
  }

  // 子 frame 进入/退出全屏时，逐级把承载它的 iframe 铺满
  window.addEventListener('message', (e) => {
    const d = e.data;
    if (!d || typeof d !== 'object' || typeof d.__aether !== 'string') return;
    e.stopImmediatePropagation();
    if (!e.source) return;
    let iframe = null;
    for (const f of document.querySelectorAll('iframe, frame')) {
      if (f.contentWindow === e.source) { iframe = f; break; }
    }
    if (!iframe) return;
    if (d.__aether === 'frame-enter') enterFrame(iframe);
    else if (d.__aether === 'frame-exit' && frameTarget && frameTarget.iframe === iframe) exitFrame();
  }, true);

  // 页面导航走掉 / 视频被移除时自动退出
  setInterval(() => {
    if (!active) return;
    if (!active.video.isConnected) { teardown(false); return; }
    if (active.video.controls) active.video.controls = false;
  }, 1000);

  // ---------------------------------------------------------------- 原生 → 网页命令

  function clampTime(v, t) {
    let lo = 0, hi = v.duration;
    if (!isFinite(hi)) {
      if (v.seekable && v.seekable.length) { lo = v.seekable.start(0); hi = v.seekable.end(v.seekable.length - 1); }
      else hi = t;
    }
    return Math.max(lo, Math.min(hi, t));
  }

  function seekTo(v, t, fast) {
    t = clampTime(v, t);
    if (fast && typeof v.fastSeek === 'function') v.fastSeek(t); else v.currentTime = t;
  }

  function cmd(c) {
    if (!c || !active) return;
    const v = active.video;
    switch (c.op) {
      case 'toggle':
        if (v.paused || v.ended) { const p = v.play(); if (p && p.catch) p.catch(() => {}); } else v.pause();
        break;
      case 'seekBy': seekTo(v, v.currentTime + num(c.v), false); break;
      case 'seekTo': seekTo(v, num(c.v), !!c.fast); break;
      case 'rate': v.playbackRate = num(c.v) || 1; break;
      case 'text': {
        const list = v.textTracks;
        for (let i = 0; list && i < list.length; i++) {
          if (!isSubtitle(list[i])) continue;
          list[i].mode = i === c.v ? 'showing' : 'disabled';
        }
        break;
      }
      case 'audio': {
        const list = v.audioTracks;
        for (let i = 0; list && i < list.length; i++) list[i].enabled = i === c.v;
        break;
      }
      case 'exit': teardown(true); return;
    }
    report('state');
  }

  function clear() {
    teardown(true);
    exitFrame();
  }

  Object.defineProperty(window, '__aether', {
    value: Object.freeze({ cmd, clear }), configurable: false, enumerable: false, writable: false,
  });

  // ---------------------------------------------------------------- 接管全屏 API

  const patch = (proto, name, fn) => {
    try { Object.defineProperty(proto, name, { value: fn, configurable: true, writable: true }); } catch (_) {}
  };
  const getter = (proto, name, fn) => {
    try { Object.defineProperty(proto, name, { get: fn, configurable: true }); } catch (_) {}
  };

  function pickVideo(el) {
    let vids = Array.from(el.querySelectorAll('video'));
    if (!vids.length && el.shadowRoot) vids = Array.from(el.shadowRoot.querySelectorAll('video'));
    if (!vids.length) return null;
    const score = (v) => {
      const r = v.getBoundingClientRect();
      return (v.paused ? 0 : 1e9) + (v.readyState > 0 ? 1e8 : 0) + r.width * r.height;
    };
    return vids.reduce((a, b) => (score(b) > score(a) ? b : a));
  }

  function requestFrom(el) {
    if (el instanceof HTMLVideoElement) return enter(el, null, el, 'element');
    const v = pickVideo(el);
    return v ? enter(v, el, el, 'element') : false;
  }

  patch(ElemProto, 'requestFullscreen', function (opts) {
    if (requestFrom(this)) return Promise.resolve();
    if (native.requestFullscreen) return native.requestFullscreen.call(this, opts);
    return Promise.reject(new TypeError('Fullscreen is not supported'));
  });
  for (const n of ['webkitRequestFullscreen', 'webkitRequestFullScreen']) {
    patch(ElemProto, n, function () {
      if (!requestFrom(this) && native.webkitRequestFullscreen) native.webkitRequestFullscreen.call(this);
    });
  }
  for (const n of ['webkitEnterFullscreen', 'webkitEnterFullScreen']) {
    patch(VideoProto, n, function () { enter(this, null, this, 'video'); });
  }
  for (const n of ['webkitExitFullscreen', 'webkitExitFullScreen']) {
    patch(VideoProto, n, function () {
      if (active && active.video === this) teardown(false);
      else if (native.videoExit) native.videoExit.call(this);
    });
  }
  patch(VideoProto, 'webkitSetPresentationMode', function (mode) {
    if (mode === 'fullscreen') { enter(this, null, this, 'video'); return; }
    if (active && active.video === this) teardown(false);
    if (mode !== 'inline' && native.setPresentationMode) native.setPresentationMode.call(this, mode);
  });
  getter(VideoProto, 'webkitPresentationMode', function () {
    if (active && active.video === this) return 'fullscreen';
    return native.presentationMode ? native.presentationMode.call(this) : 'inline';
  });
  getter(VideoProto, 'webkitSupportsFullscreen', () => true);
  getter(VideoProto, 'webkitDisplayingFullscreen', function () { return !!active && active.video === this; });

  patch(DocProto, 'exitFullscreen', function () { teardown(false); return Promise.resolve(); });
  for (const n of ['webkitExitFullscreen', 'webkitCancelFullScreen']) {
    patch(DocProto, n, function () { teardown(false); });
  }
  for (const n of ['fullscreenElement', 'webkitFullscreenElement', 'webkitCurrentFullScreenElement']) {
    getter(DocProto, n, () => (active ? active.reported : null));
  }
  for (const n of ['fullscreen', 'webkitIsFullScreen']) getter(DocProto, n, () => !!active);
  for (const n of ['fullscreenEnabled', 'webkitFullscreenEnabled']) getter(DocProto, n, () => true);

  // 原生内联控件上的全屏按钮会绕过 JS：系统播放器一出现就收回来改走伪全屏
  document.addEventListener('webkitbeginfullscreen', (e) => {
    if (firing) return;
    const v = e.target;
    if (!(v instanceof HTMLVideoElement)) return;
    setTimeout(() => {
      try { if (native.videoExit) native.videoExit.call(v); } catch (_) {}
      enter(v, null, v, 'video');
    }, 0);
  }, true);

  // ---------------------------------------------------------------- 强制内联播放

  // iPhone 上没有 playsinline 的视频一播放就会进系统全屏
  function inline(v) {
    try {
      if (!v.playsInline) v.playsInline = true;
      if (!v.hasAttribute('webkit-playsinline')) v.setAttribute('webkit-playsinline', '');
    } catch (_) {}
  }
  patch(MediaProto, 'play', function () {
    if (this instanceof HTMLVideoElement) inline(this);
    return native.play.apply(this, arguments);
  });
  new MutationObserver((muts) => {
    for (const m of muts) {
      for (const n of m.addedNodes) {
        if (n.nodeType !== 1) continue;
        if (n.tagName === 'VIDEO') inline(n);
        else if (n.getElementsByTagName) for (const v of n.getElementsByTagName('video')) inline(v);
      }
    }
  }).observe(document, { childList: true, subtree: true });
})();
