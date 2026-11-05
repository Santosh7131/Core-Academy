/* Core Academy download page: two small jobs, and the page works without either.
   1. Show the size of the newest app file on the Download button.
   2. On a computer, show a QR code that opens this page on a phone. */
(() => {
  'use strict';

  // ---------------------------------------------------------------- size of the newest app file
  const button = document.querySelector('[data-apk]');
  const label = button && button.querySelector('[data-apk-size]');
  const repo = button && (button.getAttribute('href').match(/github\.com\/([^/]+\/[^/]+)\/releases/) || [])[1];

  async function showSize() {
    if (!repo || !label) return;
    let size = 0;
    try { size = Number(sessionStorage.getItem('ca-apk-size')) || 0; } catch { size = 0; }
    if (!size) {
      const res = await fetch(`https://api.github.com/repos/${repo}/releases/latest`, { headers: { Accept: 'application/vnd.github+json' } });
      if (!res.ok) throw new Error(`GitHub answered ${res.status}`);
      const release = await res.json();
      const apk = (release.assets || []).find((a) => a.name === 'core-academy.apk') || (release.assets || []).find((a) => /\.apk$/i.test(a.name));
      if (!apk) throw new Error('No app file in the latest release');
      size = apk.size;
      try { sessionStorage.setItem('ca-apk-size', String(size)); } catch { /* fine */ }
    }
    label.textContent = `${(size / 1e6).toFixed(1)} MB`;
  }
  showSize().catch(() => { /* the button still downloads, it just shows no size */ });

  // ---------------------------------------------------------------- QR code for visitors on a computer
  const box = document.getElementById('qrBox');
  const card = document.getElementById('qr');
  const onComputer = matchMedia('(min-width: 900px) and (hover: hover) and (pointer: fine)').matches;
  if (box && card && onComputer && window.qrcode && /^https?:$/.test(location.protocol)) {
    try {
      const qr = window.qrcode(0, 'M');
      qr.addData(location.origin + location.pathname);
      qr.make();
      const svg = new DOMParser().parseFromString(qr.createSvgTag({ cellSize: 4, margin: 0, scalable: true }), 'image/svg+xml').documentElement;
      box.replaceChildren(document.importNode(svg, true));
      card.hidden = false;
    } catch { /* no code, no harm */ }
  }
})();
