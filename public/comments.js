(() => {
  const script = document.currentScript;
  if (!script || location.protocol !== "https:") {
    return;
  }

  const endpoint = new URL("comments.json", script.src);
  if (endpoint.protocol !== "https:") {
    return;
  }
  endpoint.searchParams.set("url", location.origin + location.pathname);

  async function loadComments() {
    const article = document.querySelector("main article, article");
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
        article.append(target);
      }
      const heading = document.createElement("h2");
      heading.textContent = comments.title;
      const replies = document.createElement(comments.replies.length ? "ol" : "p");
      if (comments.replies.length) {
        for (const reply of comments.replies) {
          const item = document.createElement("li");
          item.textContent = reply;
          replies.append(item);
        }
      } else {
        replies.textContent = comments.empty;
      }
      const link = document.createElement("a");
      link.href = topic.href;
      link.textContent = comments.discussion;
      target.replaceChildren(heading, replies, link);
      target.setAttribute("data-discussion-bridge-ghost-comments", "loaded");
    } catch {
      // The saved discussion link remains available while live replies are unavailable.
    }
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", loadComments, { once: true });
  } else {
    loadComments();
  }
})();
