import { useCallback, useEffect, useLayoutEffect, useRef, useState, type ReactNode } from "react";
import { createPortal } from "react-dom";
import type { LinkState } from "../app/model";

/** 系统没有合适的图标字体，用到的几个图标都画在这里。 */
const ICONS: Record<string, ReactNode> = {
  search: <><circle cx="7" cy="7" r="4.6" /><path d="M10.5 10.5 14 14" /></>,
  clock: <><circle cx="8" cy="8" r="6" /><path d="M8 4.6V8l2.3 1.6" /></>,
  list: <><rect x="1.8" y="3" width="12.4" height="10" rx="1.6" /><path d="M4.4 6h.4M6.6 6h5M4.4 8h.4M6.6 8h5M4.4 10h.4M6.6 10h5" /></>,
  pause: <path d="M5 3.4v9.2M11 3.4v9.2" strokeWidth="2.6" />,
  play: <path d="M5 3.2v9.6l7.6-4.8z" fill="currentColor" />,
  stop: <rect x="4" y="4" width="8" height="8" rx="1.2" fill="currentColor" />,
  save: <><path d="M4.6 2.6H3.4a1 1 0 0 0-1 1v9.2a1 1 0 0 0 1 1h9.2a1 1 0 0 0 1-1V3.6a1 1 0 0 0-1-1h-1.2" /><path d="M8 1.8v7.6M5.4 7 8 9.6 10.6 7" /></>,
  trash: <><path d="M2.8 4.2h10.4M6.2 4V2.6h3.6V4M4 4.2l.7 9.2h6.6l.7-9.2M6.6 6.6v4.6M9.4 6.6v4.6" /></>,
  moon: <><path d="M12.6 10A5.6 5.6 0 0 1 6 3.4 5.6 5.6 0 1 0 12.6 10z" /><path d="M10.4 2.4h3l-3 3h3" /></>,
  smile: <><circle cx="8" cy="8" r="6" /><path d="M5.2 9.6a3.2 3.2 0 0 0 5.6 0M5.8 6.2h.1M10.1 6.2h.1" /></>,
  plane: <path d="M14.4 1.6 1.6 7l4.8 2 2 4.8zM6.4 9l3.4-3.4" fill="currentColor" stroke="none" />,
  plus: <path d="M8 3v10M3 8h10" />,
  close: <path d="M3.6 3.6l8.8 8.8M12.4 3.6l-8.8 8.8" />,
  repeat: <path d="M2.6 7V6a2.4 2.4 0 0 1 2.4-2.4h8L11 1.6M13.4 9v1a2.4 2.4 0 0 1-2.4 2.4H3L5 14.4" />,
  seal: <><path d="M8 1.6l1.7 1.2 2-.2.8 1.9 1.8 1-.4 2 .4 2-1.8 1-.8 1.9-2-.2L8 14.4l-1.7-1.2-2 .2-.8-1.9-1.8-1 .4-2-.4-2 1.8-1 .8-1.9 2 .2z" /><path d="M5.6 8l1.7 1.7 3.1-3.2" /></>,
  chevrons: <path d="M4.8 6.2 8 3l3.2 3.2M4.8 9.8 8 13l3.2-3.2" />,
  right: <path d="M6 3.4 10.6 8 6 12.6" />,
  down: <path d="M3.4 6 8 10.6 12.6 6" />,
  arrowDown: <path d="M8 2.6v10.6M3.8 9 8 13.2 12.2 9" />,
  grip: <path d="M3 5h10M3 8h10M3 11h10" />,
  check: <><circle cx="8" cy="8" r="7" fill="currentColor" stroke="none" /><path d="M4.8 8.2 7 10.4l4.2-4.6" stroke="var(--raised)" /></>,
  circle: <circle cx="8" cy="8" r="6.6" />,
  x: <path d="M4.8 4.8l6.4 6.4M11.2 4.8l-6.4 6.4" strokeWidth="2.2" />,
};

export function Icon({ name, size = 14 }: { name: string; size?: number }) {
  return (
    <svg className="icon" viewBox="0 0 16 16" width={size} height={size} fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
      {ICONS[name]}
    </svg>
  );
}

/** 一朵向日葵，花瓣可以单独缩放。 */
export function Sunflower({ bloom = 1 }: { bloom?: number }) {
  const petal = "M0 -12.5C10 -25 7.5 -40 0 -50C-7.5 -40 -10 -25 0 -12.5Z";
  return (
    <svg viewBox="-52 -52 104 104" className="sunflower" aria-hidden="true">
      <g style={{ transform: `scale(${bloom})`, transition: "transform .56s var(--flower)" }}>
        {Array.from({ length: 16 }, (_, i) => (
          <path key={i} d={petal} transform={`rotate(${i * 22.5})`} fill={i % 2 === 0 ? "#E07830" : "#F2A14F"} stroke="#8F4017" strokeWidth="1.8" />
        ))}
      </g>
      <circle r="17" fill="#6B2E14" />
      <circle r="10" fill="#A65220" />
    </svg>
  );
}

const SWITCH_TEXT: Record<LinkState, { action: string; description: string; status: string }> = {
  idle: { action: "连接", description: "连接串口", status: "未连接" },
  connecting: { action: "取消", description: "取消连接", status: "正在连接" },
  connected: { action: "断开", description: "断开串口", status: "已连接" },
  lost: { action: "停止", description: "停止等待重连", status: "等待设备" },
};

/** 连接开关：向日葵滑过去时旋转、绽放，到位时回弹。 */
export function SunflowerSwitch({ state, onToggle }: { state: LinkState; onToggle: () => void }) {
  const text = SWITCH_TEXT[state];
  const on = state !== "idle";
  return (
    <button type="button" className={`switch ${state}`} onClick={onToggle} title={text.description} aria-label={`${text.description}，当前${text.status}`} aria-pressed={on}>
      <span className="switch-label" key={text.action}>{text.action}</span>
      <span className="switch-knob">
        <span className="switch-spin">
          <Sunflower bloom={on ? 1.05 : 0.78} />
        </span>
      </span>
    </button>
  );
}

/** 滑块会弹性移动的分段按钮。 */
export function Segment<T extends string | boolean>({ value, options, onChange, label, disabled }: {
  value: T;
  options: [T, string][];
  onChange: (value: T) => void;
  label: string;
  disabled?: boolean;
}) {
  const root = useRef<HTMLDivElement>(null);
  const [pill, setPill] = useState({ left: 2, width: 0, ready: false });

  useLayoutEffect(() => {
    const button = root.current?.querySelector<HTMLElement>("[aria-checked=true]");
    if (button) setPill((p) => ({ left: button.offsetLeft, width: button.offsetWidth, ready: p.width > 0 }));
  }, [value, options.length]);

  return (
    <div ref={root} className={`segment${disabled ? " disabled" : ""}`} role="radiogroup" aria-label={label}>
      <span className="segment-pill" style={{ transform: `translateX(${pill.left}px)`, width: pill.width, transition: pill.ready ? undefined : "none" }} />
      {options.map(([option, title]) => (
        <button key={String(option)} type="button" role="radio" aria-checked={option === value} disabled={disabled} onClick={() => onChange(option)}>
          {title}
        </button>
      ))}
    </div>
  );
}

/** 点按钮时不抢走输入框的焦点。输入框一失去焦点，显示就会滚回开头，长报文的末尾就看不到了。 */
export function keepFocus(event: React.MouseEvent) {
  if (!(event.target as HTMLElement).closest("input")) event.preventDefault();
}

/** 浮层：放在最外层，不会被滚动区裁掉，下方放不下时自动翻到上方。 */
export function Popover({ anchor, above, onClose, children, width, role, label }: {
  anchor: HTMLElement;
  /** 向上弹出时停在这个元素的上方，不盖住它。 */
  above?: HTMLElement | null;
  onClose: () => void;
  children: ReactNode;
  width?: number;
  role?: string;
  label?: string;
}) {
  const ref = useRef<HTMLDivElement>(null);
  const [position, setPosition] = useState<{ left: number; top: number; origin: string } | null>(null);

  useLayoutEffect(() => {
    const box = anchor.getBoundingClientRect();
    // 这里要量布局尺寸：弹出动画正在缩放，getBoundingClientRect 量到的偏小
    const { offsetWidth, offsetHeight } = ref.current!;
    const below = box.bottom + 6;
    const up = above != null || below + offsetHeight > window.innerHeight - 8;
    const ceiling = above ? above.getBoundingClientRect().top : box.top;
    setPosition({
      left: Math.max(8, Math.min(box.left, window.innerWidth - offsetWidth - 8)),
      top: up ? Math.max(8, ceiling - offsetHeight - 6) : below,
      origin: up ? "bottom left" : "top left",
    });
  }, [anchor, above]);

  useEffect(() => {
    const down = (event: PointerEvent) => {
      const target = event.target as Node;
      if (!ref.current?.contains(target) && !anchor.contains(target)) onClose();
    };
    const key = (event: KeyboardEvent) => {
      if (event.key === "Escape") {
        event.stopPropagation();
        onClose();
        anchor.focus();
      }
    };
    window.addEventListener("pointerdown", down, true);
    window.addEventListener("keydown", key, true);
    window.addEventListener("resize", onClose);
    return () => {
      window.removeEventListener("pointerdown", down, true);
      window.removeEventListener("keydown", key, true);
      window.removeEventListener("resize", onClose);
    };
  }, [anchor, onClose]);

  return createPortal(
    <div
      ref={ref}
      className="popover"
      role={role}
      aria-label={label}
      onMouseDown={keepFocus}
      style={{
        width,
        minWidth: width ? undefined : anchor.offsetWidth,
        left: position?.left ?? 0,
        top: position?.top ?? 0,
        visibility: position ? "visible" : "hidden",
        transformOrigin: position?.origin,
      }}
    >
      {children}
    </div>,
    document.body,
  );
}

/** 跟随主题的下拉选择。 */
export function Picker<T extends string | number>({ value, options, onChange, fallback = "", label, disabled, className }: {
  value: T;
  options: [T, string][];
  onChange: (value: T) => void;
  fallback?: string;
  label: string;
  disabled?: boolean;
  className?: string;
}) {
  const button = useRef<HTMLButtonElement>(null);
  const [open, setOpen] = useState(false);
  const [active, setActive] = useState(0);
  const close = useCallback(() => setOpen(false), []);
  const title = options.find(([v]) => v === value)?.[1] ?? fallback;

  const choose = (next: T) => {
    onChange(next);
    setOpen(false);
    button.current?.focus();
  };

  const onKeyDown = (event: React.KeyboardEvent) => {
    if (!open) {
      if (event.key === "ArrowDown" || event.key === "ArrowUp") {
        event.preventDefault();
        setActive(Math.max(0, options.findIndex(([v]) => v === value)));
        setOpen(true);
      }
      return;
    }
    if (event.key === "ArrowDown") {
      event.preventDefault();
      setActive((a) => Math.min(options.length - 1, a + 1));
    } else if (event.key === "ArrowUp") {
      event.preventDefault();
      setActive((a) => Math.max(0, a - 1));
    } else if (event.key === "Enter" || event.key === " ") {
      event.preventDefault();
      if (options[active]) choose(options[active][0]);
    }
  };

  return (
    <>
      <button
        ref={button}
        type="button"
        className={`picker ${className ?? ""}`}
        disabled={disabled}
        aria-label={`${label}：${title}`}
        aria-haspopup="listbox"
        aria-expanded={open}
        onClick={() => {
          setActive(Math.max(0, options.findIndex(([v]) => v === value)));
          setOpen((o) => !o);
        }}
        onKeyDown={onKeyDown}
      >
        <span className="picker-title">{title}</span>
        <Icon name="chevrons" size={11} />
      </button>
      {open && button.current && (
        <Popover anchor={button.current} onClose={close} role="listbox" label={label}>
          <div className="picker-list">
            {options.map(([option, name], index) => (
              <button
                key={String(option)}
                type="button"
                role="option"
                aria-selected={option === value}
                className={index === active ? "active" : ""}
                onPointerEnter={() => setActive(index)}
                onClick={() => choose(option)}
              >
                <span className="tick">{option === value ? "✓" : ""}</span>
                {name}
              </button>
            ))}
          </div>
        </Popover>
      )}
    </>
  );
}

export function Led({ hot, color }: { hot: boolean; color: string }) {
  return <span className={`led${hot ? " hot" : ""}`} style={{ "--led": color } as React.CSSProperties} />;
}
