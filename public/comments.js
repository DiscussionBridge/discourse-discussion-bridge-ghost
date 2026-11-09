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
      const link = document.createElement("a");
      link.href = topic.href;
      link.textContent = comments.discussion;
      const content = interactive && Number.isSafeInteger(comments.topic_id) && comments.topic_id > 0
        ? discussionFrame(comments)
        : replyList(comments);
      target.replaceChildren(heading, content, link);
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
