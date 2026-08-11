const revealTargets = [...document.querySelectorAll('[data-reveal]')];
const reducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;

function revealImmediately() {
  revealTargets.forEach(target => target.classList.add('is-visible'));
}

if (reducedMotion || !('IntersectionObserver' in window)) {
  revealImmediately();
} else {
  const heroTargets = [...document.querySelectorAll('.hero [data-reveal]')];
  heroTargets.forEach((target, index) => {
    target.style.transitionDelay = `${Math.min(index * 70, 280)}ms`;
  });

  const observer = new IntersectionObserver(entries => {
    entries.forEach(entry => {
      if (!entry.isIntersecting) return;
      entry.target.classList.add('is-visible');
      observer.unobserve(entry.target);
    });
  }, {
    threshold: 0.12,
    rootMargin: '0px 0px -8% 0px'
  });

  revealTargets.forEach(target => observer.observe(target));
}
