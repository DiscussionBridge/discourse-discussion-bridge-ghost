(() => {
  const root = document.documentElement;
  if (root.hasAttribute("data-discussionbridge-labels-ready")) return;
  root.setAttribute("data-discussionbridge-labels-ready", "");
  const attribute = "data-discussionbridge-forum-label";
  const selector = `a[${attribute}]`;
  const links = new Map();
  let frame;
  const resize = typeof ResizeObserver === "function" ? new ResizeObserver(schedule) : null;

  function schedule() {
    if (frame === undefined) frame = requestAnimationFrame(refresh);
  }

  function refresh() {
    frame = undefined;
    for (const [link, { header, probe }] of links) {
      if (link.isConnected && link.parentElement === header) continue;
      resize?.unobserve(header);
      resize?.unobserve(probe);
      links.delete(link);
    }
    for (const link of document.querySelectorAll(selector)) {
      const header = link.parentElement;
      if (!header) continue;
      let state = links.get(link);
      if (!state) {
        const fallback = link.textContent.trim();
        const text = document.createTextNode(fallback);
        const probe = document.createElement("span");
        probe.setAttribute("aria-hidden", "true");
        probe.style.cssText = "position:fixed;visibility:hidden;pointer-events:none;white-space:nowrap;inline-size:max-content;max-inline-size:none;font:inherit;letter-spacing:inherit;text-transform:inherit";
        link.replaceChildren(text, probe);
        link.style.whiteSpace = "nowrap";
        header.style.flexWrap = "wrap";
        state = { header, fallback, text, probe };
        links.set(link, state);
        resize?.observe(header);
        resize?.observe(probe);
      }
      const { fallback, text, probe } = state;
      const preferred = link.getAttribute(attribute)?.trim() || "";
      if (probe.textContent !== preferred) probe.textContent = preferred;
      const row = getComputedStyle(header);
      const anchor = getComputedStyle(link);
      const pixels = value => parseFloat(value) || 0;
      const available = header.clientWidth - pixels(row.paddingLeft) - pixels(row.paddingRight)
        - pixels(anchor.paddingLeft) - pixels(anchor.paddingRight)
        - pixels(anchor.borderLeftWidth) - pixels(anchor.borderRightWidth);
      const width = probe.getBoundingClientRect().width;
      const label = preferred && width > 0 && Math.ceil(width) <= available ? preferred : fallback;
      if (text.data !== label) text.data = label;
    }
  }

  new MutationObserver(schedule).observe(root, { subtree: true, childList: true, attributes: true, attributeFilter: [attribute] });
  window.addEventListener("resize", schedule);
  schedule();
})();
