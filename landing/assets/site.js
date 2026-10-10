/* ChalkDeck landing page behaviour. No framework. Everything here is an enhancement: with scripts
   off, the page still reads top to bottom and every screen shows its finished state. */
(() => {
  'use strict';

  const root = document.documentElement;
  const $ = (s, c = document) => c.querySelector(s);
  const $$ = (s, c = document) => Array.from(c.querySelectorAll(s));
  const clamp = (n, a, b) => Math.min(b, Math.max(a, n));
  const store = {
    get(k) { try { return localStorage.getItem(k); } catch { return null; } },
    set(k, v) { try { localStorage.setItem(k, v); } catch { /* private window: fine */ } },
  };
  const motionOn = () => root.getAttribute('data-motion') !== 'off';
  const demos = [];

  // ---------------------------------------------------------------- theme
  const darkQuery = matchMedia('(prefers-color-scheme: dark)');
  const isDark = () => {
    const t = root.getAttribute('data-theme');
    return t ? t === 'dark' : darkQuery.matches;
  };
  function syncTheme() {
    const dark = isDark();
    for (const b of $$('[data-theme-toggle]')) {
      $('use', b).setAttribute('href', dark ? '#i-sun' : '#i-moon');
      const label = dark ? 'Switch to the light theme' : 'Switch to the dark theme';
      if (b.classList.contains('iconbtn')) b.setAttribute('aria-label', label);
      else $('span', b).textContent = dark ? 'Light theme' : 'Dark theme';
    }
  }
  for (const b of $$('[data-theme-toggle]')) {
    b.addEventListener('click', () => {
      const next = isDark() ? 'light' : 'dark';
      root.setAttribute('data-theme', next);
      store.set('cd-theme', next);
      syncTheme();
    });
  }
  if (darkQuery.addEventListener) darkQuery.addEventListener('change', syncTheme);
  syncTheme();

  // ---------------------------------------------------------------- motion switch
  function syncMotion() {
    const on = motionOn();
    for (const b of $$('[data-motion-toggle]')) {
      b.setAttribute('aria-pressed', String(!on));
      $('use', b).setAttribute('href', on ? '#i-pause' : '#i-play');
      if (b.classList.contains('iconbtn')) b.setAttribute('aria-label', on ? 'Pause animations' : 'Play animations');
      else $('span', b).textContent = on ? 'Pause animations' : 'Play animations';
    }
  }
  function setMotion(on, remember) {
    root.setAttribute('data-motion', on ? 'on' : 'off');
    if (remember) store.set('cd-motion', on ? 'on' : 'off');
    syncMotion();
    for (const d of demos) d.refresh();
    runBelt();
  }
  for (const b of $$('[data-motion-toggle]')) b.addEventListener('click', () => setMotion(!motionOn(), true));
  syncMotion();

  // ---------------------------------------------------------------- the demos
  // A demo is a screen (or a panel) that plays a short script, then starts over. Its markup says what
  // happens at each step: data-at="n" is "not yet" until step n (class "pending"), data-end="n" is
  // "still there" until step n (class "alive"), data-map lists a number per step, data-count counts
  // between two numbers, data-press taps a button. The markup holds the finished picture, so a demo
  // that is not playing simply shows its last step.
  const pad = (v, n) => (n ? String(v).padStart(n, '0') : String(v));

  class Demo {
    constructor(el) {
      this.el = el;
      this.times = (el.dataset.times || '').split(',').map(Number).filter((n) => !Number.isNaN(n));
      this.hold = Number(el.dataset.hold) || 3000;
      this.max = this.times.length;
      this.pend = $$('[data-at]', el);
      this.alive = $$('[data-end]', el);
      this.maps = $$('[data-map]', el).map((e) => ({ e, v: e.dataset.map.split(',') }));
      this.counts = $$('[data-count]', el).map((e) => ({
        e, to: Number(e.dataset.count), from: Number(e.dataset.from), ms: Number(e.dataset.ms) || 800, pad: Number(e.dataset.pad) || 0, raf: 0,
      }));
      this.presses = $$('[data-press]', el);
      this.slot = el.closest('.slot');
      this.timers = [];
      this.running = false;
      this.visible = false;
    }
    set(n, live) {
      for (const e of this.pend) e.classList.toggle('pending', n < Number(e.dataset.at));
      for (const e of this.alive) e.classList.toggle('alive', n < Number(e.dataset.end));
      for (const m of this.maps) m.e.textContent = m.v[Math.min(n, m.v.length - 1)];
      if (live) {
        for (const e of this.presses) {
          if (Number(e.dataset.press) !== n) continue;
          e.classList.add('press');
          this.later(() => e.classList.remove('press'), 220);
        }
      }
    }
    later(fn, ms) { this.timers.push(setTimeout(fn, ms)); }
    clearTimers() {
      for (const t of this.timers) clearTimeout(t);
      this.timers = [];
      for (const c of this.counts) cancelAnimationFrame(c.raf);
    }
    countsAt(fromStart) {
      for (const c of this.counts) {
        cancelAnimationFrame(c.raf);
        if (!fromStart) { c.e.textContent = pad(c.to, c.pad); continue; }
        const t0 = performance.now();
        const tick = (now) => {
          const t = clamp((now - t0) / c.ms, 0, 1);
          c.e.textContent = pad(Math.round(c.from + (c.to - c.from) * t), c.pad);
          if (t < 1) c.raf = requestAnimationFrame(tick);
        };
        c.e.textContent = pad(c.from, c.pad);
        c.raf = requestAnimationFrame(tick);
      }
    }
    /** Shows the finished picture and stops. */
    finish() {
      this.clearTimers();
      this.running = false;
      this.set(this.max);
      this.countsAt(false);
      this.el.classList.remove('fading');
      this.el.classList.add('ready');
    }
    begin() {
      this.clearTimers();
      this.set(0);
      for (const c of this.counts) c.e.textContent = pad(c.from, c.pad);
      this.el.classList.add('ready');
      requestAnimationFrame(() => {
        if (!this.running) return;
        this.el.classList.remove('fading');
        this.countsAt(true);
        this.times.forEach((t, i) => this.later(() => this.set(i + 1, true), t));
        const end = (this.times[this.max - 1] || 0) + this.hold;
        this.later(() => {
          this.el.classList.add('fading');
          this.later(() => this.begin(), 460);
        }, end);
      });
    }
    start() {
      if (this.running) return;
      this.running = true;
      if (this.el.classList.contains('ready')) {
        this.el.classList.add('fading');
        this.later(() => this.begin(), 380);
      } else {
        this.begin();
      }
    }
    allowed() {
      return !this.slot || this.slot.classList.contains('active');
    }
    refresh() {
      const should = this.visible && motionOn() && !document.hidden && this.allowed();
      if (should) this.start();
      else if (this.running || !this.el.classList.contains('ready')) this.finish();
      else this.finish();
    }
  }

  // Copies of screens that are used twice (the story reuses two of the hero's).
  for (const slot of $$('.slot[data-clone]')) {
    const src = $(slot.dataset.clone);
    if (!src) continue;
    const copy = src.cloneNode(true);
    copy.removeAttribute('id');
    slot.appendChild(copy);
  }
  // On narrow screens each step carries its own phone instead of the pinned one.
  for (const step of $$('.step')) {
    const slot = $(`.stage .slot[data-screen="${step.dataset.screen}"]`);
    const holder = $('.step-phone', step);
    const scr = slot && $('.scr', slot);
    if (!holder || !scr) continue;
    const copy = scr.cloneNode(true);
    copy.removeAttribute('id');
    const phone = document.createElement('div');
    phone.className = 'phone';
    const screen = document.createElement('div');
    screen.className = 'phone-screen';
    phone.appendChild(screen);
    holder.replaceChildren(phone);
    screen.appendChild(copy);
  }

  const demoIO = new IntersectionObserver((entries) => {
    for (const en of entries) {
      const d = en.target.__demo;
      d.visible = en.isIntersecting;
      d.refresh();
    }
  }, { threshold: 0.25 });
  for (const el of $$('[data-demo]')) {
    const d = new Demo(el);
    el.__demo = d;
    demos.push(d);
    demoIO.observe(el);
  }
  document.addEventListener('visibilitychange', () => demos.forEach((d) => d.refresh()));

  // ---------------------------------------------------------------- the pinned story
  const steps = $$('.step');
  const slots = $$('.stage .slot');
  const dots = $$('.stage-dots li');
  const stageDemos = demos.filter((d) => d.slot);
  function activate(i) {
    steps.forEach((s, j) => s.classList.toggle('active', j === i));
    slots.forEach((s) => s.classList.toggle('active', s.dataset.screen === steps[i].dataset.screen));
    dots.forEach((d, j) => d.classList.toggle('on', j === i));
    stageDemos.forEach((d) => d.refresh());
  }
  if (steps.length) {
    activate(0);
    const stepIO = new IntersectionObserver((entries) => {
      for (const en of entries) if (en.isIntersecting) activate(steps.indexOf(en.target));
    }, { rootMargin: '-38% 0px -44% 0px' });
    steps.forEach((s) => stepIO.observe(s));
  }
  const stepsEl = $('#steps');

  // ---------------------------------------------------------------- scroll: progress line, nav
  const nav = $('#nav');
  let ticking = false;
  function onScroll() {
    ticking = false;
    if (nav) nav.classList.toggle('scrolled', scrollY > 8);
    if (stepsEl) {
      const r = stepsEl.getBoundingClientRect();
      stepsEl.style.setProperty('--p', clamp((innerHeight * 0.52 - r.top) / r.height, 0, 1).toFixed(3));
    }
  }
  addEventListener('scroll', () => { if (!ticking) { ticking = true; requestAnimationFrame(onScroll); } }, { passive: true });
  addEventListener('resize', onScroll);
  onScroll();

  const navLinks = $$('.links a');
  const spy = new IntersectionObserver((entries) => {
    for (const en of entries) {
      if (!en.isIntersecting) continue;
      for (const a of navLinks) a.classList.toggle('on', a.getAttribute('href') === `#${en.target.id}`);
    }
  }, { rootMargin: '-42% 0px -52% 0px' });
  for (const id of ['how', 'ai', 'tutors', 'students', 'download', 'faq']) { const s = document.getElementById(id); if (s) spy.observe(s); }

  // ---------------------------------------------------------------- reveal on scroll
  const reveal = new IntersectionObserver((entries) => {
    for (const en of entries) {
      if (!en.isIntersecting) continue;
      en.target.classList.add('in');
      reveal.unobserve(en.target);
    }
  }, { threshold: 0.12, rootMargin: '0px 0px -6% 0px' });
  for (const el of $$('[data-r]')) reveal.observe(el);

  // ---------------------------------------------------------------- belt
  const track = $('.belt-track');
  const row = track && $('.belt-row', track);
  if (row) {
    const copy = row.cloneNode(true);
    copy.setAttribute('aria-hidden', 'true');
    track.appendChild(copy);
  }
  function runBelt() { if (track) track.classList.toggle('run', motionOn()); }
  runBelt();

  // ---------------------------------------------------------------- hero tilt
  const hero = $('.hero');
  const art = $('#heroArt');
  if (hero && art && matchMedia('(pointer: fine)').matches) {
    let raf = 0;
    hero.addEventListener('pointermove', (e) => {
      if (!motionOn()) return;
      cancelAnimationFrame(raf);
      raf = requestAnimationFrame(() => {
        const r = art.getBoundingClientRect();
        const x = clamp((e.clientX - (r.left + r.width / 2)) / (innerWidth / 2), -1, 1);
        const y = clamp((e.clientY - (r.top + r.height / 2)) / (innerHeight / 2), -1, 1);
        art.style.setProperty('--ry', `${(x * 7).toFixed(2)}deg`);
        art.style.setProperty('--rx', `${(-y * 5).toFixed(2)}deg`);
      });
    });
    hero.addEventListener('pointerleave', () => { art.style.setProperty('--ry', '0deg'); art.style.setProperty('--rx', '0deg'); });
  }

  // ---------------------------------------------------------------- a soft light that follows the pointer over the feature cards
  const grid = $('.grid');
  if (grid && matchMedia('(hover: hover) and (pointer: fine)').matches) {
    grid.addEventListener('pointermove', (e) => {
      const cell = e.target.closest ? e.target.closest('.cell') : null;
      if (!cell || !motionOn()) return;
      const r = cell.getBoundingClientRect();
      cell.style.setProperty('--mx', `${(e.clientX - r.left).toFixed(0)}px`);
      cell.style.setProperty('--my', `${(e.clientY - r.top).toFixed(0)}px`);
    });
  }

  // ---------------------------------------------------------------- FAQ
  for (const btn of $$('.qa-item > button')) {
    btn.addEventListener('click', () => {
      const item = btn.parentElement;
      const open = !item.classList.contains('open');
      item.classList.toggle('open', open);
      btn.setAttribute('aria-expanded', String(open));
    });
  }

  // ---------------------------------------------------------------- the latest release
  const apkLinks = $$('[data-apk]');
  const first = apkLinks[0] && apkLinks[0].getAttribute('href');
  const repo = first && (first.match(/github\.com\/([^/]+\/[^/]+)\/releases/) || [])[1];
  const meta = (k) => $(`[data-meta="${k}"]`);

  async function loadRelease() {
    if (!repo) return;
    let data = null;
    try { data = JSON.parse(sessionStorage.getItem('cd-release') || 'null'); } catch { data = null; }
    if (!data) {
      const res = await fetch(`https://api.github.com/repos/${repo}/releases/latest`, { headers: { Accept: 'application/vnd.github+json' } });
      if (!res.ok) throw new Error(`GitHub answered ${res.status}`);
      data = await res.json();
      try { sessionStorage.setItem('cd-release', JSON.stringify(data)); } catch { /* fine */ }
    }
    const apk = (data.assets || []).find((a) => /\.apk$/i.test(a.name));
    if (!apk) throw new Error('No APK in the latest release');
    const version = String(data.tag_name || '').replace(/^v/i, '');
    const mb = `${(apk.size / 1e6).toFixed(1)} MB`;
    const when = data.published_at ? new Date(data.published_at).toLocaleDateString('en-GB', { day: 'numeric', month: 'short', year: 'numeric' }) : '';
    for (const a of apkLinks) {
      a.href = apk.browser_download_url;
      const small = $('[data-apk-meta]', a);
      if (small) small.textContent = `${version ? `v${version} · ` : ''}${mb}`;
    }
    if (meta('version')) meta('version').textContent = version || '-';
    if (meta('size')) meta('size').textContent = mb;
    if (meta('date')) meta('date').textContent = when || '-';
    $('#apkMeta').hidden = false;
    const sha = String(apk.digest || '').replace(/^sha256:/i, '');
    if (sha && meta('sha')) {
      meta('sha').textContent = sha;
      $('#apkHash').hidden = false;
    }
  }
  loadRelease().catch(() => { const f = $('.fine-fallback'); if (f) f.hidden = false; });

  const copyBtn = $('[data-copy]');
  if (copyBtn) {
    copyBtn.addEventListener('click', async () => {
      const text = meta('sha') ? meta('sha').textContent : '';
      if (!text) return;
      let ok = false;
      try { await navigator.clipboard.writeText(text); ok = true; } catch {
        const r = document.createRange();
        r.selectNodeContents(meta('sha'));
        const s = getSelection();
        s.removeAllRanges();
        s.addRange(r);
      }
      const label = $('span', copyBtn);
      label.textContent = ok ? 'Copied' : 'Selected';
      setTimeout(() => { label.textContent = 'Copy'; }, 1800);
    });
  }

  // ---------------------------------------------------------------- QR code for desktop visitors
  const qrBox = $('#qrBox');
  if (qrBox && window.qrcode && /^https?:$/.test(location.protocol) && matchMedia('(min-width: 900px) and (hover: hover) and (pointer: fine)').matches) {
    try {
      const qr = window.qrcode(0, 'M');
      qr.addData(location.origin + location.pathname);
      qr.make();
      const svg = new DOMParser().parseFromString(qr.createSvgTag({ cellSize: 4, margin: 0, scalable: true }), 'image/svg+xml').documentElement;
      qrBox.replaceChildren(document.importNode(svg, true));
      $('#qr').hidden = false;
    } catch { /* no code, no harm */ }
  }
})();
