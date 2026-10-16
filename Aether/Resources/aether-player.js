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
  const log = (msg) => post({ type: 'log', msg: String(msg) });
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
    exitFullscreen: DocProto.exitFullscreen || DocProto.webkitExitFullscreen,
    fullscreenElement: (Object.getOwnPropertyDescriptor(DocProto, 'fullscreenElement') ||
      Object.getOwnPropertyDescriptor(DocProto, 'webkitFullscreenElement') || {}).get,
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
      pip: supportsPiP(v), air: airplayAvailable, wireless: !!v.webkitCurrentPlaybackTargetIsWireless,
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

  // ---------------------------------------------------------------- 画中画 / AirPlay

  let airplayAvailable = false;
  function onAirplayAvailability(e) {
    airplayAvailable = e.availability === 'available';
    report('state');
  }

  function supportsPiP(v) {
    if (!native.setPresentationMode) return false;
    try { return typeof v.webkitSupportsPresentationMode !== 'function' || v.webkitSupportsPresentationMode('picture-in-picture'); }
    catch (_) { return false; }
  }

  // 从播放器进入画中画的视频：画中画结束（点“还原”或关闭）时回到 Aether 全屏
  let pipVideo = null;
  function onPresentationModeChanged(e) {
    const v = e.target;
    if (v !== pipVideo) return;
    const mode = native.presentationMode ? native.presentationMode.call(v) : 'inline';
    log('presentationmodechanged ' + mode + ' hidden=' + document.hidden);
    if (mode === 'picture-in-picture') return;
    pipVideo = null;
    v.removeEventListener('webkitpresentationmodechanged', onPresentationModeChanged);
    if (mode === 'inline' && v.isConnected) enter(v, null, v, 'video');
  }

  function startPiP(v) {
    try { v.disablePictureInPicture = false; v.removeAttribute('disablepictureinpicture'); } catch (_) {}
    pipVideo = v;
    v.addEventListener('webkitpresentationmodechanged', onPresentationModeChanged);
    log('startPiP paused=' + v.paused + ' ready=' + v.readyState + ' hidden=' + document.hidden + ' src=' + (v.currentSrc || '').slice(0, 60));
    teardown(false);   // 先还原页面布局（原生层随之关闭），再交给系统画中画
    try { native.setPresentationMode.call(v, 'picture-in-picture'); }
    catch (err) { log('setPresentationMode threw ' + err); pipVideo = null; enter(v, null, v, 'video'); }
    setTimeout(() => log('after 300ms mode=' + (native.presentationMode ? native.presentationMode.call(v) : '?')), 300);
  }

  // ---------------------------------------------------------------- WebKit 元素全屏（只为自动画中画）
  //
  // 系统只在“元素全屏里有正在播放的视频”时，才会在离开 App 时自动进入画中画。
  // 所以伪全屏之外再让 WebKit 进入真正的元素全屏：画面和控制层仍然是 Aether 自己的。
  // 全屏的是视频的容器而不是 <video> 本身——直接全屏 <video> 在 iPhone 上会变成系统播放器。

  function nativeFullscreenElement() {
    try { return native.fullscreenElement ? native.fullscreenElement.call(document) : null; } catch (_) { return null; }
  }

  // 注意：WebKit 对 YouTube 手机版有兼容处理，iPhone 上页面里拿不到 requestFullscreen，
  // 所以 YouTube 进不了元素全屏，系统也就不会在离开 App 时自动画中画（手动画中画按钮不受影响）
  function enterNativeFullscreen() {
    if (!active || nativeFullscreenElement()) return;
    const request = native.requestFullscreen || native.webkitRequestFullscreen;
    if (!request) return;
    const target = document.documentElement;
    try {
      const p = request.call(target);
      if (p && p.then) p.then(() => log('native fullscreen ok'), (err) => log('native fullscreen failed ' + err));
    } catch (err) { log('native fullscreen threw ' + err); }
  }

  function leaveNativeFullscreen(saved) {
    if (!nativeFullscreenElement() || !native.exitFullscreen) return;
    // WebKit 退出全屏时会恢复它自己记下的滚动位置，等它完成后再回到进入前的位置
    const restoreScroll = () => { if (saved) window.scrollTo(saved.x, saved.y); };
    try {
      const p = native.exitFullscreen.call(document);
      if (p && p.then) p.then(() => { restoreScroll(); setTimeout(restoreScroll, 300); }, () => {});
    } catch (_) {}
  }


  function bindVideo(v, on) {
    const m = on ? 'addEventListener' : 'removeEventListener';
    for (const t of MEDIA_EVENTS) v[m](t, onMediaEvent);
    if (window.WebKitPlaybackTargetAvailabilityEvent) {
      v[m]('webkitplaybacktargetavailabilitychanged', onAirplayAvailability);
      v[m]('webkitcurrentplaybacktargetiswirelesschanged', onMediaEvent);
    }
    for (const list of [v.textTracks, v.audioTracks]) {
      if (list) for (const t of TRACK_EVENTS) list[m](t, onMediaEvent);
    }
  }

  // ---------------------------------------------------------------- 只给网页的全屏事件
  //
  // webkitbeginfullscreen / webkitendfullscreen 只能交给网页自己的监听器：真的在 <video> 上派发，
  // WebKit 内部的媒体控件也会收到，它把模拟的 end 当成真的退出全屏，视频图层就没了（退出后画面空白）。
  // 所以记下网页注册的这两类监听器，退出 / 进入时按捕获 → 目标 → 冒泡的顺序直接调用。

  const PAGE_ONLY_EVENTS = new Set(['webkitbeginfullscreen', 'webkitendfullscreen']);
  const pageListeners = new WeakMap();   // target -> [{ type, fn, capture, once }]
  const nativeAdd = EventTarget.prototype.addEventListener;
  const nativeRemove = EventTarget.prototype.removeEventListener;
  const captureOf = (o) => (typeof o === 'boolean' ? o : !!(o && o.capture));
  try {
    Object.defineProperty(EventTarget.prototype, 'addEventListener', {
      configurable: true, writable: true,
      value: function (type, fn, opts) {
        if (fn && PAGE_ONLY_EVENTS.has(type)) {
          const list = pageListeners.get(this) || [];
          const capture = captureOf(opts);
          if (!list.some((l) => l.type === type && l.fn === fn && l.capture === capture)) {
            list.push({ type, fn, capture, once: !!(opts && opts.once) });
            pageListeners.set(this, list);
          }
        }
        return nativeAdd.call(this, type, fn, opts);
      },
    });
    Object.defineProperty(EventTarget.prototype, 'removeEventListener', {
      configurable: true, writable: true,
      value: function (type, fn, opts) {
        const list = pageListeners.get(this);
        if (list && PAGE_ONLY_EVENTS.has(type)) {
          const capture = captureOf(opts);
          const i = list.findIndex((l) => l.type === type && l.fn === fn && l.capture === capture);
          if (i >= 0) list.splice(i, 1);
        }
        return nativeRemove.call(this, type, fn, opts);
      },
    });
  } catch (_) {}

  function deliverToPage(el, type) {
    const path = [];
    for (let n = el; n; n = n.parentNode || (n instanceof ShadowRoot ? n.host : null)) path.push(n);
    path.push(window);
    const ev = new Event(type, { bubbles: true });
    let current = null, phase = 0, stopped = false;
    try {
      Object.defineProperty(ev, 'target', { value: el });
      Object.defineProperty(ev, 'srcElement', { value: el });
      Object.defineProperty(ev, 'currentTarget', { get: () => current });
      Object.defineProperty(ev, 'eventPhase', { get: () => phase });
      ev.stopPropagation = () => { stopped = true; };
      ev.stopImmediatePropagation = () => { stopped = true; };
    } catch (_) { return; }
    const call = (node, capture) => {
      current = node;
      const list = (pageListeners.get(node) || []).filter((l) => l.type === type && l.capture === capture);
      for (const l of list) {
        if (l.once) nativeRemove.call(node, type, l.fn, l.capture);
        try { typeof l.fn === 'function' ? l.fn.call(node, ev) : l.fn.handleEvent(ev); } catch (err) { setTimeout(() => { throw err; }); }
        if (l.once) { const all = pageListeners.get(node); const i = all ? all.indexOf(l) : -1; if (i >= 0) all.splice(i, 1); }
      }
      const handler = !capture && node['on' + type];
      if (typeof handler === 'function') { try { handler.call(node, ev); } catch (_) {} }
    };
    phase = 1;
    for (let i = path.length - 1; i > 0 && !stopped; i--) call(path[i], true);
    phase = 2;
    if (!stopped) { call(el, true); call(el, false); }
    phase = 3;
    for (let i = 1; i < path.length && !stopped; i++) call(path[i], false);
    current = null; phase = 0;
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
        if (via === 'video') deliverToPage(el, entering ? 'webkitbeginfullscreen' : 'webkitendfullscreen');
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

    forEachAncestor(video, (a) => {
      applyProps(a, ANCESTOR_PROPS, restores);
      // 外层播放器容器的 overflow:hidden 仍会裁掉合成后的视频图层（YouTube 全屏时上下被切），
      // body 例外：滚动由 html 的 overflow:hidden 锁住
      if (a !== document.body) applyProps(a, { overflow: 'visible', clip: 'auto' }, restores);
    });
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
    leaveNativeFullscreen(a.saved);
    bindVideo(a.video, false);
    runRestores(a.restores);
    a.video.controls = a.saved.controls;
    syncRootClass();
    restoreScrollAfterExit(a.saved);
    if (!fromNative) post({ type: 'exit' });
    if (!isTop) parent.postMessage({ __aether: 'frame-exit' }, '*');
    fireChange(a.reported, false, a.via);
  }

  // 退出后屏幕通常还要转回竖屏：页面重新排版时 WebKit 会调整滚动位置，
  // 退出后 2 秒内每次尺寸变化都回到进入前的位置
  function restoreScrollAfterExit(saved) {
    const restore = () => window.scrollTo(saved.x, saved.y);
    restore();
    const onResize = () => { restore(); setTimeout(restore, 120); };
    window.addEventListener('resize', onResize);
    setTimeout(() => window.removeEventListener('resize', onResize), 2000);
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
      case 'pip':
        if (supportsPiP(v)) startPiP(v);
        else log('pip unsupported pipEnabled=' + document.pictureInPictureEnabled + ' disable=' + v.disablePictureInPicture);
        return;
      case 'airplay':
        if (typeof v.webkitShowPlaybackTargetPicker === 'function') v.webkitShowPlaybackTargetPicker();
        return;
      case 'exit': teardown(true); return;
    }
    report('state');
  }

  function clear() {
    teardown(true);
    exitFrame();
  }

  Object.defineProperty(window, '__aether', {
    value: Object.freeze({ cmd, clear, enterNativeFullscreen, enterMedia: () => enterMediaPage() }), configurable: false, enumerable: false, writable: false,
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

  // 和 Safari 一样：网页只能在用户刚点过 / 按过键时进入全屏。
  // 否则 YouTube 手机版一横屏就自动请求全屏（Safari 会拒绝），我们却照单全收、直接弹出播放器。
  const DEBUG_ENTRY = false;
  function userInitiated() {
    if (DEBUG_ENTRY && (location.hash.includes('aether-debug') || window.name === 'aether-debug')) return true;
    const ua = navigator.userActivation;
    return !ua || ua.isActive;
  }

  function requestFrom(el) {
    if (el instanceof HTMLVideoElement) return enter(el, null, el, 'element');
    const v = pickVideo(el);
    return v ? enter(v, el, el, 'element') : false;
  }

  patch(ElemProto, 'requestFullscreen', function (opts) {
    if (!userInitiated()) return Promise.reject(new TypeError('Fullscreen request requires a user gesture'));
    if (requestFrom(this)) return Promise.resolve();
    if (native.requestFullscreen) return native.requestFullscreen.call(this, opts);
    return Promise.reject(new TypeError('Fullscreen is not supported'));
  });
  for (const n of ['webkitRequestFullscreen', 'webkitRequestFullScreen']) {
    patch(ElemProto, n, function () {
      if (!userInitiated()) return;
      if (!requestFrom(this) && native.webkitRequestFullscreen) native.webkitRequestFullscreen.call(this);
    });
  }
  for (const n of ['webkitEnterFullscreen', 'webkitEnterFullScreen']) {
    patch(VideoProto, n, function () {
      // Safari 在没有用户手势时抛 InvalidStateError，网页代码本来就会处理
      if (!userInitiated()) throw new DOMException('The object is in an invalid state.', 'InvalidStateError');
      enter(this, null, this, 'video');
    });
  }
  for (const n of ['webkitExitFullscreen', 'webkitExitFullScreen']) {
    patch(VideoProto, n, function () {
      if (active && active.video === this) teardown(false);
      else if (native.videoExit) native.videoExit.call(this);
    });
  }
  patch(VideoProto, 'webkitSetPresentationMode', function (mode) {
    if (mode === 'fullscreen') { if (userInitiated()) enter(this, null, this, 'video'); return; }
    const wasOurs = !!active && active.video === this;
    if (wasOurs) teardown(false);
    // 退出伪全屏只需还原；其他情况（进入画中画、从画中画回到内联）交给 WebKit
    if (!(wasOurs && mode === 'inline') && native.setPresentationMode) native.setPresentationMode.call(this, mode);
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
    if (firing || !e.isTrusted) return;
    const v = e.target;
    if (!(v instanceof HTMLVideoElement)) return;
    setTimeout(() => {
      try { if (native.videoExit) native.videoExit.call(v); } catch (_) {}
      enter(v, null, v, 'video');
    }, 0);
  }, true);

  // ---------------------------------------------------------------- 直接打开的视频文件

  // 直接打开 mp4 等视频时，原生层用 Aether 的页面（<meta name="aether-media" content="video">）代替
  // WebKit 的媒体文档；页面一加载就进入 Aether 播放器（浏览器自己的行为，不需要用户手势）
  let enterMediaPage = () => {};
  if (isTop) {
    const takeOver = () => {
      const meta = document.querySelector('meta[name="aether-media"]');
      const v = meta && meta.content === 'video' && document.querySelector('video');
      if (!v || active) return;
      enter(v, null, v, 'video');
      const p = native.play.call(v);
      if (p && p.catch) p.catch(() => {});   // 有声视频自动播放可能被拦，停在暂停状态，用控制列播放
    };
    enterMediaPage = takeOver;
    if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', takeOver, { once: true });
    else takeOver();
  }

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
