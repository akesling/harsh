// lineedit.ts — pure single-line editing primitives shared by the console's
// emacs and vi input keymaps. Each op takes the current value + cursor index and
// returns the new {value, cur}. Word motions reuse the char classifier from
// copymode so emacs and vi agree on what a "word" is.
import { cls } from "./copymode";

export type Edit = { value: string; cur: number };

export const firstNonBlank = (v: string) => { const m = v.match(/\S/); return m ? m.index! : 0; };

// word vs WORD: with big=true (W/B/E) punctuation counts as part of the word, so
// words are split only on whitespace.
const wc = (ch: string | undefined, big: boolean) => { const k = cls(ch); return big && k === "punct" ? "word" : k; };

// 'w' / 'W' — start of the next word (or end of line).
export function wordStartFwd(v: string, c: number, big = false): number {
  const n = v.length;
  if (c >= n) return n;
  const start = wc(v[c], big);
  let i = c;
  if (start !== "blank") while (i < n && wc(v[i], big) === start) i++;
  while (i < n && wc(v[i], big) === "blank") i++;
  return Math.min(i, n);
}
// 'b' / 'B' — start of the previous word.
export function wordBack(v: string, c: number, big = false): number {
  let i = c;
  if (i <= 0) return 0;
  i--;
  while (i > 0 && wc(v[i], big) === "blank") i--;
  const k = wc(v[i], big);
  while (i > 0 && wc(v[i - 1], big) === k && k !== "blank") i--;
  return i;
}
// 'e' / 'E' — end of the current/next word.
export function wordEnd(v: string, c: number, big = false): number {
  const n = v.length;
  if (c >= n - 1) return Math.max(0, n - 1);
  let i = c + 1;
  while (i < n - 1 && wc(v[i], big) === "blank") i++;
  const k = wc(v[i], big);
  while (i < n - 1 && wc(v[i + 1], big) === k && k !== "blank") i++;
  return i;
}

export const killToEnd = (v: string, c: number): Edit => ({ value: v.slice(0, c), cur: c });            // C-k / D
export const killToStart = (v: string, c: number): Edit => ({ value: v.slice(c), cur: 0 });             // C-u
export const deleteCharFwd = (v: string, c: number): Edit => ({ value: v.slice(0, c) + v.slice(c + 1), cur: c }); // C-d / x
export const clearLine = (): Edit => ({ value: "", cur: 0 });                                            // dd / cc

export function killWordBack(v: string, c: number): Edit {   // C-w / db
  const s = wordBack(v, c);
  return { value: v.slice(0, s) + v.slice(c), cur: s };
}
export function killWordFwd(v: string, c: number): Edit {    // M-d / dw
  const e = wordStartFwd(v, c);
  return { value: v.slice(0, c) + v.slice(e), cur: c };
}

// Insert `text` at the cursor (emacs C-y) or after it (vi p). Cursor lands just
// past the inserted text; callers can step back one for vi's on-last-char rule.
export function pasteAt(v: string, c: number, text: string, after = false): Edit {
  const at = after ? Math.min(v.length, c + 1) : c;
  return { value: v.slice(0, at) + text + v.slice(at), cur: at + text.length };
}
