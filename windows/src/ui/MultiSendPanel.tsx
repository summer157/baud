import { useCallback, useEffect, useRef, useState } from "react";
import { CHECKSUM_INFO } from "../core/checksum";
import { problemMessage, type SendProblem } from "../core/codec";
import { isBlank, MIN_DELAY, type SendItem } from "../core/multiSend";
import { model } from "../app/model";
import { Icon, Popover } from "./Controls";
import { useSource } from "./hooks";

interface MenuState {
  id: string;
  anchor: HTMLElement;
}

function SendRow({ item, current, problem, connected, focus, onMenu, dragStyle, onGrip }: {
  item: SendItem;
  current: boolean;
  problem: SendProblem | null;
  connected: boolean;
  focus: boolean;
  onMenu: (event: React.MouseEvent<HTMLElement>, item: SendItem) => void;
  dragStyle?: React.CSSProperties;
  onGrip: (event: React.PointerEvent, id: string) => void;
}) {
  const input = useRef<HTMLInputElement>(null);
  const multi = model.multi;
  useEffect(() => {
    if (focus) input.current?.focus();
  }, [focus]);

  const className = ["send-row", current && "current", problem && "failed", !item.enabled && "off", dragStyle && "shifting"].filter(Boolean).join(" ");

  return (
    <div
      className={className}
      data-row={item.id}
      style={dragStyle}
      onContextMenu={(event) => onMenu(event, item)}
      onPointerDown={(event) => {
        // 按住输入框和按钮以外的空白处就能拖动
        if ((event.target as HTMLElement).closest("input, button")) return;
        onGrip(event, item.id);
      }}
    >
      <div className="row-line">
        <button type="button" className={`row-check${item.enabled ? " on" : ""}`} role="checkbox" aria-checked={item.enabled} aria-label="参与依次发送" title={item.enabled ? "参与依次发送，点一下取消" : "不参与依次发送，点一下勾选"} onClick={() => multi.update(item.id, { enabled: !item.enabled })}>
          <Icon name={item.enabled ? "check" : "circle"} size={15} />
        </button>
        <button type="button" className={`row-format${item.hex ? " hex" : ""}`} title="点一下切换文本和 HEX" onClick={() => multi.update(item.id, { hex: !item.hex })}>
          {item.hex ? "HEX" : "文本"}
        </button>
        <input
          ref={input}
          className="row-text mono"
          placeholder={item.hex ? "AA 55 01 FF" : "要发送的内容"}
          aria-label="要发送的内容"
          value={item.text}
          spellCheck={false}
          onChange={(e) => multi.update(item.id, { text: e.target.value })}
          onKeyDown={(e) => {
            if (e.key === "Enter" && !e.nativeEvent.isComposing) model.sendRow(item);
          }}
        />
        <button type="button" className="soft" disabled={!connected || isBlank(item)} title="只发这一条" aria-label="只发这一条" onClick={() => model.sendRow(item)}>
          <Icon name="plane" size={12} />
        </button>
      </div>
      <div className="row-line second">
        <span className="row-grip" title="按住拖动可以调整顺序，右键可以上移下移"><Icon name="grip" size={11} /></span>
        <input className="row-note" placeholder="备注" aria-label="备注" value={item.note} onChange={(e) => multi.update(item.id, { note: e.target.value })} />
        <span className="row-unit" title={`发完这条后等多久再发下一条，最短 ${MIN_DELAY} ms`}>等</span>
        <input className="row-delay mono" placeholder="1000" aria-label="发完这条后等多久，单位毫秒" value={item.delay} onChange={(e) => multi.update(item.id, { delay: e.target.value.replace(/\D/g, "") })} />
        <span className="row-unit">ms</span>
        <button type="button" className="row-remove" title="删除这一条" aria-label="删除这一条" onClick={() => multi.remove(item.id)}>
          <Icon name="x" size={10} />
        </button>
      </div>
    </div>
  );
}

/** 日志右边的多条发送面板。 */
export function MultiSendPanel() {
  useSource(model.multi);
  const multi = model.multi;
  const s = model.state;
  const connected = s.link === "connected";
  const queue = multi.queue;
  const [focusId, setFocusId] = useState<string | null>(null);
  const [menu, setMenu] = useState<MenuState | null>(null);
  const [drag, setDrag] = useState<{ id: string; from: number; over: number; dy: number; height: number } | null>(null);
  const list = useRef<HTMLDivElement>(null);
  const closeMenu = useCallback(() => {
    // 定位用的占位元素用完就清掉
    setMenu((current) => {
      current?.anchor.remove();
      return null;
    });
  }, []);

  const startDrag = (event: React.PointerEvent, id: string) => {
    if (event.button !== 0) return;
    const from = multi.items.findIndex((i) => i.id === id);
    const startY = event.clientY;
    const startScroll = list.current!.scrollTop;
    const rows = [...list.current!.querySelectorAll<HTMLElement>("[data-row]")];
    const top = rows[0].getBoundingClientRect().top;
    const step = rows.length > 1 ? rows[1].getBoundingClientRect().top - top : rows[0].offsetHeight + 6;
    let active = false;
    let over = from;

    const move = (e: PointerEvent) => {
      const dy = e.clientY - startY + (list.current!.scrollTop - startScroll);
      if (!active && Math.abs(dy) < 4) return;
      active = true;
      document.body.classList.add("row-dragging");
      over = Math.max(0, Math.min(rows.length - 1, from + Math.round(dy / step)));
      setDrag({ id, from, over, dy, height: step });
      const box = list.current!.getBoundingClientRect();
      if (e.clientY < box.top + 24) list.current!.scrollTop -= 8;
      else if (e.clientY > box.bottom - 24) list.current!.scrollTop += 8;
    };
    const up = () => {
      window.removeEventListener("pointermove", move);
      window.removeEventListener("pointerup", up);
      window.removeEventListener("pointercancel", up);
      document.body.classList.remove("row-dragging");
      if (active) multi.moveTo(from, over);
      setDrag(null);
    };
    window.addEventListener("pointermove", move);
    window.addEventListener("pointerup", up);
    window.addEventListener("pointercancel", up);
  };

  const styleFor = (index: number, id: string): React.CSSProperties | undefined => {
    if (!drag) return undefined;
    if (id === drag.id) return { transform: `translateY(${drag.dy}px) scale(1.015)`, zIndex: 5, transition: "none", boxShadow: "0 8px 20px rgba(92,59,31,.22)" };
    if (index > drag.from && index <= drag.over) return { transform: `translateY(${-drag.height}px)` };
    if (index < drag.from && index >= drag.over) return { transform: `translateY(${drag.height}px)` };
    return { transform: "none" };
  };

  const progress = multi.progress;
  const statusParts = [progress && `第 ${progress.index} / ${progress.total} 条`, multi.loop && `第 ${multi.round} 轮`].filter(Boolean);
  const menuItem = menu && multi.items.find((i) => i.id === menu.id);

  return (
    <section className="multi" aria-label="多条发送">
      <header className="multi-head">
        <strong>多条发送</strong>
        <span className="faint num">勾选 {queue.length} 条</span>
        <span className="grow" />
        <button type="button" className="soft" title="收起" aria-label="收起多条发送" onClick={() => model.set({ multiOpen: false })}>
          <Icon name="close" size={11} />
        </button>
      </header>
      {multi.items.length === 0 ? (
        <div className="multi-empty">
          <div className="empty-title">还没有内容</div>
          <div className="empty-hint">点下面的“加一条”开始</div>
        </div>
      ) : (
        <div className="multi-list" ref={list}>
          {multi.items.map((item, index) => (
            <SendRow
              key={item.id}
              item={item}
              current={multi.currentId === item.id}
              problem={multi.failure?.id === item.id ? multi.failure.problem : null}
              connected={connected}
              focus={focusId === item.id}
              dragStyle={styleFor(index, item.id)}
              onGrip={startDrag}
              onMenu={(event, row) => {
                if ((event.target as HTMLElement).closest("input")) return;
                event.preventDefault();
                const anchor = document.createElement("span");
                anchor.style.cssText = `position:fixed;left:${event.clientX}px;top:${event.clientY}px;width:0;height:0`;
                document.body.appendChild(anchor);
                setMenu((current) => {
                  current?.anchor.remove();
                  return { id: row.id, anchor };
                });
              }}
            />
          ))}
        </div>
      )}
      {menu && menuItem && (
        <Popover anchor={menu.anchor} width={130} onClose={closeMenu} role="menu" label="这一条的操作">
          <div className="picker-list">
            <button type="button" role="menuitem" disabled={!connected || isBlank(menuItem)} onClick={() => { model.sendRow(menuItem); closeMenu(); }}>只发这一条</button>
            <button type="button" role="menuitem" onClick={() => { multi.moveBy(menu.id, -1); closeMenu(); }}>上移</button>
            <button type="button" role="menuitem" onClick={() => { multi.moveBy(menu.id, 1); closeMenu(); }}>下移</button>
            <button type="button" role="menuitem" className="danger" onClick={() => { multi.remove(menu.id); closeMenu(); }}>删除</button>
          </div>
        </Popover>
      )}
      <footer className="multi-foot">
        {multi.failure ? (
          <div className="multi-status bad" role="alert">{problemMessage(multi.failure.problem)}</div>
        ) : multi.running ? (
          <div className="multi-status tx num">{statusParts.length ? statusParts.join(" · ") : "正在发送"}</div>
        ) : s.checksum.kind !== "none" ? (
          <div className="multi-status sub">每条都会带上 {CHECKSUM_INFO[s.checksum.kind].title} 校验</div>
        ) : null}
        <div className="multi-actions">
          <button type="button" className="soft wide" onClick={() => setFocusId(multi.add())}>
            <Icon name="plus" size={12} />加一条
          </button>
          <button type="button" className={`soft wide${multi.loop ? " active" : ""}`} aria-pressed={multi.loop} title={multi.loop ? "发完最后一条再从头开始，直到手动停止" : "发完最后一条就停"} onClick={() => (multi.loop = !multi.loop)}>
            <Icon name="repeat" size={12} />循环
          </button>
          <span className="grow" />
          <button type="button" className="primary" disabled={!multi.running && (!connected || queue.length === 0)} title={connected ? "从上到下发送勾选的条目" : "连接后才能发送"} onClick={() => multi.toggleRun()}>
            <Icon name={multi.running ? "stop" : "play"} size={10} />
            {multi.running ? "停止" : "依次发送"}
          </button>
        </div>
      </footer>
    </section>
  );
}
