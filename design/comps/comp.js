// ?theme=dark switches the token set; .m elements are rendered as LaTeX.
(function () {
  var p = new URLSearchParams(location.search);
  if (p.get('theme') === 'dark') document.documentElement.setAttribute('data-theme', 'dark');
  if (p.get('bare') === '1') document.addEventListener('DOMContentLoaded', function () { document.body.classList.add('bare'); });
  document.addEventListener('DOMContentLoaded', function () {
    document.querySelectorAll('.m').forEach(function (el) {
      katex.render(el.textContent, el, { throwOnError: false });
    });
  });
})();
