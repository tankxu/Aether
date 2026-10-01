// Aether 状态栏取色（独立 content world，主框架，document end）。
// 和 iOS 26 Safari 一样：采样页面最顶部实际显示出来的颜色（通常是网站顶栏），
// 而不是只看 theme-color 或页面背景色。
(() => {
  if (window.__aetherChrome) return;
  window.__aetherChrome = true;
  const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.aetherChrome;
  if (!handler) return;

  // 任意 CSS 颜色（含 oklch() 等新写法）统一经 canvas 转成 RGBA
  const canvas = document.createElement('canvas');
  canvas.width = canvas.height = 1;
  const ctx = canvas.getContext('2d', { willReadFrequently: true });
  function toRGBA(color) {
    if (!ctx || !color) return null;
    ctx.clearRect(0, 0, 1, 1);
    ctx.fillStyle = 'rgba(0,0,0,0)';
    ctx.fillStyle = color;
    ctx.fillRect(0, 0, 1, 1);
    const d = ctx.getImageData(0, 0, 1, 1).data;
    return [d[0], d[1], d[2], d[3] / 255];
  }

  function rootColor() {
    for (const el of [document.body, document.documentElement]) {
      if (!el) continue;
      const c = toRGBA(getComputedStyle(el).backgroundColor);
      if (c && c[3] > 0.5) return c;
    }
    return [255, 255, 255, 1];
  }

  /// 从该点最上层的元素往外找第一个不透明的背景色
  function colorAt(x, y) {
    let el = document.elementFromPoint(x, y);
    while (el && el !== document.documentElement && el !== document.body) {
      const c = toRGBA(getComputedStyle(el).backgroundColor);
      if (c && c[3] > 0.5) return c;
      el = el.parentElement;
    }
    return rootColor();
  }

  let last = '';
  function sample() {
    if (!document.documentElement) return;
    const w = window.innerWidth;
    const samples = [w * 0.08, w * 0.5, w * 0.92].map((x) => colorAt(x, 1));
    // 取出现次数最多的颜色（三个点都不同就用中间那个）
    const key = (c) => c.slice(0, 3).join(',');
    const counts = {};
    for (const c of samples) counts[key(c)] = (counts[key(c)] || 0) + 1;
    let best = samples[1];
    for (const c of samples) if (counts[key(c)] > counts[key(best)]) best = c;
    const k = key(best);
    if (k === last) return;
    last = k;
    handler.postMessage({ r: best[0], g: best[1], b: best[2] });
  }

  let timer = 0;
  const schedule = () => {
    if (timer) return;
    timer = setTimeout(() => { timer = 0; try { sample(); } catch (_) {} }, 150);
  };
  sample();
  window.addEventListener('load', schedule);
  window.addEventListener('scroll', schedule, { passive: true });
  window.addEventListener('resize', schedule);
  new MutationObserver(schedule).observe(document.documentElement, {
    childList: true, subtree: true, attributes: true, attributeFilter: ['class', 'style'],
  });
})();
