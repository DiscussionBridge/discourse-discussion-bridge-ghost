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
    let target = document.querySelector(
      "[data-discussion-bridge-ghost-comments], [data-db-owner] [data-db-mode='simple']"
    );
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
      // A public read failure leaves the article and its existing links intact.
    }
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", loadComments, { once: true });
  } else {
    loadComments();
  }
})();
