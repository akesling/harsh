// copymode.ts — a tmux/vim copy-mode for the site terminal.
//
// Press Esc in the console to drop into a modal, keyboard-only navigation +
// selection mode over the scrollback, modelled on tmux's copy-mode-vi:
//   motions   h j k l, w b e, 0 ^ $, gg G, Ctrl-d/u/f/b, H M L, numeric counts
//   search    / ? to search, n / N to repeat
//   visual    v (char) / V (line); motions extend; o swaps ends
//   yank      y or Enter copies the selection to the clipboard and exits
//   leave     q / Esc / i / a returns to typing
//
// The pure motion/selection helpers are exported and unit-tested; the CopyMode
// class wires them to the DOM (render, keys, clipboard).
//
// Entered via the tmux prefix (Ctrl+a then [) or Esc.

export type Pos = { r: number; c: number };

// tmux prefix (Ctrl+a) command table: maps the key pressed after the prefix to
// an action, or null if it isn't bound. `[` enters copy mode, like tmux.
export type PrefixAction = "copy" | "paste" | "help";
export function prefixCommand(key: string): PrefixAction | null {
  switch (key) {
    case "[": return "copy";
    case "]": return "paste";   // tmux: paste the buffer
    case "?": return "help";
    default: return null;
  }
}

export const cls = (ch: string | undefined): "blank" | "word" | "punct" =>
  ch === undefined || ch === "" ? "blank"
    : /\s/.test(ch) ? "blank"
    : /[A-Za-z0-9_]/.test(ch) ? "word"
    : "punct";

// Flatten lines into a single string (newline-joined) plus the start index of
// each row, so motions/search can work in a simple linear space.
export function flatten(lines: string[]) {
  const rowStart: number[] = [];
  let idx = 0;
  for (let r = 0; r < lines.length; r++) { rowStart.push(idx); idx += lines[r].length + 1; }
  return { text: lines.join("\n"), rowStart };
}
export function posToIdx(rowStart: number[], p: Pos) { return rowStart[p.r] + p.c; }
export function idxToPos(lines: string[], rowStart: number[], idx: number): Pos {
  if (idx < 0) idx = 0;
  let r = 0;
  while (r + 1 < rowStart.length && rowStart[r + 1] <= idx) r++;
  const c = Math.max(0, Math.min(idx - rowStart[r], lines[r].length));
  return { r, c };
}

// vim word motions over the flat text, returning a clamped index.
export function wordFwd(text: string, i: number): number {
  const n = text.length;
  if (i >= n - 1) return n - 1;
  const start = cls(text[i]);
  if (start !== "blank") while (i < n && cls(text[i]) === start) i++;
  while (i < n && cls(text[i]) === "blank") i++;
  return Math.min(i, n - 1);
}
export function wordBack(text: string, i: number): number {
  if (i <= 0) return 0;
  i--;
  while (i > 0 && cls(text[i]) === "blank") i--;
  const c = cls(text[i]);
  while (i > 0 && cls(text[i - 1]) === c && c !== "blank") i--;
  return i;
}
export function wordEnd(text: string, i: number): number {
  const n = text.length;
  if (i >= n - 1) return n - 1;
  i++;
  while (i < n - 1 && cls(text[i]) === "blank") i++;
  const c = cls(text[i]);
  while (i < n - 1 && cls(text[i + 1]) === c && c !== "blank") i++;
  return i;
}

// case-insensitive search from index `from` (exclusive), wrapping around.
export function searchFrom(text: string, from: number, q: string, dir: 1 | -1): number {
  if (!q) return -1;
  const hay = text.toLowerCase(), needle = q.toLowerCase();
  if (dir === 1) {
    let i = hay.indexOf(needle, from + 1);
    if (i < 0) i = hay.indexOf(needle, 0);
    return i;
  } else {
    let i = hay.lastIndexOf(needle, from - 1);
    if (i < 0) i = hay.lastIndexOf(needle);
    return i;
  }
}

export const firstNonBlank = (line: string) => {
  const m = line.match(/\S/);
  return m ? m.index! : 0;
};

// Ordered selection text. a,b need not be ordered; linewise takes whole rows.
export function selectionText(lines: string[], a: Pos, b: Pos, linewise: boolean): string {
  let lo = a, hi = b;
  if (hi.r < lo.r || (hi.r === lo.r && hi.c < lo.c)) { lo = b; hi = a; }
  if (linewise) return lines.slice(lo.r, hi.r + 1).join("\n");
  const { text, rowStart } = flatten(lines);
  return text.slice(posToIdx(rowStart, lo), posToIdx(rowStart, hi) + 1);
}

type Mode = "normal" | "visual" | "vline" | "search";

export interface CopyOpts {
  scroll: HTMLElement;          // the scrollback element (con-scroll)
  status: HTMLElement;          // a status-line element
  onEnter: () => void;          // e.g. blur the input
  onExit: () => void;           // e.g. focus the input
  copyText: (s: string) => void;
}

export class CopyMode {
  private o: CopyOpts;
  active = false;
  private lines: string[] = [""];
  private cur: Pos = { r: 0, c: 0 };
  private anchor: Pos = { r: 0, c: 0 };
  private mode: Mode = "normal";
  private want = 0;            // desired column for j/k
  private count = "";         // numeric prefix
  private gpending = false;   // saw a 'g'
  private query = "";
  private lastQuery = "";
  private searchDir: 1 | -1 = 1;
  private savedHtml = "";
  private pre: HTMLElement | null = null;
  private boundKey = (e: KeyboardEvent) => this.onKey(e);

  constructor(o: CopyOpts) { this.o = o; }

  // test hook: inspect internal state
  debugState() { return { mode: this.mode, cur: { ...this.cur }, lines: this.lines.slice() }; }

  enter() {
    if (this.active) return;
    const txt = (this.o.scroll.innerText || "").replace(/\s+$/, "");
    this.lines = txt.length ? txt.split("\n") : [""];
    this.cur = { r: this.lines.length - 1, c: 0 };
    this.anchor = { ...this.cur };
    this.mode = "normal"; this.want = 0; this.count = ""; this.gpending = false; this.query = "";
    this.savedHtml = this.o.scroll.innerHTML;
    this.o.scroll.innerHTML = `<pre class="copybuf"></pre>`;
    this.pre = this.o.scroll.querySelector(".copybuf");
    this.active = true;
    this.o.onEnter();
    document.addEventListener("keydown", this.boundKey, true);
    this.render();
  }

  exit() {
    if (!this.active) return;
    this.active = false;
    document.removeEventListener("keydown", this.boundKey, true);
    this.o.scroll.innerHTML = this.savedHtml;
    this.o.scroll.scrollTop = this.o.scroll.scrollHeight;
    this.o.status.textContent = "";
    this.o.status.className = "con-status";
    this.pre = null;
    this.o.onExit();
  }

  private line(r = this.cur.r) { return this.lines[r] ?? ""; }
  private maxCol(r = this.cur.r) { return Math.max(0, this.line(r).length - 1); }
  private clampCur() {
    this.cur.r = Math.max(0, Math.min(this.cur.r, this.lines.length - 1));
    const lim = this.mode === "visual" || this.mode === "vline" ? this.line().length : this.maxCol();
    this.cur.c = Math.max(0, Math.min(this.cur.c, lim));
  }
  private viewRows() {
    const lh = this.pre && this.lines.length ? this.pre.scrollHeight / this.lines.length : 20;
    return Math.max(1, Math.floor(this.o.scroll.clientHeight / (lh || 20)));
  }
  private takeCount(def = 1) { const n = this.count ? parseInt(this.count, 10) : def; this.count = ""; return Math.max(1, n); }

  private idxMotion(fn: (text: string, i: number) => number, times: number) {
    const { text, rowStart } = flatten(this.lines);
    let i = posToIdx(rowStart, this.cur);
    for (let k = 0; k < times; k++) i = fn(text, i);
    this.cur = idxToPos(this.lines, rowStart, i);
    this.want = this.cur.c;
  }

  private doSearch(dir: 1 | -1, fromCursor = true) {
    if (!this.lastQuery) return;
    const { text, rowStart } = flatten(this.lines);
    const from = fromCursor ? posToIdx(rowStart, this.cur) : -1;
    const i = searchFrom(text, from, this.lastQuery, dir);
    if (i >= 0) { this.cur = idxToPos(this.lines, rowStart, i); this.want = this.cur.c; }
  }

  private yank() {
    const text = selectionText(this.lines, this.anchor, this.cur, this.mode === "vline");
    this.o.copyText(text);
    this.flash();
    this.exit();
  }

  private flash() {
    this.o.status.textContent = "yanked ✓";
    this.o.status.className = "con-status flash";
  }

  private onKey(e: KeyboardEvent): void {
    if (!this.active) return;
    const handled = this.handleKey(e);
    if (handled) { e.preventDefault(); e.stopPropagation(); }
  }

  // returns true if the key was consumed by copy mode
  handleKey(e: KeyboardEvent): boolean {
    const k = e.key;

    // search sub-mode: capture the query
    if (this.mode === "search") {
      if (k === "Enter") { this.lastQuery = this.query; this.mode = "normal"; this.doSearch(this.searchDir); this.render(); }
      else if (k === "Escape") { this.mode = "normal"; this.render(); }
      else if (k === "Backspace") { this.query = this.query.slice(0, -1); this.render(); }
      else if (k.length === 1 && !e.metaKey && !e.ctrlKey) { this.query += k; this.render(); }
      return true;
    }

    // Ctrl- scroll/page motions
    if (e.ctrlKey) {
      const vr = this.viewRows();
      if (k === "d") { this.cur.r += Math.floor(vr / 2); }
      else if (k === "u") { this.cur.r -= Math.floor(vr / 2); }
      else if (k === "f") { this.cur.r += vr; }
      else if (k === "b") { this.cur.r -= vr; }
      else return false; // let other Ctrl combos through
      this.cur.c = this.want; this.clampCur(); this.render(); return true;
    }
    if (e.metaKey || e.altKey) return false;

    // numeric counts
    if (/[1-9]/.test(k) || (k === "0" && this.count !== "")) { this.count += k; this.render(); return true; }

    // gg
    if (this.gpending) {
      this.gpending = false;
      if (k === "g") { this.cur.r = 0; this.cur.c = 0; this.want = 0; this.clampCur(); this.render(); return true; }
    }

    switch (k) {
      case "h": case "ArrowLeft": this.cur.c = Math.max(0, this.cur.c - this.takeCount()); this.want = this.cur.c; break;
      case "l": case "ArrowRight": case " ": this.cur.c += this.takeCount(); this.clampCur(); this.want = this.cur.c; break;
      case "j": case "ArrowDown": this.cur.r += this.takeCount(); this.cur.c = this.want; this.clampCur(); break;
      case "k": case "ArrowUp": this.cur.r -= this.takeCount(); this.cur.c = this.want; this.clampCur(); break;
      case "0": this.cur.c = 0; this.want = 0; break;
      case "^": this.cur.c = firstNonBlank(this.line()); this.want = this.cur.c; break;
      case "$": this.cur.c = this.maxCol(); this.want = 1e9; break;
      case "w": this.idxMotion(wordFwd, this.takeCount()); break;
      case "b": this.idxMotion(wordBack, this.takeCount()); break;
      case "e": this.idxMotion(wordEnd, this.takeCount()); break;
      case "g": this.gpending = true; break;
      case "G": this.cur.r = this.count ? this.takeCount() - 1 : this.lines.length - 1; this.cur.c = 0; this.clampCur(); break;
      case "H": this.cur.r = this.topRow(); this.cur.c = this.want; this.clampCur(); break;
      case "M": this.cur.r = this.topRow() + Math.floor(this.viewRows() / 2); this.cur.c = this.want; this.clampCur(); break;
      case "L": this.cur.r = this.topRow() + this.viewRows() - 1; this.cur.c = this.want; this.clampCur(); break;
      case "/": this.mode = "search"; this.searchDir = 1; this.query = ""; break;
      case "?": this.mode = "search"; this.searchDir = -1; this.query = ""; break;
      case "n": this.doSearch(this.searchDir); break;
      case "N": this.doSearch(this.searchDir === 1 ? -1 : 1); break;
      case "v":
        if (this.mode === "visual") { this.mode = "normal"; } else { this.anchor = { ...this.cur }; this.mode = "visual"; }
        break;
      case "V":
        if (this.mode === "vline") { this.mode = "normal"; } else { this.anchor = { ...this.cur }; this.mode = "vline"; }
        break;
      case "o":
        if (this.mode === "visual" || this.mode === "vline") { const t = this.anchor; this.anchor = this.cur; this.cur = t; }
        break;
      case "y": case "Enter":
        if (this.mode === "visual" || this.mode === "vline") { this.yank(); return true; }
        if (k === "y") { this.anchor = { r: this.cur.r, c: 0 }; const t = selectionText(this.lines, this.anchor, this.cur, true); this.o.copyText(t); this.flash(); this.exit(); return true; }
        break;
      case "Y": this.anchor = { r: this.cur.r, c: 0 }; { const t = selectionText(this.lines, this.anchor, this.cur, true); this.o.copyText(t); } this.flash(); this.exit(); return true;
      case "Escape": case "q":
        if (this.mode === "visual" || this.mode === "vline") { this.mode = "normal"; break; }
        this.exit(); return true;
      case "i": case "a": case ":": this.exit(); return true;
      default:
        // swallow other bare keys to keep the mode tight; let unmapped combos pass
        if (k.length !== 1) return false;
    }
    this.clampCur();
    this.render();
    return true;
  }

  private topRow() {
    const lh = this.pre && this.lines.length ? this.pre.scrollHeight / this.lines.length : 20;
    return Math.max(0, Math.floor(this.o.scroll.scrollTop / (lh || 20)));
  }

  render() {
    if (!this.pre) return;
    const range = (this.mode === "visual" || this.mode === "vline")
      ? this.ordered() : null;
    const linewise = this.mode === "vline";
    const { rowStart } = flatten(this.lines);
    const ia = range ? posToIdx(rowStart, range.lo) : -1;
    const ib = range ? posToIdx(rowStart, range.hi) : -1;

    const esc = (s: string) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
    let html = "";
    for (let r = 0; r < this.lines.length; r++) {
      const line = this.lines[r];
      let run = "", out = "";
      const flush = () => { if (run) { out += esc(run); run = ""; } };
      for (let c = 0; c < line.length; c++) {
        const idx = rowStart[r] + c;
        const sel = range && (linewise ? r >= range.lo.r && r <= range.hi.r : idx >= ia && idx <= ib);
        const isCur = r === this.cur.r && c === this.cur.c;
        if (sel || isCur) { flush(); out += `<span class="${isCur ? "cur" : "sel"}">${esc(line[c])}</span>`; }
        else run += line[c];
      }
      flush();
      if (this.cur.r === r && this.cur.c >= line.length) out += `<span class="cur"> </span>`;
      else if (range && linewise && r >= range.lo.r && r <= range.hi.r && line.length === 0) out += `<span class="sel"> </span>`;
      html += out + "\n";
    }
    this.pre.innerHTML = html;
    this.updateStatus();
    const cur = this.pre.querySelector(".cur");
    if (cur) (cur as HTMLElement).scrollIntoView({ block: "nearest" });
  }

  private ordered() {
    let lo = this.anchor, hi = this.cur;
    if (hi.r < lo.r || (hi.r === lo.r && hi.c < lo.c)) { lo = this.cur; hi = this.anchor; }
    return { lo, hi };
  }

  private updateStatus() {
    const s = this.o.status;
    s.className = "con-status";
    if (this.mode === "search") { s.textContent = (this.searchDir === 1 ? "/" : "?") + this.query; return; }
    const pos = `${this.cur.r + 1}:${this.cur.c + 1}`;
    const tag = this.mode === "visual" ? "-- VISUAL --" : this.mode === "vline" ? "-- VISUAL LINE --" : "-- COPY --";
    const hint = this.mode === "normal"
      ? "  hjkl move · w/b word · v select · y yank · / search · q quit"
      : "  motions extend · y/⏎ yank · o swap · Esc cancel";
    const cnt = this.count ? `  ${this.count}` : "";
    s.textContent = `${tag}  ${pos}${cnt}${hint}`;
  }
}
