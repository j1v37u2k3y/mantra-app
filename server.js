import express from "express";
import { existsSync, readFileSync, watchFile } from "fs";
import { fileURLToPath } from "url";
import { dirname, join, resolve } from "path";
import { homedir } from "os";

const __dirname = dirname(fileURLToPath(import.meta.url));
const PORT = Number.parseInt(process.env.PORT ?? "3174", 10);

const LOCAL_MANTRAS_PATH =
  process.env.MANTRA_FILE ?? join(homedir(), ".config", "mantra", "mantras.json");

function loadMantras() {
  const bundled = JSON.parse(
    readFileSync(join(__dirname, "src", "data", "mantras.json"), "utf8")
  );

  if (existsSync(LOCAL_MANTRAS_PATH)) {
    try {
      const local = JSON.parse(readFileSync(LOCAL_MANTRAS_PATH, "utf8"));
      if (Array.isArray(local)) {
        const merged = [...bundled, ...local];
        console.log(
          `Loaded ${local.length} local mantra(s) from ${LOCAL_MANTRAS_PATH} (${merged.length} total)`
        );
        return merged;
      }
    } catch (err) {
      console.warn(`Warning: could not parse ${LOCAL_MANTRAS_PATH}:`, err.message);
    }
  }

  return bundled;
}

let mantras = loadMantras();

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
    console.log(`Local mantras: ${LOCAL_MANTRAS_PATH}`);
  });

  // Hot-reload: re-read the local mantras file whenever a deploy drops a new one,
  // so the daily git sync lands on the display without a service restart.
  // watchFile (stat-poll) is used instead of watch() on purpose: the sync replaces
  // the file via atomic rename — and the path may be a symlink into the mantra repo —
  // so an inode-based watch() would go stale after the swap and silently stop firing.
  watchFile(LOCAL_MANTRAS_PATH, { interval: 5000 }, (curr, prev) => {
    if (curr.mtimeMs === prev.mtimeMs && curr.size === prev.size) return;
    mantras = loadMantras();
    console.log(
      `Reloaded mantras after ${LOCAL_MANTRAS_PATH} changed (${mantras.length} total)`
    );
  });
}