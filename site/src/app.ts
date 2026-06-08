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
import { CopyMode, prefixCommand, findChar } from "./copymode";
import {
  firstNonBlank, wordStartFwd, wordBack, wordEnd,
  killToEnd, killToStart, deleteCharFwd, clearLine, killWordBack, killWordFwd, pasteAt, type Edit,
} from "./lineedit";

const REPO_URL = "https://github.com/akesling/harsh";

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
  const octocat =
    `<svg viewBox="0 0 16 16" width="18" height="18" aria-hidden="true"><path fill="currentColor" fill-rule="evenodd" d="M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27.68 0 1.36.09 2 .27 1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.013 8.013 0 0 0 16 8c0-4.42-3.58-8-8-8z"/></svg>`;
  bar.innerHTML =
    `<div class="brand"><span class="glyph">&#10095;</span><a href="${ROOT}index.html">harsh</a></div>` +
    `<div class="crumbs">${crumbHtml}</div>` +
    `<div class="spacer"></div>` +
    `<button class="btn mode-badge" id="input-mode" title="Input keymap — click to toggle vi / emacs"></button>` +
    `<button class="btn" id="toggle-console" title="Toggle terminal (\`)">&#10095;_ <kbd>&#96;</kbd></button>` +
    `<button class="btn" id="open-palette">Jump to&hellip; <kbd>&#8984;K</kbd></button>` +
    `<button class="btn" id="toggle-theme" title="Toggle theme">&#9681;</button>` +
    `<a class="iconlink" id="repo-link" href="${REPO_URL}" target="_blank" rel="noopener noreferrer" title="View on GitHub">${octocat}</a>`;
  body.prepend(bar);
  modeBadge = document.getElementById("input-mode")!;
  modeBadge.addEventListener("click", toggleInputMode);
  document.getElementById("toggle-console")!.addEventListener("click", toggleConsole);
  document.getElementById("open-palette")!.addEventListener("click", openPalette);
  document.getElementById("toggle-theme")!.addEventListener("click", toggleTheme);
  updateBadge();
}

function toggleTheme() {
  const next = body.dataset.theme === "light" ? "" : "light";
  if (next) body.dataset.theme = next; else delete body.dataset.theme;
  try { localStorage.setItem("harsh-theme", next); } catch (e) {}
}

// ---- input mode (vi / emacs) ----------------------------------------------
function updateBadge() {
  if (!modeBadge) return;
  modeBadge.textContent = inputMode;
  modeBadge.dataset.mode = inputMode;
}
function setInputMode(m: "emacs" | "vi") {
  inputMode = m; viInsert = true; viPending = ""; viFindPending = "";
  try { localStorage.setItem("harsh-inputmode", m); } catch (e) {}
  updateBadge(); updateModeStatus();
}
function toggleInputMode() { setInputMode(inputMode === "vi" ? "emacs" : "vi"); conInput && conInput.focus(); }

// vi command mode shows in the status line (unless copy mode / the leader own it)
function updateModeStatus() {
  if (!conStatus || (copyMode && copyMode.active) || prefixArmed) return;
  if (inputMode === "vi" && !viInsert) { conStatus.textContent = "-- NORMAL --  (i insert · hjkl · w/b/e · x · dd · /search via ^a [)"; conStatus.className = "con-status"; }
  else { conStatus.textContent = ""; conStatus.className = "con-status"; }
  // a thin caret look for vi-normal
  if (conInput) conInput.classList.toggle("vi-normal", inputMode === "vi" && !viInsert);
}

const caret = () => conInput.selectionStart ?? conInput.value.length;
function setInput(e: Edit) { conInput.value = e.value; conInput.setSelectionRange(e.cur, e.cur); }
function setCaret(i: number) { conInput.setSelectionRange(i, i); }
function histPrev() { if (histIdx > 0) { histIdx--; conInput.value = history[histIdx] || ""; setCaret(conInput.value.length); } }
function histNext() { if (histIdx < history.length) { histIdx++; conInput.value = history[histIdx] || ""; setCaret(conInput.value.length); } }

// Paste into the prompt at the cursor (emacs C-y / vi P) or after it (vi p).
function pasteInput(text: string, after = false, onLast = false) {
  if (!text) return;
  const r = pasteAt(conInput.value, caret(), text, after);
  setInput(onLast ? { value: r.value, cur: Math.max(0, r.cur - 1) } : r);
}
// tmux `prefix ]`: paste the buffer, preferring the system clipboard when it's
// readable (https/localhost), falling back to our internal buffer (file://).
function tmuxPaste() {
  conInput.focus();
  const fromBuffer = () => pasteInput(pasteBuffer, true);
  try {
    if (navigator.clipboard && navigator.clipboard.readText) {
      navigator.clipboard.readText().then((sys) => pasteInput(sys || pasteBuffer, true)).catch(fromBuffer);
      return;
    }
  } catch (e) { /* fall through */ }
  fromBuffer();
}

// emacs readline bindings (Ctrl uses e.key; Alt uses e.code, since macOS remaps
// Alt+letter). Returns true if it consumed the key. Ctrl+a stays the tmux leader.
function emacsKeydown(e: KeyboardEvent): boolean {
  const v = conInput.value, c = caret();
  if (e.ctrlKey && !e.altKey && !e.metaKey) {
    switch (e.key) {
      case "e": setCaret(v.length); break;
      case "b": setCaret(Math.max(0, c - 1)); break;
      case "f": setCaret(Math.min(v.length, c + 1)); break;
      case "k": pasteBuffer = v.slice(c); setInput(killToEnd(v, c)); break;
      case "u": pasteBuffer = v.slice(0, c); setInput(killToStart(v, c)); break;
      case "w": { const r = killWordBack(v, c); pasteBuffer = v.slice(r.cur, c); setInput(r); break; }
      case "y": pasteInput(pasteBuffer); break;           // yank (paste) the buffer
      case "p": histPrev(); break;
      case "n": histNext(); break;
      default: return false;
    }
    e.preventDefault(); return true;
  }
  if (e.altKey && !e.ctrlKey && !e.metaKey) {
    switch (e.code) {
      case "KeyF": setCaret(wordStartFwd(v, c)); break;
      case "KeyB": setCaret(wordBack(v, c)); break;
      case "KeyD": setInput(killWordFwd(v, c)); break;
      case "Backspace": setInput(killWordBack(v, c)); break;
      default: return false;
    }
    e.preventDefault(); return true;
  }
  return false;
}

// vi modal line editing. Insert mode lets typing/Enter/Tab/history fall through;
// Esc enters normal mode where keys are intercepted.
function viKeydown(e: KeyboardEvent): boolean {
  if (e.ctrlKey || e.metaKey || e.altKey) return false; // leave combos to emacs-style/leader
  const v = conInput.value, c = caret();
  if (viInsert) {
    if (e.key === "Escape") { e.preventDefault(); viInsert = false; setCaret(Math.max(0, c - 1)); updateModeStatus(); return true; }
    return false;
  }
  e.preventDefault();
  // f/F/t/T target: next key is the char to find on the line
  if (viFindPending) {
    const fp = viFindPending; viFindPending = "";
    if (e.key.length === 1) {
      const dir: 1 | -1 = fp === "f" || fp === "t" ? 1 : -1;
      const till = fp === "t" || fp === "T";
      setCaret(findChar(v, c, e.key, dir, till));
      viLastFind = { ch: e.key, dir, till };
    }
    updateModeStatus(); return true;
  }
  // operator pending (d / c) + motion
  if (viPending) {
    const op = viPending; viPending = "";
    let r: Edit | null = null, killed = "";
    if (e.key === "w" || e.key === "W") { const en = wordStartFwd(v, c, e.key === "W"); killed = v.slice(c, en); r = { value: v.slice(0, c) + v.slice(en), cur: c }; }
    else if (e.key === "e" || e.key === "E") { const en = wordEnd(v, c, e.key === "E") + 1; killed = v.slice(c, en); r = { value: v.slice(0, c) + v.slice(en), cur: c }; }
    else if (e.key === "b" || e.key === "B") { const s = wordBack(v, c, e.key === "B"); killed = v.slice(s, c); r = { value: v.slice(0, s) + v.slice(c), cur: s }; }
    else if (e.key === "$") { killed = v.slice(c); r = killToEnd(v, c); }
    else if (e.key === op) { killed = v; r = clearLine(); }   // dd / cc
    if (r) { if (killed) pasteBuffer = killed; setInput(r); if (op === "c") viInsert = true; }
    updateModeStatus(); return true;
  }
  switch (e.key) {
    case "h": case "ArrowLeft": setCaret(Math.max(0, c - 1)); break;
    case "l": case "ArrowRight": case " ": setCaret(Math.min(Math.max(0, v.length - 1), c + 1)); break;
    case "0": setCaret(0); break;
    case "$": setCaret(Math.max(0, v.length - 1)); break;
    case "^": setCaret(firstNonBlank(v)); break;
    case "w": setCaret(wordStartFwd(v, c)); break;
    case "b": setCaret(wordBack(v, c)); break;
    case "e": setCaret(wordEnd(v, c)); break;
    case "W": setCaret(wordStartFwd(v, c, true)); break;
    case "B": setCaret(wordBack(v, c, true)); break;
    case "E": setCaret(wordEnd(v, c, true)); break;
    case "f": case "F": case "t": case "T": viFindPending = e.key; break;
    case ";": if (viLastFind) setCaret(findChar(v, c, viLastFind.ch, viLastFind.dir, viLastFind.till)); break;
    case ",": if (viLastFind) setCaret(findChar(v, c, viLastFind.ch, (viLastFind.dir * -1) as 1 | -1, viLastFind.till)); break;
    case "x": { pasteBuffer = v.slice(c, c + 1) || pasteBuffer; const r = deleteCharFwd(v, c); setInput({ value: r.value, cur: Math.min(r.cur, Math.max(0, r.value.length - 1)) }); break; }
    case "D": pasteBuffer = v.slice(c) || pasteBuffer; setInput(killToEnd(v, c)); break;
    case "C": pasteBuffer = v.slice(c) || pasteBuffer; setInput(killToEnd(v, c)); viInsert = true; break;
    case "p": pasteInput(pasteBuffer, true, true); break;   // paste after cursor
    case "P": pasteInput(pasteBuffer, false, true); break;  // paste before cursor
    case "d": viPending = "d"; break;
    case "c": viPending = "c"; break;
    case "i": viInsert = true; break;
    case "a": setCaret(Math.min(v.length, c + 1)); viInsert = true; break;
    case "A": setCaret(v.length); viInsert = true; break;
    case "I": setCaret(firstNonBlank(v)); viInsert = true; break;
    case "k": histPrev(); break;
    case "j": histNext(); break;
    case "Enter": { viInsert = true; const val = conInput.value; conInput.value = ""; runCommand(val); break; }
    default: break;
  }
  updateModeStatus(); return true;
}

// vim-style movement on the document (vi mode, when not typing in the terminal):
// j/k scroll a few lines, ^d/^u half a page, gg/G jump to top/bottom.
let pageGPending = false;
function pageNavKey(e: KeyboardEvent): boolean {
  const step = 80, half = Math.floor((window.innerHeight || 800) / 2);
  const max = (document.documentElement.scrollHeight || document.body.scrollHeight) + 1000;
  if (e.ctrlKey && !e.metaKey && !e.altKey) {
    if (e.key === "d") { window.scrollBy(0, half); return true; }
    if (e.key === "u") { window.scrollBy(0, -half); return true; }
    return false;
  }
  if (e.metaKey || e.altKey) return false;
  if (pageGPending) { pageGPending = false; if (e.key === "g") { window.scrollTo(0, 0); return true; } }   // gg — instant jump to top
  switch (e.key) {
    case "j": window.scrollBy(0, step); return true;
    case "k": window.scrollBy(0, -step); return true;
    case "d": window.scrollBy(0, half); return true;   // also bare d/u for convenience
    case "u": window.scrollBy(0, -half); return true;
    case "g": pageGPending = true; return true;
    case "G": window.scrollTo(0, max); return true;    // instant jump to bottom
    default: return false;
  }
}

// ---- layout ---------------------------------------------------------------
function buildLayout() {
  const main = document.createElement("div"); main.className = "main";
  const doc = document.createElement("div"); doc.className = "doc";
  main.appendChild(doc);
  const footer = document.createElement("footer");
  footer.className = "site-footer";
  footer.innerHTML = `<span>&copy; 2026 <a href="${REPO_URL}" target="_blank" rel="noopener noreferrer">Adjective Noun</a></span>`;
  main.appendChild(footer);
  body.appendChild(main);
}

// ---- pop-down terminal ----------------------------------------------------
let conEl: HTMLElement, conScroll: HTMLElement, conInput: HTMLInputElement, conPrompt: HTMLElement, conStatus: HTMLElement;
let copyMode: CopyMode;
let prefixArmed = false, prefixTimer: any = null;   // tmux Ctrl+a leader
let inputMode: "emacs" | "vi" = "emacs";            // prompt editing keymap
let viInsert = true;                                // vi sub-mode (insert vs normal)
let viPending = "";                                 // vi operator pending (d / c)
let viFindPending = "";                             // vi f/F/t/T awaiting target char
let viLastFind: { ch: string; dir: 1 | -1; till: boolean } | null = null;
let pasteBuffer = "";                               // tmux-style buffer: last yank/kill
let modeBadge: HTMLElement | null = null;
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
      `<button class="con-toggle" id="con-toggle" title="Close terminal (^d on empty prompt, or \`)">&#9662;</button>` +
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
    copyText: (s) => { pasteBuffer = s; copyText(s); },   // yank fills the paste buffer too
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
  conPut(`<span class="con-dim">harsh source tour. Type <b>help</b>, or <b>ls</b> to look around. <b>^a [</b> (or <b>Esc</b>) = vi copy mode · <b>\`</b> opens · <b>^d</b> closes.</span>`);
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
  // tmux leader: Ctrl+a, then a command key ([ = copy mode, like tmux). A second
  // Ctrl+a (^a ^a) sends a literal C-a = beginning of line, the tmux convention.
  if (prefixArmed) {
    e.preventDefault(); disarmPrefix();
    if (e.ctrlKey && e.key.toLowerCase() === "a") { setCaret(0); return; }
    const act = prefixCommand(e.key);
    if (act === "copy") { openConsole(); copyMode.enter(); }
    else if (act === "paste") { tmuxPaste(); }
    else if (act === "help") { cmdHelp(); }
    return; // the key after the leader is consumed either way
  }
  if (e.ctrlKey && !e.metaKey && !e.altKey && e.key.toLowerCase() === "a") {
    e.preventDefault();
    prefixArmed = true;
    conStatus.textContent = "^a —  [ copy/select · ] paste · ^a line start · ? help";
    conStatus.className = "con-status";
    clearTimeout(prefixTimer);
    prefixTimer = setTimeout(disarmPrefix, 2500);
    return;
  }
  // Ctrl-D — shell EOF: closes the terminal on an empty prompt, otherwise it's
  // emacs delete-char-forward. (` stays a literal character you can type.)
  // stopPropagation so closing (which blurs the prompt) doesn't let the
  // document-level handler treat this same ^d as a page scroll.
  if (e.ctrlKey && !e.metaKey && !e.altKey && e.key.toLowerCase() === "d") {
    e.preventDefault(); e.stopPropagation();
    if (conInput.value === "") closeConsole();
    else setInput(deleteCharFwd(conInput.value, caret()));
    return;
  }

  // mode-specific line editing
  if (inputMode === "vi" ? viKeydown(e) : emacsKeydown(e)) return;

  if (e.key === "Enter") { const v = conInput.value; conInput.value = ""; runCommand(v); }
  else if (e.key === "ArrowUp") { e.preventDefault(); histPrev(); }
  else if (e.key === "ArrowDown") { e.preventDefault(); histNext(); }
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
    "  <b>/</b> <b>?</b> search · <b>n N</b> repeat · <b>Space</b> select (or <b>V</b> line) · <b>y</b>/<b>⏎</b> yank · <b>q</b> leave",
    "  paste the yanked buffer back into the prompt with <b>^a ]</b> (tmux), <b>^y</b> (emacs), or <b>p</b>/<b>P</b> (vi)",
    "",
    "prompt keymap (badge, top right — click to toggle):",
    "  <b>emacs</b>: ^e ^b ^f ^k ^u ^w ^d ^y · M-f/b/d · ^p/^n history · ^a leader (^a^a = line start)",
    "  <b>vi</b>: Esc → command — h l 0 ^ $ · w b e / W B E · f F t T ; , · x D C · dd dw cw · p P · i a A I",
    "  <b>vi page</b> (when not typing): <b>j/k</b> scroll · <b>^d/^u</b> half-page · <b>gg/G</b> top/bottom",
    "",
    "shortcuts: <b>Tab</b> completes · <b>↑/↓</b> history · <b>`</b> opens · <b>^d</b> closes (empty prompt) · <b>⌘K</b> palette",
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
function closeConsole() { if (copyMode && copyMode.active) copyMode.exit(); conEl.classList.remove("open"); conInput && conInput.blur(); }
function toggleConsole() {
  if (copyMode && copyMode.active) copyMode.exit();
  conEl.classList.toggle("open");
  if (conEl.classList.contains("open")) conInput.focus(); else conInput.blur();
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
  try { const m = localStorage.getItem("harsh-inputmode"); if (m === "vi" || m === "emacs") inputMode = m; } catch (e) {}
  document.addEventListener("keydown", (e) => {
    if (copyMode && copyMode.active) return; // copy mode owns the keyboard
    const inInput = /^(INPUT|TEXTAREA)$/.test(document.activeElement?.tagName || "");
    if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === "k") { e.preventDefault(); openPalette(); }
    else if (e.key === "`" && !inInput) { e.preventDefault(); toggleConsole(); }
    else if (e.key === "/" && !inInput) { e.preventDefault(); openPalette(); }
    // vi mode: vim-style page movement when not typing in the terminal.
    else if (inputMode === "vi" && !inInput && pageNavKey(e)) { e.preventDefault(); }
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
