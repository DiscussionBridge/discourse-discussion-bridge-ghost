(() => {
  const script = document.currentScript;
  if (!script || location.protocol !== "https:") {
    return;
  }

  const endpoint = new URL("comments.json", script.src);
  if (endpoint.protocol !== "https:") {
    return;
  }
  const interactive = script.getAttribute("data-discussion-bridge-ghost-mode") === "interactive";
  if (!interactive && document.querySelector('script[data-discussion-bridge-ghost-mode="interactive"]')) {
    return;
  }
  endpoint.searchParams.set("url", location.origin + location.pathname);

  async function loadComments() {
    const scriptArticle = script.closest("article");
    const article = scriptArticle || document.querySelector("main article, article");
    const simpleBlocks = document.querySelectorAll("[data-db-owner] > [data-db-mode='simple']");
    for (const block of simpleBlocks) {
      // Older publications may still contain a saved reply snapshot. Keep only the discussion link.
      block.replaceChildren(...block.querySelectorAll(":scope > a[data-db-discussion='true']"));
    }
    let target = simpleBlocks[0] || document.querySelector("[data-discussion-bridge-ghost-comments]");
    if (!target && !article) {
      return;
    }

    try {
      const response = await fetch(endpoint, { credentials: "omit", redirect: "error" });
      if (!response.ok) {
        return;
      }
      const comments = await response.json();
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
      link.style.fontSize = "0.875em";
      header.append(heading, link);
      const content = interactive && Number.isSafeInteger(comments.topic_id) && comments.topic_id > 0
        ? discussionFrame(comments)
        : replyList(comments);
      const credit = document.createElement("footer");
      credit.className = "discussionbridge-credit";
      credit.setAttribute("aria-label", "DiscussionBridge credit");
      Object.assign(credit.style, {
        marginBlockStart: "0.5em",
        textAlign: "center",
        fontSize: "0.875em",
        lineHeight: "1.4",
        opacity: "0.8",
      });
      const brand = document.createElement("a");
      brand.className = "discussionbridge-credit__brand";
      brand.href = "https://discussionbridge.dev/";
      brand.textContent = "DiscussionBridge";
      brand.style.fontWeight = "600";
      credit.append("Connected by ", brand);
      const creditStyles = document.createElement("style");
      if (script.nonce) {
        creditStyles.nonce = script.nonce;
      }
      creditStyles.textContent = `
        footer.discussionbridge-credit > a.discussionbridge-credit__brand {
          position: relative;
          padding-inline: 0.2em;
          border-radius: 0.2em;
          color: inherit;
          text-decoration: none;
          transition: color 160ms ease, background-color 160ms ease;
        }
        .discussionbridge-credit > .discussionbridge-credit__brand::after {
          position: absolute;
          inset-inline: 0.2em;
          bottom: -0.12em;
          height: 1px;
          background: currentColor;
          content: "";
          transform: scaleX(0);
          transform-origin: center;
          transition: transform 180ms ease;
        }
        footer.discussionbridge-credit > a.discussionbridge-credit__brand:is(:hover, :focus-visible) {
          color: var(--ghost-accent-color, #3451b2);
          color: color-mix(in srgb, var(--ghost-accent-color, #3451b2) 68%, currentColor);
          background-color: color-mix(in srgb, var(--ghost-accent-color, #3451b2) 10%, transparent);
        }
        .discussionbridge-credit > .discussionbridge-credit__brand:is(:hover, :focus-visible)::after {
          transform: scaleX(1);
        }
        .discussionbridge-credit > .discussionbridge-credit__brand:focus-visible {
          outline: 2px solid currentColor;
          outline-offset: 0.2em;
        }
        @media (prefers-reduced-motion: reduce) {
          footer.discussionbridge-credit > a.discussionbridge-credit__brand,
          .discussionbridge-credit > .discussionbridge-credit__brand::after {
            transition: none;
          }
        }
      `;
      document.head.append(creditStyles);
      target.replaceChildren(header, content, credit);
      target.setAttribute("data-discussion-bridge-ghost-comments", "loaded");
    } catch {
      // The saved discussion link remains available while live replies are unavailable.
    }
  }

  function discussionFrame(comments) {
    const url = new URL("/embed/comments", endpoint.origin);
    url.searchParams.set("topic_id", comments.topic_id);
    url.searchParams.set("full_app", "true");
    const frame = document.createElement("iframe");
    frame.src = url.href;
    frame.title = comments.discussion;
    frame.width = "100%";
    frame.height = "600";
    frame.loading = "lazy";
    frame.referrerPolicy = "no-referrer-when-downgrade";
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
