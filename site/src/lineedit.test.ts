import { test, expect } from "bun:test";
import {
  firstNonBlank, wordStartFwd, wordBack, wordEnd,
  killToEnd, killToStart, deleteCharFwd, clearLine, killWordBack, killWordFwd,
} from "./lineedit.ts";

const v = "foo bar baz";

test("word motions on a single line", () => {
  expect(wordStartFwd(v, 0)).toBe(4);   // foo -> bar
  expect(wordStartFwd(v, 4)).toBe(8);   // bar -> baz
  expect(wordBack(v, 8)).toBe(4);       // baz -> bar
  expect(wordEnd(v, 0)).toBe(2);        // -> end of foo
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
