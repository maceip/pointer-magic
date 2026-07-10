import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const root = new URL("../", import.meta.url);

async function render() {
  const workerUrl = new URL("../dist/server/index.js", import.meta.url);
  workerUrl.searchParams.set("test", `${process.pid}-${Date.now()}`);
  const { default: worker } = await import(workerUrl.href);

  return worker.fetch(
    new Request("http://localhost/", { headers: { accept: "text/html" } }),
    { ASSETS: { fetch: async () => new Response("Not found", { status: 404 }) } },
    { waitUntil() {}, passThroughOnException() {} },
  );
}

test("server-renders the After Chat research lab", async () => {
  const response = await render();
  assert.equal(response.status, 200);
  assert.match(response.headers.get("content-type") ?? "", /^text\/html\b/i);

  const html = await response.text();
  assert.match(html, /<title>After Chat — Browser Agent UI Lab<\/title>/i);
  assert.match(html, /The browser agent should not look like/);
  assert.match(html, /Intent Halo/);
  assert.match(html, /Shadow Run/);
  assert.match(html, /Apprentice Relay/);
  assert.doesNotMatch(html, /codex-preview|Your site is taking shape|react-loading-skeleton/i);
});

test("ships interactive concepts and removes starter infrastructure", async () => {
  const [component, page, layout, packageJson] = await Promise.all([
    readFile(new URL("app/after-chat-lab.tsx", root), "utf8"),
    readFile(new URL("app/page.tsx", root), "utf8"),
    readFile(new URL("app/layout.tsx", root), "utf8"),
    readFile(new URL("package.json", root), "utf8"),
  ]);

  assert.match(component, /useState/);
  assert.match(component, /type=\"range\"/);
  assert.match(component, /REHEARSE/);
  assert.match(component, /TEACH WITH THIS RECEIPT/);
  assert.match(component, /PREPARE 8 SAFE DRAFTS/);
  assert.match(page, /<AfterChatLab \/>/);
  assert.match(layout, /After Chat — Browser Agent UI Lab/);
  assert.doesNotMatch(packageJson, /react-loading-skeleton/);
  assert.doesNotMatch(component, /_sites-preview|codex-preview/);
});
