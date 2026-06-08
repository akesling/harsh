import { test, expect } from "bun:test";
import {
  firstNonBlank, wordStartFwd, wordBack, wordEnd,
  killToEnd, killToStart, deleteCharFwd, clearLine, killWordBack, killWordFwd, pasteAt,
} from "./lineedit.ts";

test("pasteAt — at cursor (emacs yank) and after (vi p)", () => {
  expect(pasteAt("ab", 0, "X", false)).toEqual({ value: "Xab", cur: 1 });
  expect(pasteAt("ab", 0, "X", true)).toEqual({ value: "aXb", cur: 2 });
  expect(pasteAt("", 0, "hi", true)).toEqual({ value: "hi", cur: 2 });
});

const v = "foo bar baz";

test("word motions on a single line", () => {
  expect(wordStartFwd(v, 0)).toBe(4);   // foo -> bar
  expect(wordStartFwd(v, 4)).toBe(8);   // bar -> baz
  expect(wordBack(v, 8)).toBe(4);       // baz -> bar
  expect(wordEnd(v, 0)).toBe(2);        // -> end of foo
});

test("WORD motions (big) skip punctuation", () => {
  const s = "a.b cd";
  expect(wordStartFwd(s, 0)).toBe(1);         // w -> '.'
  expect(wordStartFwd(s, 0, true)).toBe(4);   // W -> 'cd'
  expect(wordBack(s, 4, true)).toBe(0);       // B -> start of a.b
  expect(wordEnd(s, 0, true)).toBe(2);        // E -> 'b'
});

test("firstNonBlank", () => {
  expect(firstNonBlank("  hi")).toBe(2);
  expect(firstNonBlank("x")).toBe(0);
});

test("kill / delete ops", () => {
  expect(killToEnd(v, 4)).toEqual({ value: "foo ", cur: 4 });
  expect(killToStart(v, 4)).toEqual({ value: "bar baz", cur: 0 });
  expect(deleteCharFwd(v, 0)).toEqual({ value: "oo bar baz", cur: 0 });
  expect(clearLine()).toEqual({ value: "", cur: 0 });
  expect(killWordBack(v, 7)).toEqual({ value: "foo  baz", cur: 4 }); // delete "bar"
  expect(killWordFwd(v, 4)).toEqual({ value: "foo baz", cur: 4 });   // delete "bar "
});
