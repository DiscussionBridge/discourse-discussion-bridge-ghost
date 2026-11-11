(() => {
  const script = document.currentScript;
  if (!script || location.protocol !== "https:") {
    return;
  }

  const endpoint = new URL("comments.json", script.src);
  if (endpoint.protocol !== "https:") {
    return;
  }
  const themeMode = script.getAttribute("data-discussion-bridge-ghost-mode") === "interactive"
    ? "interactive" : "simple";
  if (themeMode !== "interactive" && document.querySelector('script[data-discussion-bridge-ghost-mode="interactive"]')) {
    return;
  }
  endpoint.searchParams.set("url", location.origin + location.pathname);

  async function loadComments() {
    const scriptArticle = script.closest("article");
    const article = scriptArticle || document.querySelector("main article, article");
    // Existing publications use this marker for their saved discussion link.
    const managedDiscussions = document.querySelectorAll("[data-db-owner] > [data-db-mode='simple']");
    for (const block of managedDiscussions) {
      // Older publications may still contain a saved reply snapshot. Keep only the discussion link.
      const saved = block.querySelectorAll(":scope > a[data-db-discussion='true']");
      for (const link of saved) link.textContent = "Open in forum";
      block.replaceChildren(...saved);
    }
    let target = managedDiscussions[0] || document.querySelector("[data-discussion-bridge-ghost-comments]");
    if (!target && !article) {
      return;
    }

    try {
      const response = await fetch(endpoint, { credentials: "omit", redirect: "error" });
      if (!response.ok) {
        return;
      }
      const comments = await response.json();
      const mode = comments.presentation_mode ?? themeMode;
      if (!["simple", "full", "interactive"].includes(mode)) return;
      if (mode !== "simple" && (!Number.isSafeInteger(comments.topic_id) || comments.topic_id < 1)) return;
      const topic = new URL(comments.topic_path, endpoint.origin);
      if (topic.origin !== endpoint.origin || !Array.isArray(comments.replies)) {
        return;
      }

      if (!target) {
        target = document.createElement("section");
        if (scriptArticle) {
          script.before(target);
        } else {
          article.append(target);
        }
      }
      const header = document.createElement("div");
      header.className = "discussionbridge-discussion__header";
      Object.assign(header.style, {
        display: "flex",
        flexWrap: "wrap",
        alignItems: "baseline",
        justifyContent: "space-between",
        gap: "0.5em 1em",
        marginBlockEnd: "1em",
      });
      const heading = document.createElement("h2");
      heading.textContent = comments.title;
      heading.style.margin = "0";
      const link = document.createElement("a");
      link.href = topic.href;
      link.textContent = comments.discussion;
      if (typeof comments.forum_name === "string" && comments.forum_name) {
        link.setAttribute("data-discussionbridge-forum-label", `Open in ${comments.forum_name}`);
      }
      link.style.fontSize = "0.875em";
      header.append(heading, link);
      const content = mode === "simple" ? replyList(comments) : discussionFrame(comments, mode);
      target.replaceChildren(header, content);
      if (comments.credit_enabled !== false) target.append(bridgeCredit());
      target.setAttribute("data-discussion-bridge-ghost-comments", "loaded");
    } catch {
      // The saved discussion link remains available while live replies are unavailable.
    }
  }

  function bridgeCredit() {
    const credit = document.createElement("footer");
    credit.className = "discussionbridge-credit";
    credit.setAttribute("aria-label", "DiscussionBridge credit");
    const brand = document.createElement("a");
    brand.className = "discussionbridge-credit__brand";
    brand.href = "https://discussionbridge.dev/";
    brand.textContent = "DiscussionBridge";
    credit.append("Connected by ", brand);
    if (!document.querySelector("style[data-discussionbridge-credit-style]")) {
      const creditStyles = document.createElement("style");
      creditStyles.setAttribute("data-discussionbridge-credit-style", "");
      if (script.nonce) creditStyles.nonce = script.nonce;
      creditStyles.textContent = "/* Customize credit colors with the inherited --discussionbridge-credit-* properties. */\n:is(footer, p).discussionbridge-credit {\n  margin: 0.45rem 0 0;\n  color: var(--sl-color-gray-3, inherit);\n  text-align: center;\n  font-size: max(0.875rem, 14px);\n  font-weight: 600;\n  line-height: 1.4;\n}\n\n.discussionbridge-credit > a:any-link {\n  position: relative;\n  padding-inline: 0.22em;\n  border-radius: 0.2em;\n  color: var(--discussionbridge-credit-link-color, inherit);\n  background-color: var(--discussionbridge-credit-background, transparent);\n  text-decoration: none;\n  transition: color 160ms ease, background-color 160ms ease;\n}\n\n.discussionbridge-credit > a::after {\n  position: absolute;\n  inset-inline: 0.22em;\n  bottom: -0.12em;\n  height: 1px;\n  background: currentColor;\n  content: \"\";\n  transform: scaleX(0);\n  transform-origin: center;\n  transition: transform 180ms ease;\n}\n\n.discussionbridge-credit > a:is(:hover, :focus-visible) {\n  --_discussionbridge-credit-accent: var(--sl-color-accent-high, var(--wp--preset--color--accent-2, var(--ghost-accent-color, #3451b2)));\n  color: var(--discussionbridge-credit-hover-link-color, color-mix(in srgb, var(--_discussionbridge-credit-accent) 42%, currentColor));\n  background-color: var(--discussionbridge-credit-hover-background, color-mix(in srgb, currentColor 16%, transparent));\n}\n\n.discussionbridge-credit > a:is(:hover, :focus-visible)::after {\n  transform: scaleX(1);\n}\n\n.discussionbridge-credit > a:focus-visible {\n  outline: 2px solid currentColor;\n  outline-offset: 0.2rem;\n}\n\n@media (prefers-reduced-motion: reduce) {\n  .discussionbridge-credit > a,\n  .discussionbridge-credit > a::after {\n    transition: none;\n  }\n}\n";
      document.head.append(creditStyles);
    }
    return credit;
  }

  function discussionFrame(comments, mode) {
    const url = new URL("/embed/comments", endpoint.origin);
    url.searchParams.set("topic_id", comments.topic_id);
    if (mode === "interactive") url.searchParams.set("full_app", "true");
    const frame = document.createElement("iframe");
    frame.src = url.href;
    frame.title = comments.discussion;
    frame.width = "100%";
    frame.height = mode === "interactive" ? "600" : "150";
    frame.loading = "lazy";
    frame.referrerPolicy = "no-referrer-when-downgrade";
    if (mode === "full") {
      window.addEventListener("message", (event) => {
        if (event.source !== frame.contentWindow || event.origin !== endpoint.origin ||
            event.data?.type !== "discourse-resize") return;
        const height = event.data.height;
        if (Number.isFinite(height) && height > 0 && height <= 100000) {
          frame.style.height = Math.ceil(height) + "px";
        }
      });
    }
    return frame;
  }

  function replyList(comments) {
    if (!comments.replies.length) {
      const empty = document.createElement("p");
      empty.textContent = comments.empty;
      return empty;
    }

    const replies = document.createElement("ol");
    for (const reply of comments.replies) {
      const item = document.createElement("li");
      item.textContent = reply;
      replies.append(item);
    }
    return replies;
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", loadComments, { once: true });
  } else {
    loadComments();
  }
})();
