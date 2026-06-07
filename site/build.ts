// build.ts — generate the harsh.sh interactive source tour into site/dist/.
//
// Run with Bun:  bun run build.ts          (production build into dist/)
//                bun run build.ts --dev     (build, serve, watch, live-reload)
//
// The landing page is, quite literally, harsh.sh: dist/index.html is the page
// for the core harness, and you click outward from there. Every project file
// gets its own page; all the interactive behaviour (syntax colouring, docco
// margin annotations, cross-file links, the pop-down terminal, full-text search)
// lives in the bundled client (src/app.ts), driven by data this script bakes in.
//
// All page data (the file index AND the search corpus) is written to
// src/generated.json and bundled straight into the client by `Bun.build`, so the
// site needs NO fetch at runtime — it works opened directly from file:// as well
// as served. Search uses lunr (a real dependency, bundled in — no CDN, no vendor
// step, no fallback).
import { Glob } from "bun";
import * as fs from "node:fs";
import * as path from "node:path";

const SITE = import.meta.dir;
const ROOT = path.resolve(SITE, "..");
const DIST = path.join(SITE, "dist");
const DEV = process.argv.includes("--dev");
const portArg = process.argv.indexOf("--port");
const PORT = portArg >= 0 ? Number(process.argv[portArg + 1]) : 8000;

// ---------------------------------------------------------------------------
// manifest — the guided tour, in order. Globs keep it complete as harsh grows.
// ---------------------------------------------------------------------------
type Entry = { group: string; rel: string };

function gather(): Entry[] {
  const seen = new Set<string>();
  const out: Entry[] = [];
  const add = (group: string, rel: string) => {
    if (seen.has(rel)) return;
    const abs = path.join(ROOT, rel);
    if (!fs.existsSync(abs) || !fs.statSync(abs).isFile()) return;
    seen.add(rel);
    out.push({ group, rel });
  };
  const glob = (group: string, ...patterns: string[]) => {
    for (const p of patterns)
      for (const m of [...new Glob(p).scanSync({ cwd: ROOT, onlyFiles: true })].sort())
        add(group, m);
  };

  add("The core harness", "harsh.sh");
  add("The core harness", "harsh_tui.sh");
  add("Tools — one file per capability", "tools/tool.sh");
  glob("Tools — one file per capability", "tools/*.sh");
  glob("Commands — extensible CLI verbs", "commands/*.sh", "commands/cli/*.sh", "commands/repl/*.sh");
  glob("Hooks — observe & gate the loop", "hooks/*/*.sh", "hooks/*/*/*.sh");
  glob("Skills — instructions on demand", "skills/*/SKILL.md");
  add("Shared library", "lib/render.sh");
  add("Configuration & install", "harsh.conf");
  add("Configuration & install", "install.sh");
  for (const f of ["README.md", "STYLE.md", "commands/README.md", "hooks/README.md", "prompt.txt"])
    add("Docs & conventions", f);
  return out;
}

// ---------------------------------------------------------------------------
// extraction
// ---------------------------------------------------------------------------
const htmlEscape = (s: string) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
const attr = (s: string) => htmlEscape(s).replace(/"/g, "&quot;");

type Note = { line: number; text: string };

// docco-style: a maximal run of comment lines attaches to the next line of
// code. Shebang and `# shellcheck` lines are ignored; a line with no
// alphanumerics (`# ----`) is a divider, skipped without breaking the run;
// blank lines don't break a run. The first note is the file intro.
function extractNotes(content: string): { notes: Note[]; intro: string } {
  const lines = content.split("\n");
  const notes: Note[] = [];
  let buf = "";
  const flush = (lineNo: number) => { if (buf) { notes.push({ line: lineNo, text: buf }); buf = ""; } };
  for (let i = 0; i < lines.length; i++) {
    const stripped = lines[i].replace(/^[ \t]+/, "");
    if (stripped.startsWith("#!") || stripped.startsWith("# shellcheck")) continue;
    if (stripped.startsWith("#")) {
      const ctext = stripped.replace(/^#/, "").replace(/^ /, "");
      if (/[A-Za-z0-9]/.test(ctext)) buf = buf ? buf + "\n" + ctext : ctext;
    } else if (stripped === "") {
      // blank — keep the run pending
    } else flush(i + 1);
  }
  flush(lines.length);
  return { notes, intro: notes.length ? notes[0].text : "" };
}

type Func = { name: string; path: string; line: number };
function extractFuncs(content: string, rel: string): Func[] {
  const out: Func[] = [];
  content.split("\n").forEach((line, i) => {
    const m = line.match(/^([A-Za-z_][A-Za-z0-9_]*)\(\)/);
    if (m) out.push({ name: m[1], path: rel, line: i + 1 });
  });
  return out;
}

const firstSentence = (text: string) => {
  const t = text.replace(/\n/g, " ").replace(/\s+/g, " ").trim();
  const m = t.match(/^.*?[.!?](\s|$)/);
  return (m ? m[0] : t).trim().slice(0, 140);
};
function mdBlurb(content: string): string {
  for (const line of content.split("\n")) {
    const t = line.trim();
    if (!t || t.startsWith("#") || t.startsWith("```")) continue;
    return firstSentence(t);
  }
  return "";
}

// ---------------------------------------------------------------------------
// page template
// ---------------------------------------------------------------------------
const FAVICON =
  "data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 32 32'%3E%3Ctext y='26' font-size='26'%3E%E2%9D%AF%3C/text%3E%3C/svg%3E";
const RELOAD_CLIENT =
  `(()=>{try{var ws=new WebSocket((location.protocol==='https:'?'wss':'ws')+'://'+location.host+'/__livereload');ws.onmessage=function(){location.reload()};}catch(e){}})();`;

const rootPrefix = (rel: string) => "../".repeat(rel.split("/").length - 1);

function emitPage(rel: string, group: string, title: string, kind: string, content: string) {
  const root = rootPrefix(rel);
  const out = path.join(DIST, rel + ".html");
  fs.mkdirSync(path.dirname(out), { recursive: true });
  const dev = DEV ? `<script>${RELOAD_CLIENT}</script>\n` : "";
  const html =
`<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${htmlEscape(title)} · harsh</title>
<link rel="stylesheet" href="${root}assets/style.css">
<link rel="icon" href="${FAVICON}">
</head>
<body data-path="${attr(rel)}" data-group="${attr(group)}" data-root="${attr(root)}" data-kind="${kind}">
<pre id="src" hidden>
${htmlEscape(content)}</pre>
${dev}<script src="${root}assets/app.js" defer></script>
</body>
</html>
`;
  fs.writeFileSync(out, html);
}

// ---------------------------------------------------------------------------
// build
// ---------------------------------------------------------------------------
async function runBuild() {
  fs.rmSync(DIST, { recursive: true, force: true });
  fs.mkdirSync(path.join(DIST, "assets"), { recursive: true });

  const entries = gather();
  const files: any[] = [];
  const funcs: Func[] = [];
  const search: any[] = [];

  for (const { group, rel } of entries) {
    const content = fs.readFileSync(path.join(ROOT, rel), "utf8");
    const kind = /\.(md|txt)$/.test(rel) ? "md" : "code";
    const title = path.basename(rel);
    let intro = "", blurb = "";
    if (kind === "code") {
      intro = extractNotes(content).intro;     // first comment block -> header card
      blurb = firstSentence(intro);
      funcs.push(...extractFuncs(content, rel));
    } else {
      blurb = mdBlurb(content);
    }
    files.push({ path: rel, group, title, page: rel + ".html", kind, intro, blurb });
    search.push({ path: rel, page: rel + ".html", title, content });
    emitPage(rel, group, title, kind, content);
  }

  // Bake all page data into a module the client bundle imports — no runtime fetch.
  fs.writeFileSync(path.join(SITE, "src/generated.json"),
    JSON.stringify({ index: { files, funcs }, search }));

  // Bundle the client (app.ts + lunr + the generated data) into dist/assets/app.js.
  const res = await Bun.build({
    entrypoints: [path.join(SITE, "src/app.ts")],
    outdir: path.join(DIST, "assets"),
    minify: !DEV,
    target: "browser",
    // IIFE (self-executing) so the bundle loads as a classic <script> and runs
    // under file:// too. An ESM bundle (the default) has top-level `export`,
    // which throws a SyntaxError when loaded as a non-module script.
    format: "iife",
    naming: "[dir]/[name].[ext]",
  });
  if (!res.success) { console.error(res.logs); throw new Error("bundle failed"); }

  fs.copyFileSync(path.join(SITE, "assets/style.css"), path.join(DIST, "assets/style.css"));
  // Landing page == the harsh.sh page (it already lives at the dist root).
  fs.copyFileSync(path.join(DIST, "harsh.sh.html"), path.join(DIST, "index.html"));

  const bundleKB = Math.round(fs.statSync(path.join(DIST, "assets/app.js")).size / 1024);
  console.log(`build.ts: ${files.length} pages, ${funcs.length} linkable functions, ` +
    `${search.length}-doc search index · app.js ${bundleKB}KB${DEV ? " (dev)" : ""} -> site/dist/`);
}

// ---------------------------------------------------------------------------
// dev server: serve dist/, watch the repo, rebuild + live-reload on change
// ---------------------------------------------------------------------------
function startDevServer() {
  const clients = new Set<any>();
  const server = Bun.serve({
    port: PORT,
    async fetch(req, srv) {
      const url = new URL(req.url);
      if (url.pathname === "/__livereload") { if (srv.upgrade(req)) return; }
      let p = decodeURIComponent(url.pathname);
      if (p.endsWith("/")) p += "index.html";
      const file = Bun.file(path.join(DIST, p));
      return (await file.exists()) ? new Response(file) : new Response("not found", { status: 404 });
    },
    websocket: { message() {}, open(ws) { clients.add(ws); }, close(ws) { clients.delete(ws); } },
  });

  let timer: any = null, building = false;
  // Ignore generated/runtime paths — crucially src/generated.json and dist/,
  // which the build itself writes, so a rebuild never retriggers the watcher.
  const ignore = /(^|\/)(dist|node_modules|\.git|sessions|logs|local)(\/|$)|(^|\/)generated\.json$/;
  fs.watch(ROOT, { recursive: true }, (_e, fn) => {
    if (!fn || ignore.test(fn)) return;
    clearTimeout(timer);
    timer = setTimeout(async () => {
      if (building) return;
      building = true;
      try { await runBuild(); clients.forEach((ws) => ws.send("reload")); }
      catch (e) { console.error("rebuild failed:", e); }
      finally { building = false; }
    }, 120);
  });

  console.log(`build.ts: serving http://localhost:${server.port}/  (watching for changes — Ctrl-C to stop)`);
}

await runBuild();
if (DEV) startDevServer();
