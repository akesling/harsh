// Tests for the dev server's free-port selection (no real sockets — the bind is
// injected). Importing build.ts is side-effect-free thanks to its import.meta.main guard.
import { test, expect } from "bun:test";
import { listenWithFallback } from "../build.ts";

const eaddrinuse = () => { const e: any = new Error("in use"); e.code = "EADDRINUSE"; return e; };

test("uses the requested port when free", () => {
  const got = listenWithFallback(8000, (p) => ({ port: p }));
  expect(got.port).toBe(8000);
});

test("walks forward over busy ports", () => {
  const busy = new Set([8000, 8001, 8002]);
  const got = listenWithFallback(8000, (p) => { if (busy.has(p)) throw eaddrinuse(); return { port: p }; });
  expect(got.port).toBe(8003);
});

test("falls back to an OS-assigned port (0) when the whole span is busy", () => {
  let lastTried = -1;
  const got = listenWithFallback(8000, (p) => { lastTried = p; if (p !== 0) throw eaddrinuse(); return { port: 0 }; }, 5);
  expect(got.port).toBe(0);          // OS-assigned
  expect(lastTried).toBe(0);         // tried port 0 last
});

test("non-EADDRINUSE errors propagate immediately", () => {
  expect(() => listenWithFallback(8000, () => { throw new Error("boom"); })).toThrow("boom");
});
