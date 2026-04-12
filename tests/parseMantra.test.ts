import { describe, it, expect } from "vitest";
import { parseMantra } from "../src/lib/parseMantra";

describe("parseMantra", () => {
  it("returns a plain title when there is no subtitle", () => {
    expect(parseMantra("Hello world")).toEqual({
      title: "Hello world",
      subtitle: null,
    });
  });

  it("splits on an em dash", () => {
    expect(parseMantra("Title — subtitle text")).toEqual({
      title: "Title",
      subtitle: "subtitle text",
    });
  });

  it("splits on an en dash", () => {
    expect(parseMantra("Title – subtitle text")).toEqual({
      title: "Title",
      subtitle: "subtitle text",
    });
  });

  it("parses bold markdown titles", () => {
    expect(parseMantra("**Bold Title** — supporting text")).toEqual({
      title: "Bold Title",
      subtitle: "supporting text",
    });
  });

  it("parses bold markdown titles with a hyphen separator", () => {
    expect(parseMantra("**Bold** - supporting text")).toEqual({
      title: "Bold",
      subtitle: "supporting text",
    });
  });

  it("strips leading list markers", () => {
    expect(parseMantra("- dashed item")).toEqual({
      title: "dashed item",
      subtitle: null,
    });
    expect(parseMantra("* starred item")).toEqual({
      title: "starred item",
      subtitle: null,
    });
  });

  it("trims surrounding whitespace", () => {
    expect(parseMantra("  padded title  ")).toEqual({
      title: "padded title",
      subtitle: null,
    });
  });

  it("does not split on a bare hyphen in plain strings", () => {
    // A hyphen without bold markers is treated as part of the title.
    expect(parseMantra("co-located services")).toEqual({
      title: "co-located services",
      subtitle: null,
    });
  });
});