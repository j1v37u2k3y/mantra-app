import { useEffect, useRef, useState, useCallback } from "react";
import { parseMantra } from "./lib/parseMantra";
import mantrasData from "./data/mantras.json";

type Status = "loading" | "ready" | "error" | "refreshing";

interface MantraResponse {
  mantra: string;
  index: number;
  total: number;
}

// Auto-rotate intervals (seconds). 0 = off.
const ROTATE_INTERVALS = [0, 15, 30, 60] as const;
type RotateInterval = (typeof ROTATE_INTERVALS)[number];

function readInitialIndex(): number | null {
  if (typeof window === "undefined") return null;
  const params = new URLSearchParams(window.location.search);
  const raw = params.get("m");
  if (raw === null) return null;
  const parsed = Number.parseInt(raw, 10);
  return Number.isNaN(parsed) || parsed < 0 ? null : parsed;
}

function pickStaticMantra(index: number | null): MantraResponse | null {
  const total = mantrasData.length;
  if (total === 0) return null;
  const chosen =
    index !== null && index >= 0 && index < total
      ? index
      : Math.floor(Math.random() * total);
  return { mantra: mantrasData[chosen], index: chosen, total };
}

export default function App() {
  const [mantra, setMantra] = useState<string | null>(null);
  const [status, setStatus] = useState<Status>("loading");
  const [key, setKey] = useState(0);
  const [rotateSeconds, setRotateSeconds] = useState<RotateInterval>(0);
  const rotateTimerRef = useRef<ReturnType<typeof setInterval> | null>(null);

  const applyMantra = useCallback((data: MantraResponse) => {
    setMantra(data.mantra);
    setStatus("ready");
    setKey((k) => k + 1);
    if (typeof window !== "undefined") {
      const nextUrl = new URL(window.location.href);
      nextUrl.searchParams.set("m", String(data.index));
      window.history.replaceState({}, "", nextUrl.toString());
    }
  }, []);

  const fetchMantra = useCallback(
    async (opts: { isRefresh?: boolean; index?: number | null } = {}) => {
      const { isRefresh = false, index = null } = opts;
      setStatus(isRefresh ? "refreshing" : "loading");
      try {
        const url = index !== null ? `/api/mantra/${index}` : "/api/mantra";
        const res = await fetch(url);
        if (!res.ok) throw new Error(`HTTP ${res.status}`);
        const contentType = res.headers.get("content-type") ?? "";
        if (!contentType.includes("application/json")) {
          throw new Error("Non-JSON response");
        }
        const data = (await res.json()) as MantraResponse;
        applyMantra(data);
      } catch {
        // Static fallback — used on GitHub Pages / any host without the Express API
        const fallback = pickStaticMantra(index);
        if (fallback) {
          applyMantra(fallback);
        } else {
          setStatus("error");
        }
      }
    },
    [applyMantra]
  );

  // Initial load — honor ?m=<index> from the URL
  useEffect(() => {
    const initialIndex = readInitialIndex();
    void fetchMantra({ index: initialIndex });
  }, [fetchMantra]);

  // Spacebar = new mantra
  useEffect(() => {
    const onKeyDown = (e: KeyboardEvent) => {
      if (e.code !== "Space") return;
      const target = e.target as HTMLElement | null;
      if (target && (target.tagName === "INPUT" || target.tagName === "TEXTAREA")) return;
      e.preventDefault();
      void fetchMantra({ isRefresh: true });
    };
    window.addEventListener("keydown", onKeyDown);
    return () => window.removeEventListener("keydown", onKeyDown);
  }, [fetchMantra]);

  // Auto-rotate timer
  useEffect(() => {
    if (rotateTimerRef.current) {
      clearInterval(rotateTimerRef.current);
      rotateTimerRef.current = null;
    }
    if (rotateSeconds > 0) {
      rotateTimerRef.current = setInterval(() => {
        void fetchMantra({ isRefresh: true });
      }, rotateSeconds * 1000);
    }
    return () => {
      if (rotateTimerRef.current) clearInterval(rotateTimerRef.current);
    };
  }, [rotateSeconds, fetchMantra]);

  const cycleRotate = useCallback(() => {
    setRotateSeconds((cur) => {
      const idx = ROTATE_INTERVALS.indexOf(cur);
      const next = ROTATE_INTERVALS[(idx + 1) % ROTATE_INTERVALS.length];
      return next;
    });
  }, []);

  const parsed = mantra ? parseMantra(mantra) : null;
  const rotateLabel = rotateSeconds === 0 ? "auto off" : `auto ${rotateSeconds}s`;

  return (
    <div className="min-h-screen w-full flex flex-col items-center justify-center bg-[#050507] relative overflow-hidden">
      {/* Subtle vignette glow */}
      <div className="pointer-events-none absolute inset-0 bg-[radial-gradient(ellipse_80%_60%_at_50%_50%,rgba(100,80,200,0.06),transparent)]" />

      {/* Grain texture overlay */}
      <div
        className="pointer-events-none absolute inset-0 opacity-[0.03]"
        style={{
          backgroundImage:
            "url(\"data:image/svg+xml,%3Csvg viewBox='0 0 256 256' xmlns='http://www.w3.org/2000/svg'%3E%3Cfilter id='noise'%3E%3CfeTurbulence type='fractalNoise' baseFrequency='0.9' numOctaves='4' stitchTiles='stitch'/%3E%3C/filter%3E%3Crect width='100%25' height='100%25' filter='url(%23noise)' opacity='1'/%3E%3C/svg%3E\")",
        }}
      />

      {/* Content */}
      <main className="relative z-10 flex flex-col items-center justify-center px-4 sm:px-8 max-w-3xl mx-auto text-center pb-12 sm:pb-0">
        {status === "loading" && (
          <div className="animate-pulse">
            <div className="h-px w-12 bg-purple-500/30 rounded-full mx-auto mb-6 sm:mb-12" />
            <div className="h-5 sm:h-8 w-48 sm:w-72 bg-white/5 rounded mx-auto mb-3 sm:mb-4" />
            <div className="h-3 sm:h-4 w-32 sm:w-48 bg-white/3 rounded mx-auto" />
          </div>
        )}

        {status === "error" && (
          <p className="font-jetbrains text-[10px] sm:text-sm text-red-400/60 tracking-widest uppercase">
            no mantras available
          </p>
        )}

        {(status === "ready" || status === "refreshing") && parsed && (
          <div
            key={key}
            className={`flex flex-col items-center gap-2 sm:gap-6 ${
              status === "refreshing" ? "opacity-40 scale-95" : ""
            } transition-all duration-300`}
            style={{ animation: status === "ready" ? "fadeUp 1.1s ease-out forwards" : undefined }}
          >
            {/* Accent line */}
            <div
              className="h-px w-8 sm:w-12 bg-gradient-to-r from-transparent via-purple-400/50 to-transparent"
              style={{ animation: "fadeIn 1.8s ease-out forwards" }}
            />

            {/* Main title */}
            <h1
              className="font-playfair text-white/90 leading-snug tracking-tight text-[clamp(1.1rem,5vw,3rem)] md:text-5xl"
              style={{ fontWeight: 400 }}
            >
              {parsed.title}
            </h1>

            {/* Subtitle / descriptor */}
            {parsed.subtitle && (
              <p
                className="font-playfair italic text-white/50 leading-snug max-w-xl text-[clamp(0.85rem,2.6vw,1.25rem)]"
                style={{ animation: "fadeIn 2s ease-out 0.3s both" }}
              >
                {parsed.subtitle}
              </p>
            )}

            {/* Accent line bottom */}
            <div
              className="h-px w-6 sm:w-8 bg-gradient-to-r from-transparent via-purple-400/30 to-transparent"
              style={{ animation: "fadeIn 2s ease-out 0.6s both" }}
            />
          </div>
        )}
      </main>

      {/* Bottom control row */}
      {(status === "ready" || status === "error") && (
        <div
          className="absolute bottom-3 sm:bottom-10 left-1/2 -translate-x-1/2 flex items-center gap-4 sm:gap-8"
          style={{ animation: "fadeIn 3s ease-out 1.5s both" }}
        >
          <button
            onClick={() => void fetchMantra({ isRefresh: true })}
            className="font-jetbrains text-[9px] sm:text-[10px] tracking-[0.25em] sm:tracking-[0.3em] uppercase text-white/15 hover:text-white/40 transition-colors duration-500 cursor-pointer select-none"
            title="New mantra (spacebar)"
          >
            new mantra
          </button>

          <div className="h-2 w-px bg-white/10" />

          <button
            onClick={cycleRotate}
            className={`font-jetbrains text-[9px] sm:text-[10px] tracking-[0.25em] sm:tracking-[0.3em] uppercase transition-colors duration-500 cursor-pointer select-none ${
              rotateSeconds > 0 ? "text-purple-300/50 hover:text-purple-300/80" : "text-white/15 hover:text-white/40"
            }`}
            title="Cycle auto-rotate interval"
          >
            {rotateLabel}
          </button>
        </div>
      )}

      {/* Subtle hint about spacebar — hidden on tiny screens (e.g. 480x320) */}
      {status === "ready" && (
        <div
          className="hidden sm:block absolute bottom-3 left-1/2 -translate-x-1/2 font-jetbrains text-[9px] tracking-[0.25em] uppercase text-white/10 select-none pointer-events-none"
          style={{ animation: "fadeIn 4s ease-out 2.5s both" }}
        >
          space for new · click label to auto-cycle
        </div>
      )}

      <style>{`
        @keyframes fadeIn {
          from { opacity: 0; }
          to   { opacity: 1; }
        }
        @keyframes fadeUp {
          from { opacity: 0; transform: translateY(16px); }
          to   { opacity: 1; transform: translateY(0); }
        }
      `}</style>
    </div>
  );
}