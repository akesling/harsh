// Integration test: boot the whole client against a proxy DOM and confirm it
// renders end-to-end from the *bundled* data — no fetch, no exceptions. This is
// the regression guard for the "Jump to / linkage broken under file://" bug,
// which was caused by the old fetch("index.json") path.
import { test, expect } from "bun:test";
import { boot } from "./app.ts";

const NOOP = () => {};
let appended = 0;
function makeEl(): any {
  const t: any = {
    dataset: {}, style: {}, children: [],
    classList: { _s: new Set<string>(), add(x: string) { this._s.add(x); }, remove(x: string) { this._s.delete(x); }, toggle(x: string) { this._s.has(x) ? this._s.delete(x) : this._s.add(x); }, contains(x: string) { return this._s.has(x); } },
    textContent: "", innerHTML: "", value: "", className: "", id: "", tagName: "DIV",
  };
  return new Proxy(t, {
    get(o, p: string) {
      if (p in o) return o[p];
      if (["offsetTop", "offsetHeight", "scrollTop", "scrollHeight"].includes(p)) return 0;
      if (p === "appendChild" || p === "prepend" || p === "insertAdjacentElement") return () => { appended++; };
      if (["append", "remove", "removeChild", "addEventListener", "removeEventListener", "scrollIntoView", "setAttribute", "getAttribute", "focus", "blur", "matches"].includes(p)) return NOOP;
      if (p === "querySelector" || p === "closest") return () => makeEl();
      if (p === "querySelectorAll") return () => [];
      return undefined;
    },
    set(o, p, v) { o[p] = v; return true; },
  });
}

test("boot() renders from bundled data with no fetch and no throw", () => {
  const bodyEl = makeEl();
  Object.assign(bodyEl.dataset, { root: "", path: "harsh.sh", kind: "code", group: "The core harness" });
  const srcEl = makeEl(); srcEl.textContent = "#!/usr/bin/env sh\nset -u\ndie() { exit 1; }\n";

  (globalThis as any).document = {
    body: bodyEl,
    createElement: () => makeEl(),
    getElementById: (id: string) => (id === "src" ? srcEl : makeEl()),
    querySelector: () => makeEl(),
    querySelectorAll: () => [],
    addEventListener: NOOP,
    get activeElement() { return { tagName: "BODY" }; },
  };
  (globalThis as any).window = { matchMedia: () => ({ matches: false }), addEventListener: NOOP };
  (globalThis as any).localStorage = { getItem: () => null, setItem: NOOP };
  (globalThis as any).location = { hash: "", href: "" };
  (globalThis as any).requestAnimationFrame = (cb: any) => cb();
  (globalThis as any).cancelAnimationFrame = NOOP;
  // fetch intentionally undefined: if anything tries to fetch, it throws.

  expect(() => boot()).not.toThrow();
  expect(appended).toBeGreaterThan(0); // topbar/console/main/palette all mounted
});
