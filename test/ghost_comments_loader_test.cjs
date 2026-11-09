const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { test } = require("node:test");
const { URL } = require("node:url");
const vm = require("node:vm");

const loader = fs.readFileSync(path.join(__dirname, "../public/comments.js"), "utf8");

function runLoader(fetch) {
  const link = { textContent: "Open discussion" };
  const snapshot = { textContent: "a reply removed by moderation" };
  const block = {
    children: [snapshot, link],
    querySelectorAll: () => [link],
    replaceChildren(...children) { this.children = children; },
    setAttribute(name, value) { this[name] = value; },
  };
  const document = {
    currentScript: { src: "https://forum.example/ghost/comments.js" },
    readyState: "complete",
    querySelector: () => ({}),
    querySelectorAll: () => [block],
    createElement: () => ({ children: [], append(child) { this.children.push(child); } }),
  };
  vm.runInNewContext(loader, {
    document, URL, fetch,
    location: { protocol: "https:", origin: "https://ghost.example", pathname: "/article/" },
  });
  return { block, link };
}

test("removes a legacy moderated reply before a failed live request finishes", async () => {
  let refuse;
  const response = new Promise((_, reject) => { refuse = reject; });
  const { block, link } = runLoader(() => response);
  assert.deepEqual(block.children, [link]);
  refuse(new Error("offline"));
  await new Promise(setImmediate);
  assert.deepEqual(block.children, [link]);
});

test("an unavailable linked topic leaves only the existing discussion link", async () => {
  const { block, link } = runLoader(async () => ({ ok: false, status: 404 }));
  await new Promise(setImmediate);
  assert.deepEqual(block.children, [link]);
});

test("refreshes the existing block from live replies alone", async () => {
  const { block } = runLoader(async () => ({
    ok: true,
    json: async () => ({
      topic_path: "/t/source/54", title: "Comments", empty: "No comments yet.",
      replies: ["currently visible reply"], discussion: "Open discussion",
    }),
  }));
  await new Promise(setImmediate);
  assert.equal(block["data-discussion-bridge-ghost-comments"], "loaded");
  assert.deepEqual(block.children[1].children.map((reply) => reply.textContent), ["currently visible reply"]);
  assert.equal(block.children[2].href, "https://forum.example/t/source/54");
});
