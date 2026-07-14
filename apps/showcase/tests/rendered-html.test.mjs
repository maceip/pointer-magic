import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const root = new URL("../", import.meta.url);

async function renderedPage(name) {
  return readFile(new URL(`.next/server/app/${name}.html`, root), "utf8");
}

test("server-renders the Magic Pointer research lab", async () => {
  const html = await renderedPage("index");
  assert.match(html, /<title>Magic Pointer Lab — Five Working Experiments<\/title>/i);
  assert.match(html, /The pointer should understand what you mean/);
  assert.match(html, /Threadline/);
  assert.match(html, /Pattern Brush/);
  assert.match(html, /Timefold/);
  assert.match(html, /Source X-Ray/);
  assert.match(html, /Afterimage/);
  assert.match(html, /Beat the hotkey/);
  assert.doesNotMatch(html, /codex-preview|Your site is taking shape|react-loading-skeleton/i);
});

test("preserves the earlier After Chat experiments at a local route", async () => {
  const html = await renderedPage("after-chat");
  assert.match(html, /The browser agent should not look like/);
  assert.match(html, /Intent Halo/);
  assert.match(html, /Shadow Run/);
  assert.match(html, /Apprentice Relay/);
});

test("ships interactive concepts and removes starter infrastructure", async () => {
  const [component, page, layout, packageJson] = await Promise.all([
    readFile(new URL("app/magic-pointer-lab.tsx", root), "utf8"),
    readFile(new URL("app/page.tsx", root), "utf8"),
    readFile(new URL("app/layout.tsx", root), "utf8"),
    readFile(new URL("package.json", root), "utf8"),
  ]);

  assert.match(component, /useState/);
  assert.match(component, /requestAnimationFrame/);
  assert.match(component, /type=\"range\"/);
  assert.match(component, /CHECK THE CONNECTION/);
  assert.match(component, /THIS BELONGS/);
  assert.match(component, /SIMULATING ONLY/);
  assert.match(component, /PULL DEEPER/);
  assert.match(component, /PATH NOTICED/);
  assert.match(page, /<MagicPointerLab \/>/);
  assert.match(layout, /Magic Pointer Lab — Five Working Experiments/);
  assert.doesNotMatch(packageJson, /react-loading-skeleton/);
  assert.doesNotMatch(packageJson, /vinext|wrangler|cloudflare|drizzle/i);
  assert.doesNotMatch(component, /_sites-preview|codex-preview/);
});
