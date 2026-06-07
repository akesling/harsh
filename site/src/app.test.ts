// Unit tests for the client logic. No DOM needed — these functions are pure
// over the bundled data. Run with: bun test
import { test, expect } from "bun:test";
import {
  highlightShell, linkifyPaths, md, buildMaps, buildVFS, resolvePath, fileAt,
  firstHit, ensureSearch, INDEX, SEARCH_DOCS, __test,
} from "./app.ts";

// the generated data is baked in at build time (counts grow with the project,
// so assert structure rather than exact numbers)
test("bundled data is present", () => {
  expect(INDEX.files.length).toBeGreaterThan(30);
  expect(INDEX.funcs.length).toBeGreaterThan(30);
  expect(SEARCH_DOCS.length).toBe(INDEX.files.length); // one search doc per file
  expect(INDEX.files.some((f: any) => f.path === "harsh.sh")).toBe(true);
});

buildMaps(INDEX);
__test.setPage("", "harsh.sh", "code");

test("highlight links function calls", () => {
  const h = highlightShell('  _p=$(resolve_command repl "${_name}")');
  expect(h).toContain("resolve_command</a>");
  expect(h).toContain('t-string'); // "${_name}" is a double-quoted string token
});

test("highlight links a short builtin-like function (die)", () => {
  expect(highlightShell('die "no such session"')).toMatch(/t-func"[^>]*>die<\/a>/);
});

test("variable highlighting for bare vars", () => {
  expect(highlightShell("_dir=${HARSH_SESSIONS_DIR}; n=$count")).toContain("t-var");
});

test("paths linkified inside comments", () => {
  const h = highlightShell("# see lib/render.sh for the palette");
  expect(h).toContain("t-comment");
  expect(h).toMatch(/class="path"[^>]*>lib\/render\.sh<\/a>/);
});

test("linkifyPaths handles full path and basename alias", () => {
  const lp = linkifyPaths("see tools/agent.sh and harsh.conf here");
  expect(lp).toMatch(/>tools\/agent\.sh<\/a>/);
  expect(lp).toMatch(/>harsh\.conf<\/a>/);
});

test("markdown: heading, inline code keeps digits, bold, list, sh fence", () => {
  const m = md("# T\n\nA `code 3 of 4` and **b**.\n\n- one\n- two\n\n```sh\ndie x\n```");
  expect(m).toContain("<h1>T</h1>");
  expect(m).toContain("<code>code 3 of 4</code>");
  expect(m).toContain("<strong>b</strong>");
  expect(m).toContain("<li>one</li>");
  expect(m).toMatch(/t-func"[^>]*>die<\/a>/);
});

test("VFS + path resolution", () => {
  const vfs = buildVFS(INDEX.files);
  __test.setVfs(vfs);
  expect(vfs.has("tools")).toBe(true);
  expect(vfs.has("hooks/PreToolUse/bash")).toBe(true);
  expect(vfs.get("tools")!.files.has("agent.sh")).toBe(true);
  __test.setCwd("tools");
  expect(resolvePath("..")).toBe("");
  expect(resolvePath("/hooks/SessionStart")).toBe("hooks/SessionStart");
  expect(resolvePath("agent.sh")).toBe("tools/agent.sh");
  expect(fileAt("tools/agent.sh")).toBeTruthy();
  expect(fileAt("tools")).toBeUndefined();
});

test("lunr full-text search returns ranked hits with snippets", () => {
  const idx = ensureSearch();
  const hits = idx.search("hook");
  expect(hits.length).toBeGreaterThan(0);
  const top = SEARCH_DOCS.find((d: any) => d.path === hits[0].ref);
  expect(top).toBeTruthy();
  const fh = firstHit(SEARCH_DOCS.find((d: any) => d.path === "harsh.sh").content, "run_hooks");
  expect(fh).toBeTruthy();
  expect(fh!.line).toBeGreaterThan(0);
  expect(fh!.text).toContain("run_hooks");
});
