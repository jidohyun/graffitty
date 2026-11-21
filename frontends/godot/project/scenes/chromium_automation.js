(function (request) {
  const action = request.action,
    p = request.params,
    key = "__graffittyAutomation";
  if (action === "snapshot") {
    const generation = p.generation;
    const state = { generation, nodes: new Map() };
    globalThis[key] = state;
    const elements = [
      ...document.querySelectorAll(
        "a,button,input,textarea,select,[role],[contenteditable=true],summary",
      ),
    ]
      .filter((el) => {
        const r = el.getBoundingClientRect(),
          s = getComputedStyle(el);
        return r.width > 0 && r.height > 0 && s.visibility !== "hidden" && s.display !== "none";
      })
      .slice(0, 500);
    return {
      url: location.href,
      title: document.title,
      generation,
      text: (document.body?.innerText || "").slice(0, 32000),
      elements: elements.map((el, i) => {
        const ref = `g${generation}:e${i + 1}`;
        state.nodes.set(ref, el);
        return {
          ref,
          tag: el.tagName.toLowerCase(),
          role: el.getAttribute("role"),
          name: (
            el.getAttribute("aria-label") ||
            el.labels?.[0]?.innerText ||
            el.innerText ||
            el.getAttribute("placeholder") ||
            ""
          ).slice(0, 300),
          type: el.type || "",
          disabled: !!el.disabled,
        };
      }),
    };
  }
  if (action === "wait")
    return {
      ready: p.selector
        ? !!document.querySelector(p.selector)
        : p.text
          ? (document.body?.innerText || "").includes(p.text)
          : document.readyState === "complete",
    };
  if (action === "scroll") {
    window.scrollBy(Number(p.x || 0), Number(p.y ?? 500));
    return { scrolled: true };
  }
  const el = globalThis[key]?.nodes.get(p.ref);
  if (!el || !el.isConnected)
    return {
      error: { code: "stale_ref", message: "Take a fresh snapshot and use its element reference" },
    };
  el.scrollIntoView({ block: "center", inline: "center" });
  el.focus();
  if (action === "locate") {
    const r = el.getBoundingClientRect();
    return { x: r.x + r.width / 2, y: r.y + r.height / 2 };
  }
  if (action === "fill") {
    if (!el.matches("input,textarea,[contenteditable=true]") || el.disabled || el.readOnly)
      return { error: { code: "invalid_element", message: "Element is not editable" } };
    if (el.isContentEditable) el.textContent = String(p.text || "");
    else
      Object.getOwnPropertyDescriptor(
        el.tagName === "TEXTAREA" ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype,
        "value",
      ).set.call(el, String(p.text || ""));
    el.dispatchEvent(new Event("input", { bubbles: true }));
    el.dispatchEvent(new Event("change", { bubbles: true }));
    return { filled: true };
  }
  return { error: { code: "unsupported", message: "Unsupported DOM operation" } };
});
