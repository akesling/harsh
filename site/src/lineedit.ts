// lineedit.ts — pure single-line editing primitives shared by the console's
// emacs and vi input keymaps. Each op takes the current value + cursor index and
// returns the new {value, cur}. Word motions reuse the char classifier from
// copymode so emacs and vi agree on what a "word" is.
import { cls } from "./copymode";

export type Edit = { value: string; cur: number };

export const firstNonBlank = (v: string) => { const m = v.match(/\S/); return m ? m.index! : 0; };

// 'w' — start of the next word (or end of line).
export function wordStartFwd(v: string, c: number): number {
  const n = v.length;
  if (c >= n) return n;
  const start = cls(v[c]);
  let i = c;
  if (start !== "blank") while (i < n && cls(v[i]) === start) i++;
  while (i < n && cls(v[i]) === "blank") i++;
  return Math.min(i, n);
}
// 'b' — start of the previous word.
export function wordBack(v: string, c: number): number {
  let i = c;
  if (i <= 0) return 0;
  i--;
  while (i > 0 && cls(v[i]) === "blank") i--;
  const k = cls(v[i]);
  while (i > 0 && cls(v[i - 1]) === k && k !== "blank") i--;
  return i;
}
// 'e' — end of the current/next word.
export function wordEnd(v: string, c: number): number {
  const n = v.length;
  if (c >= n - 1) return Math.max(0, n - 1);
  let i = c + 1;
  while (i < n - 1 && cls(v[i]) === "blank") i++;
  const k = cls(v[i]);
  while (i < n - 1 && cls(v[i + 1]) === k && k !== "blank") i++;
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
