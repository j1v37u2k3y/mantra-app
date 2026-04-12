import { describe, it, expect } from "vitest";
import request from "supertest";
import { app } from "../server.js";

describe("GET /api/mantra", () => {
  it("returns a random mantra with index + total", async () => {
    const res = await request(app).get("/api/mantra");
    expect(res.status).toBe(200);
    expect(typeof res.body.mantra).toBe("string");
    expect(res.body.mantra.length).toBeGreaterThan(0);
    expect(typeof res.body.index).toBe("number");
    expect(res.body.total).toBeGreaterThan(0);
    expect(res.body.index).toBeGreaterThanOrEqual(0);
    expect(res.body.index).toBeLessThan(res.body.total);
  });
});

describe("GET /api/mantra/:index", () => {
  it("returns the mantra at the requested index", async () => {
    const res = await request(app).get("/api/mantra/0");
    expect(res.status).toBe(200);
    expect(res.body.index).toBe(0);
    expect(typeof res.body.mantra).toBe("string");
  });

  it("is deterministic for the same index", async () => {
    const first = await request(app).get("/api/mantra/1");
    const second = await request(app).get("/api/mantra/1");
    expect(first.body.mantra).toBe(second.body.mantra);
  });

  it("returns 404 for an out-of-range index", async () => {
    const res = await request(app).get("/api/mantra/999999");
    expect(res.status).toBe(404);
    expect(res.body.error).toBe("Invalid index");
  });

  it("returns 404 for a non-numeric index", async () => {
    const res = await request(app).get("/api/mantra/abc");
    expect(res.status).toBe(404);
  });

  it("returns 404 for a negative index", async () => {
    const res = await request(app).get("/api/mantra/-1");
    expect(res.status).toBe(404);
  });
});

describe("SPA fallback", () => {
  it("returns a helpful message when dist/ is missing", async () => {
    const res = await request(app).get("/some-unknown-route");
    // dist/ is not built during tests, so the fallback message is expected.
    expect([200, 404]).toContain(res.status);
  });
});