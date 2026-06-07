import { test, expect } from "bun:test";
import {
  cls, flatten, posToIdx, idxToPos, wordFwd, wordBack, wordEnd, searchFrom,
  firstNonBlank, selectionText, CopyMode,
} from "./copymode.ts";

const lines = ["foo bar  baz", "  hello world", "qux"];
const { text, rowStart } = flatten(lines);

test("cls classifies characters", () => {
  expect(cls("a")).toBe("word");
  expect(cls("_")).toBe("word");
  expect(cls(" ")).toBe("blank");
  expect(cls(".")).toBe("punct");
  expect(cls(undefined)).toBe("blank");
});

test("flatten + pos/idx round-trip", () => {
  expect(rowStart).toEqual([0, 13, 27]);
  expect(text.length).toBe(30);
  for (const p of [{ r: 0, c: 0 }, { r: 1, c: 8 }, { r: 2, c: 2 }]) {
    expect(idxToPos(lines, rowStart, posToIdx(rowStart, p))).toEqual(p);
  }
});

test("word motions (w/b/e), including across line boundaries", () => {
  expect(wordFwd(text, 0)).toBe(4);   // foo -> bar
  expect(wordFwd(text, 4)).toBe(9);   // bar -> baz (skips 2 spaces)
  expect(wordFwd(text, 9)).toBe(15);  // baz -> hello (next line)
  expect(wordBack(text, 15)).toBe(9); // hello -> baz
  expect(wordEnd(text, 0)).toBe(2);   // -> end of foo
});

test("search is case-insensitive and wraps", () => {
  expect(idxToPos(lines, rowStart, searchFrom(text, 0, "WORLD", 1))).toEqual({ r: 1, c: 8 });
  // from end, forward search wraps back to an earlier match
  expect(searchFrom(text, text.length - 1, "foo", 1)).toBe(0);
});

test("firstNonBlank", () => {
  expect(firstNonBlank("  hello")).toBe(2);
  expect(firstNonBlank("x")).toBe(0);
});

test("selectionText charwise and linewise (order-independent)", () => {
  expect(selectionText(lines, { r: 0, c: 0 }, { r: 0, c: 2 }, false)).toBe("foo");
  expect(selectionText(lines, { r: 0, c: 2 }, { r: 0, c: 0 }, false)).toBe("foo"); // reversed
  expect(selectionText(lines, { r: 0, c: 0 }, { r: 1, c: 4 }, false)).toBe("foo bar  baz\n  hel");
  expect(selectionText(lines, { r: 0, c: 0 }, { r: 1, c: 0 }, true)).toBe("foo bar  baz\n  hello world");
});

// ---- controller state machine (minimal fake DOM) --------------------------
function fakeEl(props: any = {}): any {
  return {
    innerText: props.innerText || "", innerHTML: "", className: "", textContent: "",
    clientHeight: 120, scrollHeight: 60, scrollTop: 0,
    scrollIntoView() {},
    querySelector() { return fakeEl(); },
  };
}
function key(k: string, mods: any = {}) { return { key: k, preventDefault() {}, stopPropagation() {}, ...mods } as any; }

test("CopyMode: enter, move, visual-select, yank", () => {
  (globalThis as any).document = { addEventListener() {}, removeEventListener() {} };
  const scroll = fakeEl({ innerText: "alpha beta\ngamma delta\nepsilon" });
  let copied = "";
  const cm = new CopyMode({
    scroll: scroll as any, status: fakeEl() as any,
    onEnter() {}, onExit() {}, copyText(s) { copied = s; },
  });
  cm.enter();
  let st = cm.debugState();
  expect(st.mode).toBe("normal");
  expect(st.lines).toEqual(["alpha beta", "gamma delta", "epsilon"]);
  expect(st.cur).toEqual({ r: 2, c: 0 });          // enters at the bottom

  cm.handleKey(key("g")); cm.handleKey(key("g"));    // gg -> top
  expect(cm.debugState().cur).toEqual({ r: 0, c: 0 });
  cm.handleKey(key("w"));                             // -> "beta"
  expect(cm.debugState().cur).toEqual({ r: 0, c: 6 });
  cm.handleKey(key("v"));                             // visual from col 6
  cm.handleKey(key("$"));                             // extend to end of line
  expect(cm.debugState().mode).toBe("visual");
  cm.handleKey(key("y"));                             // yank
  expect(copied).toBe("beta");
  expect(cm.active).toBe(false);                      // yank exits copy mode
});

test("CopyMode: counts and Escape leaves", () => {
  (globalThis as any).document = { addEventListener() {}, removeEventListener() {} };
  const scroll = fakeEl({ innerText: "l0\nl1\nl2\nl3\nl4" });
  const cm = new CopyMode({ scroll: scroll as any, status: fakeEl() as any, onEnter() {}, onExit() {}, copyText() {} });
  cm.enter();
  cm.handleKey(key("g")); cm.handleKey(key("g"));    // top
  cm.handleKey(key("3")); cm.handleKey(key("j"));    // 3j -> row 3
  expect(cm.debugState().cur.r).toBe(3);
  cm.handleKey(key("q"));
  expect(cm.active).toBe(false);
});
