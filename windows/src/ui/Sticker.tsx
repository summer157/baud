import { useEffect, useRef, useState } from "react";
import type { Mood, MoodModel } from "../app/mood";
import { MOODS } from "../app/mood";
import { useSource } from "./hooks";

const BODY = "M1.5 0h10v2H13v2h-1.5v2.2h-.1v2.3H9.2V6.2H8.4v2.3H7.2V6.2H5.8v2.3H4.6V6.2H3.8v2.3H2.6V6.2H1.5V4H0V2h1.5z";

const SYMBOLS: Partial<Record<Mood, string>> = {
  unplug: "!", fail: "!", failx: "!", hex: "?", doze: "z", link: "♪", send: "♪", shy: "♪",
};

const BREATH: Partial<Record<Mood, number>> = { flood: 0.16, doze: 2.2, read: 0.7 };

/** 小方块 Clawd：用矢量画的，带贴纸白边，会跟着串口状态做反应，也能被戳。 */
export function Clawd({ mood, size }: { mood: MoodModel; size: number }) {
  useSource(mood);
  const current = mood.current;
  const [blink, setBlink] = useState(false);
  const [hop, setHop] = useState(0);
  const [flip, setFlip] = useState(0);
  const [poked, setPoked] = useState(false);
  const pokes = useRef(0);

  useEffect(() => {
    let timer: ReturnType<typeof setTimeout>;
    const schedule = () => {
      timer = setTimeout(() => {
        setBlink(true);
        timer = setTimeout(() => {
          setBlink(false);
          schedule();
        }, 120);
      }, 2400 + Math.random() * 2800);
    };
    schedule();
    return () => clearTimeout(timer);
  }, []);

  useEffect(() => {
    if (current === "send" || current === "shy" || current === "flood" || current === "link") setHop((h) => h + 1);
    if (current === "link") {
      const second = setTimeout(() => setHop((h) => h + 1), 420);
      return () => clearTimeout(second);
    }
  }, [current]);

  const poke = () => {
    pokes.current += 1;
    setHop((h) => h + 1);
    if (pokes.current % 5 === 0) setFlip((f) => f + 360);
    setPoked(true);
    setTimeout(() => setPoked(false), 700);
  };

  const shut = blink || current === "doze";
  const shaking = current === "unplug" || current === "fail" || current === "failx";
  const symbol = poked ? "!" : SYMBOLS[current];

  return (
    <button
      type="button"
      className={`clawd${shaking ? " shaking" : ""}`}
      style={{ width: size, height: (size * 9) / 13, "--breath": `${BREATH[current] ?? 1.15}s` } as React.CSSProperties}
      onClick={(event) => {
        event.stopPropagation();
        poke();
      }}
      onPointerDown={(event) => event.stopPropagation()}
      title="Clawd"
      aria-label="小方块 Clawd"
    >
      <span className="clawd-flip" style={{ transform: `rotate(${flip + (current === "hex" ? -9 : 0)}deg)` }}>
        <span className="clawd-hop" key={hop} data-hop={hop > 0}>
          <span className="clawd-breathe">
            <svg viewBox="-1 -1 15 10.5" aria-hidden="true">
              <path d={BODY} fill="none" stroke="#fff" strokeWidth="1" strokeLinejoin="round" />
              <path d={BODY} fill="#D77757" stroke="#4A2B1C" strokeOpacity=".85" strokeWidth=".36" strokeLinejoin="round" />
              {shut ? (
                <>
                  <rect x="3.6" y="2.7" width="1.6" height=".45" fill="#291A14" />
                  <rect x="7.8" y="2.7" width="1.6" height=".45" fill="#291A14" />
                </>
              ) : (
                <>
                  <rect x="3.8" y="1.6" width="1.2" height="2.4" fill="#291A14" />
                  <rect x="8" y="1.6" width="1.2" height="2.4" fill="#291A14" />
                </>
              )}
            </svg>
          </span>
        </span>
      </span>
      {symbol && <span className="clawd-symbol" key={symbol} style={{ fontSize: size * 0.32 }}>{symbol}</span>}
    </button>
  );
}

interface Particle {
  id: number;
  symbol: string;
  dx: number;
  dy: number;
  delay: number;
}

const BURST_COLOR: Record<string, string> = { "♥": "#F28589", "★": "#F0AD3D", "✦": "#F0AD3D", "!": "#E3453D", "✖": "#E3453D" };

let particleId = 0;

/** 看板娘：贴纸可以被拖动、按压和戳，鼠标移过时会跟着倾斜。 */
export function StickerStage({ mood, side }: { mood: MoodModel; side: number }) {
  useSource(mood);
  const current = mood.current;
  const info = MOODS[current];
  const [previous, setPrevious] = useState<string | null>(null);
  const shown = useRef(info.sticker);
  const [particles, setParticles] = useState<Particle[]>([]);
  const stage = useRef<HTMLDivElement>(null);
  const press = useRef<{ x: number; y: number; moved: boolean } | null>(null);
  const [pressed, setPressed] = useState(false);

  useEffect(() => {
    if (shown.current === info.sticker) return;
    setPrevious(shown.current);
    shown.current = info.sticker;
    const timer = setTimeout(() => setPrevious(null), 280);
    return () => clearTimeout(timer);
  }, [info.sticker]);

  useEffect(() => {
    const symbol = MOODS[mood.current].burst;
    if (!symbol || mood.burstId === 0) return;
    const batch = Array.from({ length: 7 }, (_, i): Particle => {
      const angle = -Math.PI / 2 + (i - 3) * 0.46;
      const reach = side * 0.46 + 26 + Math.random() * 22;
      return { id: ++particleId, symbol, dx: Math.cos(angle) * reach, dy: Math.sin(angle) * reach - 12, delay: i * 20 };
    });
    setParticles((p) => [...p, ...batch]);
    const ids = new Set(batch.map((b) => b.id));
    const timer = setTimeout(() => setParticles((p) => p.filter((x) => !ids.has(x.id))), 1100);
    return () => clearTimeout(timer);
    // 每次爆发只由编号触发
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [mood.burstId]);

  const setVars = (tiltX: number, tiltY: number, dragX: number, dragY: number) => {
    const style = stage.current!.style;
    style.setProperty("--tilt-x", tiltX.toFixed(3));
    style.setProperty("--tilt-y", tiltY.toFixed(3));
    style.setProperty("--drag-x", `${dragX}px`);
    style.setProperty("--drag-y", `${dragY}px`);
  };

  const onPointerMove = (event: React.PointerEvent) => {
    const el = stage.current!;
    const box = el.getBoundingClientRect();
    if (press.current) {
      const dx = event.clientX - press.current.x;
      const dy = event.clientY - press.current.y;
      if (Math.hypot(dx, dy) > 3) press.current.moved = true;
      if (press.current.moved) {
        el.classList.add("dragging");
        setVars(Math.max(-0.6, Math.min(0.6, dx / 90)), Math.max(-0.6, Math.min(0.6, dy / 90)), dx, dy);
      }
      return;
    }
    const x = (event.clientX - box.left) / box.width;
    const y = (event.clientY - box.top) / box.height;
    el.style.setProperty("--glare-x", `${x * 100}%`);
    el.style.setProperty("--glare-y", `${y * 100}%`);
    setVars(x - 0.5, y - 0.5, 0, 0);
  };

  const onPointerUp = () => {
    if (!press.current) return;
    if (!press.current.moved) mood.poke();
    press.current = null;
    setPressed(false);
    stage.current!.classList.remove("dragging");
    setVars(0, 0, 0, 0);
  };

  return (
    <div className="sticker-area">
      <div className="bubble" key={info.line}>{info.line}</div>
      <div
        ref={stage}
        className={`stage${pressed ? " pressed" : ""}`}
        style={{ width: side, height: side, "--side": `${side}px` } as React.CSSProperties}
        role="button"
        tabIndex={0}
        aria-label={`看板娘，${info.line}`}
        onKeyDown={(event) => {
          if (event.key === "Enter" || event.key === " ") {
            event.preventDefault();
            mood.poke();
          }
        }}
        onPointerMove={onPointerMove}
        onPointerLeave={() => {
          if (!press.current) setVars(0, 0, 0, 0);
        }}
        onPointerDown={(event) => {
          event.currentTarget.setPointerCapture(event.pointerId);
          press.current = { x: event.clientX, y: event.clientY, moved: false };
          setPressed(true);
        }}
        onPointerUp={onPointerUp}
        onPointerCancel={onPointerUp}
      >
        <div className="card-holder">
          {previous && <img key={`old-${previous}`} className="card peel" src={`stickers/${previous}.png`} alt="" draggable={false} />}
          <img key={info.sticker} className="card pop" src={`stickers/${info.sticker}.png`} alt="" draggable={false} />
          <div className="glare" />
        </div>
        {particles.map((p) => (
          <span
            key={p.id}
            className="particle"
            style={{ "--dx": `${p.dx}px`, "--dy": `${p.dy}px`, color: BURST_COLOR[p.symbol] ?? "var(--clay)", animationDelay: `${p.delay}ms` } as React.CSSProperties}
          >
            {p.symbol}
          </span>
        ))}
        <div className="clawd-seat" style={{ right: -side * 0.095, bottom: -side * 0.077 }}>
          <Clawd mood={mood} size={side * 0.3} />
        </div>
      </div>
    </div>
  );
}
