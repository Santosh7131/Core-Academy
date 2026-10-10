/* Runs before first paint: marks the page as scripted, restores the saved theme, and decides
   whether animations play. Kept tiny and blocking on purpose, so there is no flash. */
(function () {
  var d = document.documentElement;
  d.classList.add('js');
  var on = true;
  try {
    var t = localStorage.getItem('cd-theme');
    if (t === 'dark' || t === 'light') d.setAttribute('data-theme', t);
    var m = localStorage.getItem('cd-motion');
    var reduced = window.matchMedia && matchMedia('(prefers-reduced-motion: reduce)').matches;
    on = m ? m === 'on' : !reduced;
  } catch (e) {}
  d.setAttribute('data-motion', on ? 'on' : 'off');
})();
