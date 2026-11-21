(() => {
  const feedback = new WeakMap();
  document.addEventListener('click', async event => {
    const button = event.target.closest('[data-copy-settings], .md-code__button[data-md-type="copy"]');
    if (!button) return;
    const target = button.hasAttribute('data-copy-settings')
      ? button.closest('.effect-code').querySelector('code')
      : document.querySelector(button.dataset.clipboardTarget);
    if (!target) return;
    // Handle both generated docs buttons and gallery buttons in one place.
    event.preventDefault();
    event.stopImmediatePropagation();
    let state = feedback.get(button);
    if (!state) {
      state = {label: button.getAttribute('aria-label'), title: button.title};
      feedback.set(button, state);
    }
    clearTimeout(state.timer);
    try {
      await navigator.clipboard.writeText(target.textContent);
      button.dataset.copied = 'true';
      button.setAttribute('aria-label', 'Copied');
      button.title = 'Copied';
    } catch {
      button.setAttribute('aria-label', 'Copy failed; select text to copy');
      button.title = 'Copy failed; select text to copy';
    }
    state.timer = setTimeout(() => {
      delete button.dataset.copied;
      if (state.label === null) button.removeAttribute('aria-label');
      else button.setAttribute('aria-label', state.label);
      button.title = state.title;
    }, 1500);
  }, true);
})();
