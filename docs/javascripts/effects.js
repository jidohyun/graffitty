(() => {
  let cleanup = () => {};
  function mount() {
    cleanup();
    const gallery = document.querySelector('.effects-gallery');
    if (!gallery) return;
    const controller = new AbortController();
    const {signal} = controller;
    const clips = [...gallery.querySelectorAll('video')];
    const visible = new Set();
    const button = gallery.querySelector('[data-effects-motion]');
    const header = document.querySelector('.md-header');
    const updateHeader = () => gallery.style.setProperty('--effects-header-height', `${header?.getBoundingClientRect().height || 0}px`);
    const headerObserver = new ResizeObserver(updateHeader);
    if (header) headerObserver.observe(header);
    updateHeader();
    let playing = false;
    const media = new Map();
    // Preview servers may omit byte-range support. Blob URLs remain seekable
    // on those servers too; fetch only clips that enter the viewport.
    function prepare(clip) {
      if (media.has(clip)) return;
      const state = {source: clip.getAttribute('src'), url: null};
      media.set(clip, state);
      fetch(clip.src, {signal}).then(response => {
        if (!response.ok) throw new Error(`Preview fetch failed: ${response.status}`);
        return response.blob();
      }).then(blob => {
        if (signal.aborted) return;
        const position = clip.currentTime;
        const resume = !clip.paused || (playing && visible.has(clip));
        state.url = URL.createObjectURL(blob);
        clip.addEventListener('loadedmetadata', () => {
          clip.currentTime = position;
          if (resume && visible.has(clip) && !document.hidden) clip.play().catch(() => {});
        }, {once: true, signal});
        clip.src = state.url;
        clip.load();
      }).catch(() => { media.delete(clip); });
    }
    function sync() {
      button.textContent = playing ? 'Pause previews' : 'Play previews';
      button.setAttribute('aria-pressed', String(playing));
      for (const clip of clips) {
        if (playing && visible.has(clip) && !document.hidden) clip.play().catch(() => {});
        else clip.pause();
      }
    }
    const observer = new IntersectionObserver(entries => {
      for (const {target, isIntersecting} of entries) {
        if (isIntersecting) { visible.add(target); prepare(target); }
        else { visible.delete(target); target.pause(); }
        if (playing && isIntersecting && !document.hidden) target.play().catch(() => {});
      }
    }, {threshold: 0.1});
    clips.forEach(clip => observer.observe(clip));
    sync();
    button.addEventListener('click', () => { playing = !playing; sync(); }, {signal});
    document.addEventListener('visibilitychange', sync, {signal});
    cleanup = () => {
      observer.disconnect();
      headerObserver.disconnect();
      controller.abort();
      clips.forEach(clip => clip.pause());
      for (const [clip, state] of media) {
        if (state.url) { clip.src = state.source; URL.revokeObjectURL(state.url); }
      }
    };
  }
  if (typeof document$ !== 'undefined') document$.subscribe(mount);
  else if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', mount);
  else mount();
})();
