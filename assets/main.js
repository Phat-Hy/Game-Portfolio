/* Small progressive enhancements only — the page is fully readable without JS. */
(function () {
  'use strict';

  // sticky nav gets a hairline once the page scrolls
  var nav = document.getElementById('nav');
  if (nav) {
    var onScroll = function () {
      nav.classList.toggle('is-stuck', window.scrollY > 8);
    };
    onScroll();
    window.addEventListener('scroll', onScroll, { passive: true });
  }

  // keep the footer year honest
  var year = document.getElementById('year');
  if (year) year.textContent = String(new Date().getFullYear());

  // hide the broken-image icon if a remote screenshot is unavailable
  Array.prototype.forEach.call(document.images, function (img) {
    img.addEventListener('error', function () {
      img.style.visibility = 'hidden';
      var box = img.parentElement;
      if (box) box.style.minHeight = '160px';
    }, { once: true });
  });
})();
