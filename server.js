import express from "express";
import { existsSync, readFileSync } from "fs";
import { fileURLToPath } from "url";
import { dirname, join, resolve } from "path";

const __dirname = dirname(fileURLToPath(import.meta.url));
const PORT = Number.parseInt(process.env.PORT ?? "3174", 10);

const mantras = JSON.parse(
  readFileSync(join(__dirname, "src", "data", "mantras.json"), "utf8")
);

export const app = express();

app.use(express.static(join(__dirname, "dist")));

app.get("/api/mantra", (_req, res) => {
  const index = Math.floor(Math.random() * mantras.length);
  res.json({ mantra: mantras[index], index, total: mantras.length });
});

app.get("/api/mantra/:index", (req, res) => {
  const index = Number.parseInt(req.params.index, 10);
  if (Number.isNaN(index) || index < 0 || index >= mantras.length) {
    res.status(404).json({ error: "Invalid index" });
    return;
  }
  res.json({ mantra: mantras[index], index, total: mantras.length });
});

app.get("*", (_req, res) => {
  const distIndex = join(__dirname, "dist", "index.html");
  if (!existsSync(distIndex)) {
    res
      .status(404)
      .send("No production build found. Run `npm run build` first, or use `npm run dev` and open http://localhost:5174.");
    return;
  }
  res.sendFile(distIndex);
});

const isMain = resolve(process.argv[1] ?? "") === fileURLToPath(import.meta.url);
if (isMain) {
  app.listen(PORT, () => {
    console.log(`Mantra API running on http://localhost:${PORT}`);
  });
}
