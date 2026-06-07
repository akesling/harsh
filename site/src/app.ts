// app.ts — client runtime for the harsh source tour.
//
// Bundled by build.ts (with lunr and the generated page data) into
// dist/assets/app.js. All data is imported, not fetched, so the site works
// opened straight from file:// as well as served. Turns each static page into
// the interactive tour: syntax colouring, clickable cross-references (file paths
// and function calls), docco margin annotations, a pop-down terminal for
// navigation, full-text search, a ⌘K palette, and Markdown rendering.
import lunr from "lunr";
import DATA from "./generated.json";
import { CopyMode, prefixCommand } from "./copymode";

const INDEX: { files: any[]; funcs: any[] } = (DATA as any).index;
const SEARCH_DOCS: any[] = (DATA as any).search;

// page identity — populated by boot() from the <body> data-* attributes.
let body: HTMLElement;
let ROOT = "";
let CUR = "";
let KIND = "code";

const esc = (s: string) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
const escAttr = (s: string) => esc(s).replace(/"/g, "&quot;");

const KEYWORDS = new Set("if then elif else fi for while until do done case esac in function select time return break continue exit local export readonly declare set unset shift trap eval exec".split(" "));
const BUILTINS = new Set("echo printf read cd pwd test command type source true false sh bash jq curl sed grep cat tr cut sort uniq head tail wc date basename dirname mkdir rmdir rm cp mv ln find xargs awk env sleep tee touch chmod kill wait getopts shopt emulate setopt".split(" "));

let pathAlias = new Map<string, string>(); // alias -> page path
let funcMap = new Map<string, any>();       // name -> {path,line}
let PATH_KEYS: string[] = [];
let PATH_RE: RegExp | null = null;
const reEsc = (s: string) => s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");

function buildMaps(idx: { files: any[]; funcs: any[] }) {
  pathAlias = new Map(); funcMap = new Map();
  const baseCount = new Map<string, number>();
  (idx.files || []).forEach((f) => {
    pathAlias.set(f.path, f.path);
    const base = f.path.split("/").pop()!;
    baseCount.set(base, (baseCount.get(base) || 0) + 1);
  });
  (idx.files || []).forEach((f) => {
    const base = f.path.split("/").pop()!;
    if (baseCount.get(base) === 1) pathAlias.set(base, f.path);
  });
  (idx.funcs || []).forEach((fn) => { if (!funcMap.has(fn.name)) funcMap.set(fn.name, fn); });
  PATH_KEYS = [...pathAlias.keys()].sort((a, b) => b.length - a.length);
  PATH_RE = PATH_KEYS.length
    ? new RegExp("(^|[^\\w./-])(" + PATH_KEYS.map(reEsc).join("|") + ")(?![\\w/-])", "g")
    : null;
}

function pageHref(p: string, line?: number) {
  if (p === CUR) return line ? "#L" + line : "#";
  return ROOT + p + ".html" + (line ? "#L" + line : "");
}

// Wrap known file-path mentions inside raw text (comments, strings, prose) in
// links. Returns escaped HTML.
function linkifyPaths(raw: string) {
  if (!PATH_RE) return esc(raw);
  let out = "", last = 0, m: RegExpExecArray | null;
  PATH_RE.lastIndex = 0;
  while ((m = PATH_RE.exec(raw))) {
    const start = m.index + m[1].length;
    out += esc(raw.slice(last, start));
    const alias = m[2], target = pathAlias.get(alias)!;
    out += `<a class="path" href="${escAttr(pageHref(target))}">${esc(alias)}</a>`;
    last = start + alias.length;
  }
  out += esc(raw.slice(last));
  return out;
}

// ---- shell syntax highlighter (hand scanner, linkifies as it goes) --------
function highlightShell(line: string) {
  let out = "", i = 0; const n = line.length;
  const isWord = (c: string) => /[A-Za-z0-9_]/.test(c);
  while (i < n) {
    const c = line[i];
    if (c === "#" && (i === 0 || /\s/.test(line[i - 1]))) {
      // split the leading #'s (and one space) off as a dim marker so the prose
      // of the comment reads cleanly against the de-emphasized hash.
      const rest = line.slice(i);
      const mk = rest.match(/^#+\s?/);
      const hash = mk ? mk[0] : "#";
      out += `<span class="t-comment"><span class="t-hash">${esc(hash)}</span>${linkifyPaths(rest.slice(hash.length))}</span>`;
      break;
    }
    if (c === "'") {
      let j = i + 1; while (j < n && line[j] !== "'") j++;
      out += `<span class="t-string">${linkifyPaths(line.slice(i, Math.min(j + 1, n)))}</span>`;
      i = j + 1; continue;
    }
    if (c === '"') {
      let j = i + 1;
      while (j < n) { if (line[j] === "\\") j += 2; else if (line[j] === '"') break; else j++; }
      out += `<span class="t-string">${linkifyPaths(line.slice(i, Math.min(j + 1, n)))}</span>`;
      i = j + 1; continue;
    }
    if (c === "$" && i + 1 < n && (line[i + 1] === "{" || /[A-Za-z_0-9@*?#!-]/.test(line[i + 1]))) {
      let j = i + 1;
      if (line[j] === "{") { while (j < n && line[j] !== "}") j++; j++; }
      else { j++; while (j < n && isWord(line[j])) j++; }
      out += `<span class="t-var">${esc(line.slice(i, j))}</span>`; i = j; continue;
    }
    if (/[A-Za-z_]/.test(c)) {
      let j = i + 1; while (j < n && isWord(line[j])) j++;
      const w = line.slice(i, j);
      if (funcMap.has(w)) {
        const fn = funcMap.get(w);
        out += `<a class="t-func" href="${escAttr(pageHref(fn.path, fn.line))}">${esc(w)}</a>`;
      } else if (KEYWORDS.has(w)) out += `<span class="t-keyword">${esc(w)}</span>`;
      else if (BUILTINS.has(w)) out += `<span class="t-builtin">${esc(w)}</span>`;
      else out += esc(w);
      i = j; continue;
    }
    if (/[0-9]/.test(c)) {
      let j = i + 1; while (j < n && /[0-9.]/.test(line[j])) j++;
      out += `<span class="t-number">${esc(line.slice(i, j))}</span>`; i = j; continue;
    }
    if (/[|&;<>(){}=]/.test(c)) { out += `<span class="t-punct">${esc(c)}</span>`; i++; continue; }
    out += esc(c); i++;
  }
  return out;
}

// ---- init -----------------------------------------------------------------
function init() {
  buildMaps(INDEX);
  buildTopbar();
  buildLayout();
  buildConsole(INDEX);
  const fileRec = (INDEX.files || []).find((f) => f.path === CUR) ||
    { intro: "", group: body.dataset.group, title: CUR };
  buildHead(fileRec);
  if (KIND === "md") renderMarkdown(fileRec); else renderCode(fileRec);
  buildPalette(INDEX);
  handleHashTarget();
}

// ---- code page ------------------------------------------------------------
// A full-line comment (after optional indentation, starting with # but not a
// shebang) — these rows get the woven-in "annotation" styling, and consecutive
// ones form a block via the shared left spine in CSS.
function isCommentLine(line: string) {
  const s = line.replace(/^\s+/, "");
  return s.charAt(0) === "#" && s.charAt(1) !== "!";
}

function renderCode(_rec: any) {
  const srcEl = document.getElementById("src");
  const source = srcEl ? srcEl.textContent!.replace(/\n$/, "") : "";
  srcEl && srcEl.remove();
  const lines = source.split("\n");

  const code = document.createElement("div");
  code.className = "code";
  lines.forEach((ln, k) => {
    const num = k + 1;
    const row = document.createElement("div");
    row.className = "row" + (isCommentLine(ln) ? " cmt" : "");
    row.id = "L" + num;
    row.innerHTML = `<span class="ln">${num}</span><span class="cl">${highlightShell(ln) || "​"}</span>`;
    code.appendChild(row);
  });
  document.querySelector(".doc")!.appendChild(code);
}

function renderNoteText(text: string) {
  return text.split(/(`[^`]+`)/g).map((p) =>
    p.startsWith("`") && p.endsWith("`") ? `<code>${esc(p.slice(1, -1))}</code>` : linkifyPaths(p)
  ).join("");
}

// ---- header card ----------------------------------------------------------
function buildHead(rec: any) {
  const doc = document.querySelector(".doc")!;
  const head = document.createElement("header");
  head.className = "filehead";
  const segs = CUR.split("/"); const base = segs.pop()!;
  const dir = segs.length ? `<span class="dir">${esc(segs.join("/"))}/</span>` : "";
  const intro = rec.intro;
  head.innerHTML =
    `<div class="grouptag">${esc(rec.group || body.dataset.group || "")}</div>` +
    `<h1>${dir}${esc(base)}</h1>` +
    (intro ? `<div class="intro">${renderNoteText(intro)}</div>` : "");
  doc.prepend(head);
}

// ---- topbar ---------------------------------------------------------------
function buildTopbar() {
  const bar = document.createElement("div");
  bar.className = "topbar";
  const segs = CUR.split("/");
  const crumbHtml = segs.map((s, k) => (k === segs.length - 1 ? `<b>${esc(s)}</b>` : esc(s)))
    .join('<span style="opacity:.5"> / </span>');
  bar.innerHTML =
    `<div class="brand"><span class="glyph">&#10095;</span><a href="${ROOT}index.html">harsh</a></div>` +
    `<div class="crumbs">${crumbHtml}</div>` +
    `<div class="spacer"></div>` +
    `<button class="btn" id="toggle-console" title="Toggle terminal (\`)">&#10095;_ <kbd>&#96;</kbd></button>` +
    `<button class="btn" id="open-palette">Jump to&hellip; <kbd>&#8984;K</kbd></button>` +
    `<button class="btn" id="toggle-theme" title="Toggle theme">&#9681;</button>`;
  body.prepend(bar);
  document.getElementById("toggle-console")!.addEventListener("click", toggleConsole);
  document.getElementById("open-palette")!.addEventListener("click", openPalette);
  document.getElementById("toggle-theme")!.addEventListener("click", toggleTheme);
}

function toggleTheme() {
  const next = body.dataset.theme === "light" ? "" : "light";
  if (next) body.dataset.theme = next; else delete body.dataset.theme;
  try { localStorage.setItem("harsh-theme", next); } catch (e) {}
}

// ---- layout ---------------------------------------------------------------
function buildLayout() {
  const main = document.createElement("div"); main.className = "main";
  const doc = document.createElement("div"); doc.className = "doc";
  main.appendChild(doc); body.appendChild(main);
}

// ---- pop-down terminal ----------------------------------------------------
let conEl: HTMLElement, conScroll: HTMLElement, conInput: HTMLInputElement, conPrompt: HTMLElement, conStatus: HTMLElement;
let copyMode: CopyMode;
let prefixArmed = false, prefixTimer: any = null;   // tmux Ctrl+a leader
let vfs = new Map<string, { dirs: Set<string>; files: Map<string, any> }>();
let cwd = "";
let history: string[] = [], histIdx = 0;

// Clipboard write that also works on file:// / non-secure contexts (where the
// async Clipboard API is unavailable) via a temporary textarea + execCommand.
function copyText(s: string) {
  try {
    if (navigator.clipboard && navigator.clipboard.writeText) { navigator.clipboard.writeText(s); return; }
  } catch (e) { /* fall through */ }
  try {
    const ta = document.createElement("textarea");
    ta.value = s; ta.style.position = "fixed"; ta.style.top = "-1000px"; ta.style.opacity = "0";
    document.body.appendChild(ta); ta.focus(); ta.select();
    document.execCommand("copy");
    document.body.removeChild(ta);
  } catch (e) { /* give up quietly */ }
}

function buildConsole(idx: { files: any[] }) {
  vfs = buildVFS(idx.files || []);
  const segs = CUR.split("/"); segs.pop(); cwd = segs.join("/");

  conEl = document.createElement("section");
  conEl.className = "console";
  conEl.innerHTML =
    `<div class="con-scroll" id="con-scroll"></div>` +
    `<div class="con-line">` +
      `<span class="con-prompt" id="con-prompt"></span>` +
      `<input class="con-input" id="con-input" spellcheck="false" autocomplete="off" ` +
        `autocapitalize="off" autocorrect="off" placeholder="ls · cd tools · open harsh.sh · grep hook · help">` +
      `<button class="con-toggle" id="con-toggle" title="Toggle terminal (\`)">&#9662;</button>` +
    `</div>` +
    `<div class="con-status" id="con-status"></div>`;
  document.querySelector(".topbar")!.insertAdjacentElement("afterend", conEl);
  conScroll = conEl.querySelector("#con-scroll")!;
  conInput = conEl.querySelector("#con-input")!;
  conPrompt = conEl.querySelector("#con-prompt")!;
  conStatus = conEl.querySelector("#con-status")!;
  updatePrompt();

  copyMode = new CopyMode({
    scroll: conScroll, status: conStatus,
    onEnter: () => conInput.blur(),
    onExit: () => conInput.focus(),
    copyText,
  });

  conEl.querySelector("#con-toggle")!.addEventListener("click", toggleConsole);
  conPrompt.addEventListener("click", () => { openConsole(); conInput.focus(); });
  conEl.querySelector(".con-line")!.addEventListener("click", (e) => {
    if ((e.target as HTMLElement).tagName !== "BUTTON") conInput.focus();
  });
  conInput.addEventListener("keydown", onConsoleKey);
  conScroll.addEventListener("click", (e) => {
    const d = (e.target as HTMLElement).closest("[data-cd]");
    if (d) { e.preventDefault(); conInput.value = ""; runCommand("cd " + d.getAttribute("data-cd")); runCommand("ls"); }
  });
  conPut(`<span class="con-dim">harsh source tour. Type <b>help</b>, or <b>ls</b> to look around. <b>^a [</b> (or <b>Esc</b>) = vi copy mode · <b>\`</b> toggles.</span>`);
}

function buildVFS(files: any[]) {
  const dirs = new Map<string, { dirs: Set<string>; files: Map<string, any> }>();
  const ensure = (d: string) => { if (!dirs.has(d)) dirs.set(d, { dirs: new Set(), files: new Map() }); return dirs.get(d)!; };
  ensure("");
  files.forEach((f) => {
    const segs = f.path.split("/"); const name = segs.pop();
    let parent = "";
    segs.forEach((s: string, i: number) => { const full = segs.slice(0, i + 1).join("/"); ensure(parent).dirs.add(s); ensure(full); parent = full; });
    ensure(parent).files.set(name, f);
  });
  return dirs;
}

const prettyCwd = () => "/" + cwd;
function updatePrompt() { conPrompt.textContent = `harsh:${prettyCwd()} $`; }

function resolvePath(arg?: string) {
  if (arg === undefined || arg === "") return cwd;
  const base = arg.charAt(0) === "/" ? [] : cwd.split("/").filter(Boolean);
  arg.split("/").forEach((s) => { if (s === "" || s === ".") return; if (s === "..") base.pop(); else base.push(s); });
  return base.join("/");
}
function fileAt(p: string) {
  const segs = p.split("/"); const name = segs.pop()!; const dir = segs.join("/");
  return vfs.has(dir) ? vfs.get(dir)!.files.get(name) : undefined;
}

function conPut(html: string, cls?: string) { const d = document.createElement("div"); d.className = "con-out" + (cls ? " " + cls : ""); d.innerHTML = html; conScroll.appendChild(d); }
function conText(t: string, cls?: string) { conPut(esc(t), cls); }

function disarmPrefix() { prefixArmed = false; clearTimeout(prefixTimer); if (!copyMode.active) { conStatus.textContent = ""; conStatus.className = "con-status"; } }

function onConsoleKey(e: KeyboardEvent) {
  // tmux leader: Ctrl+a, then a command key ([ = copy mode, like tmux).
  if (prefixArmed) {
    e.preventDefault(); disarmPrefix();
    const act = prefixCommand(e.key);
    if (act === "copy") { openConsole(); copyMode.enter(); }
    else if (act === "help") { cmdHelp(); }
    return; // the key after the leader is consumed either way
  }
  if (e.ctrlKey && !e.metaKey && !e.altKey && e.key.toLowerCase() === "a") {
    e.preventDefault();
    prefixArmed = true;
    conStatus.textContent = "^a —  [ copy/select mode · ? help";
    conStatus.className = "con-status";
    clearTimeout(prefixTimer);
    prefixTimer = setTimeout(disarmPrefix, 2500);
    return;
  }

  if (e.key === "Enter") { const v = conInput.value; conInput.value = ""; runCommand(v); }
  else if (e.key === "ArrowUp") { e.preventDefault(); if (histIdx > 0) { histIdx--; conInput.value = history[histIdx] || ""; } }
  else if (e.key === "ArrowDown") { e.preventDefault(); if (histIdx < history.length) { histIdx++; conInput.value = history[histIdx] || ""; } }
  else if (e.key === "Tab") { e.preventDefault(); tabComplete(); }
  else if (e.key === "Escape") { e.preventDefault(); openConsole(); copyMode.enter(); }
}

function tabComplete() {
  const val = conInput.value; const sp = val.lastIndexOf(" ");
  const head = val.slice(0, sp + 1), tok = val.slice(sp + 1);
  const slash = tok.lastIndexOf("/");
  const dirPart = slash >= 0 ? tok.slice(0, slash + 1) : "";
  const prefix = slash >= 0 ? tok.slice(slash + 1) : tok;
  const dir = resolvePath(dirPart || ".");
  if (!vfs.has(dir)) return;
  const node = vfs.get(dir)!;
  const names = [...[...node.dirs].map((d) => d + "/"), ...node.files.keys()]
    .filter((nm) => nm.toLowerCase().startsWith(prefix.toLowerCase()));
  if (!names.length) return;
  if (names.length === 1) { conInput.value = head + dirPart + names[0]; return; }
  let cp = names[0];
  names.forEach((nm) => { while (!nm.toLowerCase().startsWith(cp.toLowerCase())) cp = cp.slice(0, -1); });
  conInput.value = head + dirPart + cp;
  printPrompt(val);
  conPut(names.map((nm) => `<span class="${nm.endsWith("/") ? "e-dir" : "e-file"}">${esc(nm)}</span>`).join("  "));
  scrollBottom();
}

function printPrompt(cmd: string) { conPut(`<span class="con-p">harsh:${esc(prettyCwd())} $</span> ${esc(cmd)}`, "con-cmd"); }

function runCommand(line: string) {
  line = line.trim();
  openConsole();
  printPrompt(line);
  if (line) { history.push(line); histIdx = history.length; }
  const parts = line.split(/\s+/).filter(Boolean);
  const cmd = parts[0], a = parts[1];
  switch (cmd) {
    case undefined: break;
    case "help": cmdHelp(); break;
    case "ls": case "ll": case "dir": cmdLs(a); break;
    case "cd": cmdCd(a); break;
    case "pwd": conText(prettyCwd()); break;
    case "open": case "cat": case "less": case "vi": case "vim": case "view": case "o": cmdOpen(a); break;
    case "tree": cmdTree(); break;
    case "grep": case "search": case "find": case "rg": cmdGrep(parts.slice(1).join(" ")); break;
    case "clear": case "cls": conScroll.innerHTML = ""; break;
    case "whoami": conText("guest"); break;
    case "harsh": conText("an agent harness like no other. pure portable shell."); break;
    default: conPut(`harsh: command not found: <b>${esc(cmd)}</b> — try <b>help</b>`, "err");
  }
  updatePrompt(); scrollBottom();
}

function cmdHelp() {
  conPut([
    "navigate the project as a filesystem:",
    "  <b>ls</b> [path]        list a directory",
    "  <b>cd</b> &lt;path&gt;       change directory (.. and / work)",
    "  <b>pwd</b>             print the current directory",
    "  <b>open</b> &lt;file&gt;     open a file's page  (aliases: cat, less, view)",
    "  <b>tree</b>            print the whole project tree",
    "  <b>grep</b> &lt;text&gt;     full-text search across every file",
    "  <b>clear</b>           clear the scrollback",
    "",
    "<b>^a [</b> (tmux leader) or <b>Esc</b> enters copy mode — a tmux/vi keyboard layer:",
    "  motions <b>h j k l</b> · <b>w b e</b> · <b>0 ^ $</b> · <b>gg G</b> · <b>^d ^u ^f ^b</b> · <b>H M L</b> (with counts)",
    "  <b>/</b> <b>?</b> search · <b>n N</b> repeat · <b>v</b>/<b>V</b> select · <b>y</b>/<b>⏎</b> yank to clipboard · <b>q</b> leave",
    "",
    "shortcuts: <b>Tab</b> completes · <b>↑/↓</b> history · <b>`</b> toggles · <b>⌘K</b> jump palette",
  ].join("\n"));
}

function cmdLs(arg?: string) {
  const p = resolvePath(arg);
  if (vfs.has(p)) {
    const node = vfs.get(p)!;
    const rows: string[] = [];
    [...node.dirs].sort().forEach((name) => {
      const full = (p ? p + "/" : "") + name;
      rows.push(`<div class="e"><a class="e-dir" href="#" data-cd="${escAttr(full)}">${esc(name)}/</a><span></span></div>`);
    });
    [...node.files.keys()].sort().forEach((name) => {
      const f = node.files.get(name);
      rows.push(`<div class="e"><a class="e-file" href="${escAttr(ROOT + f.page)}">${esc(name)}</a><span class="blurb">${esc(f.blurb || "")}</span></div>`);
    });
    conPut(rows.length ? rows.join("") : `<span class="con-dim">(empty)</span>`);
  } else if (fileAt(p)) {
    const f = fileAt(p);
    conPut(`<div class="e"><a class="e-file" href="${escAttr(ROOT + f.page)}">${esc(arg || "")}</a><span class="blurb">${esc(f.blurb || "")}</span></div>`);
  } else conPut(`ls: ${esc(arg || "")}: No such file or directory`, "err");
}

function cmdCd(arg?: string) {
  if (arg === undefined) { cwd = ""; return; }
  const p = resolvePath(arg);
  if (vfs.has(p)) cwd = p;
  else if (fileAt(p)) conPut(`cd: not a directory: ${esc(arg)} — try <b>open ${esc(arg)}</b>`, "err");
  else conPut(`cd: no such file or directory: ${esc(arg)}`, "err");
}

function cmdOpen(arg?: string) {
  if (!arg) { conPut("usage: open &lt;file&gt;", "err"); return; }
  const p = resolvePath(arg); const f = fileAt(p);
  if (f) { conText("opening " + p + " …"); location.href = ROOT + f.page; }
  else if (vfs.has(p)) conPut(`open: ${esc(arg)} is a directory — try <b>cd ${esc(arg)}</b>`, "err");
  else conPut(`open: ${esc(arg)}: no such file`, "err");
}

function cmdTree() {
  const lines: string[] = [];
  const walk = (dir: string, prefix: string) => {
    const node = vfs.get(dir); if (!node) return;
    const subs = [...node.dirs].sort(), fileNames = [...node.files.keys()].sort();
    const all = [...subs.map((s) => ({ n: s, d: true })), ...fileNames.map((s) => ({ n: s, d: false }))];
    all.forEach((ent, i) => {
      const last = i === all.length - 1;
      const full = (dir ? dir + "/" : "") + ent.n;
      if (ent.d) {
        lines.push(`${prefix}${last ? "└── " : "├── "}<a class="e-dir" href="#" data-cd="${escAttr(full)}">${esc(ent.n)}/</a>`);
        walk(full, prefix + (last ? "    " : "│   "));
      } else {
        const f = node.files.get(ent.n);
        lines.push(`${prefix}${last ? "└── " : "├── "}<a class="e-file" href="${escAttr(ROOT + f.page)}">${esc(ent.n)}</a>`);
      }
    });
  };
  walk("", "");
  conPut(lines.join("\n"));
}

// ---- full-text search (lunr, bundled) -------------------------------------
let lunrIdx: any = null;
function ensureSearch() {
  if (lunrIdx) return lunrIdx;
  lunrIdx = lunr(function (this: any) {
    this.ref("path"); this.field("title", { boost: 5 }); this.field("content");
    SEARCH_DOCS.forEach((d) => this.add(d));
  });
  return lunrIdx;
}
function firstHit(content: string, q: string) {
  const lines = content.split("\n"); const ql = q.toLowerCase();
  for (let i = 0; i < lines.length; i++) if (lines[i].toLowerCase().indexOf(ql) >= 0)
    return { line: i + 1, text: lines[i].trim().slice(0, 120) };
  return null;
}
function cmdGrep(q: string) {
  q = (q || "").trim();
  if (!q) { conPut("usage: grep &lt;text&gt;", "err"); return; }
  let hits: { doc: any; score: number }[] = [];
  try {
    hits = ensureSearch().search(q).map((r: any) => ({ doc: SEARCH_DOCS.find((d) => d.path === r.ref), score: r.score }));
  } catch (e) {
    const ql = q.toLowerCase();
    hits = SEARCH_DOCS.filter((d) => (d.content + " " + d.title).toLowerCase().includes(ql)).map((d) => ({ doc: d, score: 1 }));
  }
  if (!hits.length) { conPut(`no matches for <b>${esc(q)}</b>`); return; }
  const term = q.split(/\s+/)[0];
  const rows = hits.slice(0, 14).map((h) => {
    const f = h.doc; const hit = firstHit(f.content, term) || firstHit(f.content, q);
    const anchor = hit ? "#L" + hit.line : "";
    const loc = f.path + (hit ? ":" + hit.line : "");
    const snip = hit ? hit.text : (f.title || "");
    return `<div class="e"><a class="e-file" href="${escAttr(ROOT + f.page + anchor)}">${esc(loc)}</a><span class="blurb">${esc(snip)}</span></div>`;
  }).join("");
  conPut(rows);
  conPut(`<span class="con-dim">${hits.length} file(s) matched</span>`);
}

function openConsole() { conEl.classList.add("open"); }
function closeConsole() { if (copyMode && copyMode.active) copyMode.exit(); conEl.classList.remove("open"); }
function toggleConsole() {
  if (copyMode && copyMode.active) copyMode.exit();
  conEl.classList.toggle("open");
  if (conEl.classList.contains("open")) conInput.focus();
}
function scrollBottom() { conScroll.scrollTop = conScroll.scrollHeight; }

// ---- markdown -------------------------------------------------------------
function renderMarkdown(_rec: any) {
  const srcEl = document.getElementById("src");
  const src = srcEl ? srcEl.textContent!.replace(/\n$/, "") : "";
  srcEl && srcEl.remove();
  const div = document.createElement("div");
  div.className = "md"; div.innerHTML = md(src);
  document.querySelector(".doc")!.appendChild(div);
}

function mdInline(text: string) {
  const codes: string[] = [];
  const S0 = String.fromCharCode(0xe000), S1 = String.fromCharCode(0xe001);
  text = text.replace(/`([^`]+)`/g, (_m, c) => { codes.push(c); return S0 + (codes.length - 1) + S1; });
  let html = linkifyPaths(text);
  html = html.replace(/\[([^\]]+)\]\(([^)]+)\)/g, (_m, t, u) => `<a href="${escAttr(u)}">${t}</a>`);
  html = html.replace(/(^|[^a-zA-Z0-9])(https?:\/\/[^\s<)]+)(?=$|[\s<).,])/g, (_m, p, u) => `${p}<a href="${escAttr(u)}">${esc(u)}</a>`);
  html = html.replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>");
  html = html.replace(/(^|[^*])\*([^*]+)\*/g, "$1<em>$2</em>");
  html = html.replace(new RegExp(S0 + "(\\d+)" + S1, "g"), (_m, k) => `<code>${esc(codes[+k])}</code>`);
  return html;
}

function md(src: string) {
  const lines = src.split("\n");
  let html = "", i = 0;
  const flushTable = (rows: string[]) => {
    if (rows.length < 2) return rows.map((r) => `<p>${mdInline(r)}</p>`).join("");
    const cells = (r: string) => r.replace(/^\||\|$/g, "").split("|").map((c) => c.trim());
    let t = "<table><thead><tr>" + cells(rows[0]).map((c) => `<th>${mdInline(c)}</th>`).join("") + "</tr></thead><tbody>";
    for (let r = 2; r < rows.length; r++) t += "<tr>" + cells(rows[r]).map((c) => `<td>${mdInline(c)}</td>`).join("") + "</tr>";
    return t + "</tbody></table>";
  };
  while (i < lines.length) {
    const line = lines[i];
    const fence = line.match(/^```(\w*)/);
    if (fence) {
      const lang = fence[1]; const buf: string[] = []; i++;
      while (i < lines.length && !/^```/.test(lines[i])) buf.push(lines[i++]);
      i++;
      const isSh = lang === "" || /^(sh|bash|shell|console)$/.test(lang);
      html += `<pre><code>${buf.map((l) => (isSh ? highlightShell(l) : esc(l))).join("\n")}</code></pre>`;
      continue;
    }
    const h = line.match(/^(#{1,6})\s+(.*)$/);
    if (h) { const lv = h[1].length; html += `<h${lv}>${mdInline(h[2])}</h${lv}>`; i++; continue; }
    if (/^\s*([-*_])\1{2,}\s*$/.test(line)) { html += "<hr>"; i++; continue; }
    if (/^>\s?/.test(line)) {
      const buf: string[] = [];
      while (i < lines.length && /^>\s?/.test(lines[i])) buf.push(lines[i++].replace(/^>\s?/, ""));
      html += `<blockquote>${md(buf.join("\n"))}</blockquote>`; continue;
    }
    if (/^\s*\|.*\|\s*$/.test(line)) {
      const buf: string[] = [];
      while (i < lines.length && /^\s*\|.*\|\s*$/.test(lines[i])) buf.push(lines[i++].trim());
      html += flushTable(buf); continue;
    }
    if (/^\s*([-*+]|\d+\.)\s+/.test(line)) {
      const ordered = /^\s*\d+\./.test(line); const buf: string[] = [];
      while (i < lines.length && /^\s*([-*+]|\d+\.)\s+/.test(lines[i]))
        buf.push(lines[i++].replace(/^\s*([-*+]|\d+\.)\s+/, ""));
      html += `<${ordered ? "ol" : "ul"}>` + buf.map((b) => `<li>${mdInline(b)}</li>`).join("") + `</${ordered ? "ol" : "ul"}>`;
      continue;
    }
    if (line.trim() === "") { i++; continue; }
    const buf: string[] = [];
    while (i < lines.length && lines[i].trim() !== "" && !/^(#{1,6}\s|```|>|\s*[-*+]\s|\s*\d+\.\s|\s*\|)/.test(lines[i]))
      buf.push(lines[i++]);
    html += `<p>${mdInline(buf.join(" "))}</p>`;
  }
  return html;
}

// ---- command palette ------------------------------------------------------
let palette: HTMLElement, paletteInput: HTMLInputElement, paletteResults: HTMLElement, palItems: any[] = [], palSel = 0;
function buildPalette(idx: { files: any[]; funcs: any[] }) {
  const items: any[] = [];
  (idx.files || []).forEach((f) => items.push({ kind: "file", label: f.path, blurb: f.blurb || "", href: ROOT + f.page }));
  (idx.funcs || []).forEach((fn) => items.push({ kind: "fn", label: fn.name + "()", blurb: fn.path, href: pageHref(fn.path, fn.line) }));
  palItems = items;

  const bg = document.createElement("div");
  bg.className = "palette-bg";
  bg.innerHTML = `<div class="palette"><input type="text" placeholder="Jump to a file or function&hellip;" spellcheck="false"><div class="results"></div></div>`;
  document.body.appendChild(bg);
  palette = bg;
  paletteInput = bg.querySelector("input")!;
  paletteResults = bg.querySelector(".results")!;
  bg.addEventListener("click", (e) => { if (e.target === bg) closePalette(); });
  paletteInput.addEventListener("input", renderResults);
  paletteInput.addEventListener("keydown", (e) => {
    const rows = paletteResults.querySelectorAll(".res");
    if (e.key === "ArrowDown") { palSel = Math.min(palSel + 1, rows.length - 1); e.preventDefault(); }
    else if (e.key === "ArrowUp") { palSel = Math.max(palSel - 1, 0); e.preventDefault(); }
    else if (e.key === "Enter") { const r = rows[palSel] as HTMLElement; if (r) location.href = r.dataset.href!; }
    else if (e.key === "Escape") { closePalette(); }
    else return;
    updateSel(rows);
  });
}
function fuzzy(q: string, s: string) {
  q = q.toLowerCase(); s = s.toLowerCase();
  if (!q) return true;
  let i = 0; for (const ch of s) if (ch === q[i]) i++;
  return i === q.length;
}
function renderResults() {
  const q = paletteInput.value.trim();
  const matches = palItems.filter((it) => fuzzy(q, it.label) || (q && it.blurb.toLowerCase().includes(q.toLowerCase()))).slice(0, 60);
  palSel = 0;
  if (!matches.length) { paletteResults.innerHTML = `<div class="empty">no matches</div>`; return; }
  paletteResults.innerHTML = matches.map((it, k) =>
    `<div class="res${k === 0 ? " sel" : ""}" data-href="${escAttr(it.href)}">` +
      `<span class="kind ${it.kind === "fn" ? "fn" : "file"}">${it.kind}</span>` +
      `<span class="label">${esc(it.label)}</span>` +
      `<span class="blurb">${esc(it.blurb)}</span></div>`
  ).join("");
  paletteResults.querySelectorAll(".res").forEach((r, k) => {
    r.addEventListener("mouseenter", () => { palSel = k; updateSel(paletteResults.querySelectorAll(".res")); });
    r.addEventListener("click", () => { location.href = (r as HTMLElement).dataset.href!; });
  });
}
function updateSel(rows: NodeListOf<Element>) {
  rows.forEach((r, k) => r.classList.toggle("sel", k === palSel));
  if (rows[palSel]) (rows[palSel] as HTMLElement).scrollIntoView({ block: "nearest" });
}
function openPalette() { palette.classList.add("open"); paletteInput.value = ""; renderResults(); paletteInput.focus(); }
function closePalette() { palette.classList.remove("open"); }

// ---- arrival at #Lnn ------------------------------------------------------
function handleHashTarget() {
  const flash = () => {
    const m = location.hash.match(/^#L(\d+)$/);
    if (!m) return;
    const row = document.getElementById("L" + m[1]);
    if (!row) return;
    row.scrollIntoView({ block: "center" });
    row.classList.add("flash");
    setTimeout(() => row.classList.remove("flash"), 1400);
  };
  requestAnimationFrame(() => requestAnimationFrame(flash));
  window.addEventListener("hashchange", flash);
}

// ---- boot -----------------------------------------------------------------
function boot() {
  body = document.body;
  ROOT = body.dataset.root || "";
  CUR = body.dataset.path || "";
  KIND = body.dataset.kind || "code";
  try { const t = localStorage.getItem("harsh-theme"); if (t) body.dataset.theme = t; } catch (e) {}
  document.addEventListener("keydown", (e) => {
    if (copyMode && copyMode.active) return; // copy mode owns the keyboard
    const inInput = /^(INPUT|TEXTAREA)$/.test(document.activeElement?.tagName || "");
    if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === "k") { e.preventDefault(); openPalette(); }
    else if (e.key === "`" && !inInput) { e.preventDefault(); toggleConsole(); }
    else if (e.key === "/" && !inInput) { e.preventDefault(); openPalette(); }
  });
  init();
}

if (typeof document !== "undefined") {
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", boot);
  else boot();
}

// exports for tests (tree-shaken out of the browser bundle entry path)
export {
  highlightShell, linkifyPaths, md, mdInline, buildMaps, buildVFS, resolvePath,
  fileAt, firstHit, ensureSearch, boot, INDEX, SEARCH_DOCS,
};
export const __test = {
  setPage(root: string, cur: string, kind = "code") { ROOT = root; CUR = cur; KIND = kind; },
  setCwd(v: string) { cwd = v; },
  setVfs(v: any) { vfs = v; },
  getLunr: () => lunrIdx,
};
