import { useCallback, useEffect, useLayoutEffect, useRef, useState } from "react";
import { CHECKSUM_INFO, CHECKSUM_KINDS } from "../core/checksum";
import { hexString, LINE_ENDINGS, problemMessage } from "../core/codec";
import { model } from "../app/model";
import { Icon, keepFocus, Picker, Popover, Segment } from "./Controls";
import { MultiSendPanel } from "./MultiSendPanel";
import { useSource, useWidth } from "./hooks";

const IS_MAC = /Mac/.test(navigator.platform);
const MOD = IS_MAC ? "⌘" : "Ctrl+";

function Toolbar() {
  useSource(model.log);
  const s = model.state;
  const log = model.log;
  const search = useRef<HTMLInputElement>(null);
  const [ref, width] = useWidth<HTMLDivElement>();
  /** 窗口窄的时候文字让位给图标，否则整个界面会被撑得超出窗口。 */
  const compact = width < 720;

  useEffect(() => {
    if (s.searchFocusTick > 0) {
      search.current?.focus();
      search.current?.select();
    }
  }, [s.searchFocusTick]);

  return (
    <div className="toolbar" ref={ref}>
      <div className="search">
        <Icon name="search" size={12} />
        <input ref={search} placeholder="搜索日志" aria-label="搜索日志" value={s.query} onChange={(e) => model.set({ query: e.target.value })} onKeyDown={(e) => { if (e.key === "Escape") model.set({ query: "" }); }} />
        {s.query && (
          <button type="button" className="search-clear" aria-label="清除搜索" onClick={() => model.set({ query: "" })}>
            <Icon name="x" size={10} />
          </button>
        )}
      </div>
      <span className="faint num nowrap">{s.query ? `${log.shownCount} 行匹配` : `${log.shownCount} 行`}</span>
      <span className="grow" />
      <span className="field-label nowrap">显示</span>
      <Segment label="接收内容的显示格式" value={s.viewMode} options={[["text", "文本"], ["hex", "HEX"]]} onChange={(viewMode) => model.set({ viewMode })} />
      <button type="button" className={`soft wide${s.showTime ? " active" : ""}`} aria-pressed={s.showTime} aria-label="时间戳" title={s.showTime ? "隐藏时间戳" : "显示时间戳"} onClick={() => model.set({ showTime: !s.showTime })}>
        <Icon name="clock" size={13} />{!compact && "时间戳"}
      </button>
      <button type="button" className={`soft wide${s.multiOpen ? " active" : ""}`} aria-pressed={s.multiOpen} aria-label="多条发送" title={`${s.multiOpen ? "收起" : "打开"}多条发送（${MOD}Shift+M）`} onClick={() => model.set({ multiOpen: !s.multiOpen })}>
        <Icon name="list" size={13} />{compact ? "多条" : "多条发送"}
      </button>
      <span className="divider" />
      <button type="button" className={`soft${log.paused ? " active" : ""}`} aria-pressed={log.paused} aria-label={log.paused ? "继续显示" : "暂停显示"} title={log.paused ? "继续显示" : "暂停显示"} onClick={() => model.togglePause()}>
        <Icon name={log.paused ? "play" : "pause"} size={13} />
      </button>
      <button type="button" className="soft" aria-label="保存日志" title={`保存日志（${MOD}S）`} onClick={() => void model.saveLog()}>
        <Icon name="save" size={13} />
      </button>
      <button type="button" className="soft" aria-label="清屏" title={`清屏（${MOD}L）`} onClick={() => model.clearLog()}>
        <Icon name="trash" size={13} />
      </button>
      <button type="button" className={`soft${s.focusMode ? " active" : ""}`} aria-pressed={s.focusMode} aria-label={s.focusMode ? "请回看板娘" : "专注模式：收起看板娘"} title={s.focusMode ? "请回看板娘" : "专注模式：收起看板娘"} onClick={() => model.set({ focusMode: !s.focusMode })}>
        <Icon name={s.focusMode ? "smile" : "moon"} size={13} />
      </button>
    </div>
  );
}

function Banners() {
  useSource(model.log);
  const s = model.state;
  const log = model.log;
  return (
    <div className="banners">
      {s.link === "lost" && (
        <div className="banner">
          <b className="bad">设备已断开</b><span className="sub">插回后会自动重连</span><span className="grow" />
          {!s.demoPlugged && <button type="button" className="mini" onClick={() => model.demoPlugBack()}>模拟插回</button>}
        </div>
      )}
      {s.lastError && (
        <div className="banner" role="alert">
          <b className="bad">连接失败</b><span className="sub clip">{s.lastError}</span>
        </div>
      )}
      {log.paused && (
        <div className="banner">
          <span className="sub">显示已暂停，后台继续接收</span><b className="tx num">{log.pending} 行待显示</b><span className="grow" />
          <button type="button" className="mini" onClick={() => model.togglePause()}>继续</button>
        </div>
      )}
    </div>
  );
}

function LogArea() {
  useSource(model.log);
  const host = useRef<HTMLDivElement>(null);
  const log = model.log;
  const s = model.state;

  useLayoutEffect(() => {
    host.current!.appendChild(log.element);
    log.jumpToEnd();
  }, [log]);

  const emptyTitle = s.query ? "没有匹配的内容" : s.link === "connected" ? "正在等待数据" : "还没有数据";
  const emptyHint = s.query ? "换个关键词试试" : s.link === "connected" ? "设备发来的内容会显示在这里" : "选择端口，然后拨动向日葵";

  return (
    <div className="log-area">
      <div className="log-host" ref={host} />
      {log.isEmpty && (
        <div className="log-empty">
          <div className="empty-title">{emptyTitle}</div>
          <div className="empty-hint">{emptyHint}</div>
        </div>
      )}
      {!log.atBottom && !log.paused && !log.isEmpty && (
        <button type="button" className="jump" onClick={() => log.jumpToEnd()}>
          <Icon name="arrowDown" size={12} />回到最新
        </button>
      )}
    </div>
  );
}

function ChecksumButton() {
  const s = model.state;
  const button = useRef<HTMLButtonElement>(null);
  const [open, setOpen] = useState(false);
  const close = useCallback(() => setOpen(false), []);
  const info = CHECKSUM_INFO[s.checksum.kind];
  const on = s.checksum.kind !== "none";

  return (
    <>
      <button ref={button} type="button" className={`soft wide nowrap${on ? " active" : ""}`} aria-haspopup="dialog" aria-expanded={open} title="在发送的内容后面加校验" onClick={() => setOpen((o) => !o)}>
        <Icon name="seal" size={13} />{on ? info.title : "校验"}
      </button>
      {open && button.current && (
        <Popover anchor={button.current} above={button.current.closest<HTMLElement>(".composer")} width={270} onClose={close} role="dialog" label="发送时加校验">
          <div className="checksum">
            <strong>发送时加校验</strong>
            <div className="checksum-grid">
              {CHECKSUM_KINDS.map((kind) => (
                <button key={kind} type="button" className={kind === s.checksum.kind ? "on" : ""} aria-pressed={kind === s.checksum.kind} onClick={() => model.setChecksumKind(kind)}>
                  {CHECKSUM_INFO[kind].title}
                </button>
              ))}
            </div>
            <div className="checksum-detail">{info.detail}</div>
            <hr />
            <div className="stepper" aria-disabled={!on}>
              <span className="num">从第 {s.checksum.startByte} 字节算到末尾</span>
              <span className="grow" />
              <button type="button" disabled={!on || s.checksum.startByte <= 1} aria-label="起始字节减一" onClick={() => model.set({ checksum: { ...s.checksum, startByte: s.checksum.startByte - 1 } })}>−</button>
              <button type="button" disabled={!on || s.checksum.startByte >= 4096} aria-label="起始字节加一" title="设备的校验不算帧头时，把起点往后调" onClick={() => model.set({ checksum: { ...s.checksum, startByte: s.checksum.startByte + 1 } })}>+</button>
            </div>
            <Segment label="校验的字节顺序" disabled={info.width < 2} value={s.checksum.lowFirst} options={[[false, "高字节在前"], [true, "低字节在前"]]} onChange={(lowFirst) => model.set({ checksum: { ...s.checksum, lowFirst } })} />
            <div className="checksum-preview mono"><span className="sub">输入框这一条的校验</span> <span className="tx">{model.checksumPreview ?? "—"}</span></div>
          </div>
        </Popover>
      )}
    </>
  );
}

const measure = document.createElement("canvas").getContext("2d")!;

/** 把光标滚回可见范围，只滚动，不改选区。 */
function revealCaret(input: HTMLInputElement) {
  const style = getComputedStyle(input);
  measure.font = `${style.fontSize} ${style.fontFamily}`;
  const caret = measure.measureText(input.value.slice(0, input.selectionEnd ?? 0)).width;
  if (caret < input.scrollLeft) input.scrollLeft = Math.max(0, caret - 8);
  else if (caret > input.scrollLeft + input.clientWidth - 4) input.scrollLeft = caret - input.clientWidth + 8;
}

function Composer() {
  const s = model.state;
  const input = useRef<HTMLInputElement>(null);
  const box = useRef<HTMLDivElement>(null);
  const connected = s.link === "connected";
  const empty = s.input.trim() === "";
  const width = CHECKSUM_INFO[s.checksum.kind].width;
  const preview = model.checksumPreview;

  useEffect(() => {
    // 输入有误时轻轻摇一下
    if (s.inputProblem) box.current?.animate([{ transform: "translateX(7px)" }, { transform: "translateX(-4px)" }, { transform: "translateX(2px)" }, { transform: "none" }], { duration: 340 });
  }, [s.inputProblem]);

  // 粘贴或翻历史后内容变了，光标也要留在看得见的地方
  useLayoutEffect(() => {
    const el = input.current!;
    if (document.activeElement !== el) return;
    // 浏览器处理完这次编辑后才会定下滚动位置，要排在它后面
    const frame = requestAnimationFrame(() => revealCaret(el));
    return () => cancelAnimationFrame(frame);
  }, [s.input]);

  // 输入框宽度变化后，把光标滚回可见范围
  useEffect(() => {
    const el = input.current!;
    let last = el.clientWidth;
    const observer = new ResizeObserver(() => {
      if (el.clientWidth === last) return;
      last = el.clientWidth;
      if (document.activeElement === el) revealCaret(el);
    });
    observer.observe(el);
    return () => observer.disconnect();
  }, []);

  const prompt = !connected ? "连接后即可发送" : s.sendHex ? "输入十六进制，例如 AA 55 01 FF" : "输入要发送的内容";

  return (
    <div ref={box} className={`composer${s.inputProblem ? " error" : ""}`}>
      <div className="composer-line">
        <input
          ref={input}
          className="composer-input mono"
          placeholder={prompt}
          aria-label="要发送的内容"
          spellCheck={false}
          value={s.input}
          onChange={(e) => model.set({ input: e.target.value })}
          onKeyDown={(e) => {
            if (e.nativeEvent.isComposing) return;
            if (e.key === "Enter") model.submit();
            else if (e.key === "ArrowUp") {
              e.preventDefault();
              model.historyUp();
            } else if (e.key === "ArrowDown") {
              e.preventDefault();
              model.historyDown();
            }
          }}
        />
        {width > 0 && (
          // 按算法固定占位：HEX 打到奇数位时没有预览，输入框也不会跟着变宽变窄
          <span className="checksum-slot mono" title="这几个校验字节会加在内容后面" onClick={() => input.current?.focus()}>
            <span className="slot-sizer">+ {hexString(new Uint8Array(width))}</span>
            {preview && <span className="slot-value">+ {preview}</span>}
          </span>
        )}
      </div>
      <div className="composer-tools" onMouseDown={keepFocus}>
        <span className="field-label nowrap">发送</span>
        <Segment label="发送内容的格式" value={s.sendHex} options={[[false, "文本"], [true, "HEX"]]} onChange={(sendHex) => model.set({ sendHex })} />
        <Picker className="ending" label="行尾" disabled={s.sendHex} value={s.ending} options={LINE_ENDINGS.map((e) => [e.id, e.title] as [typeof e.id, string])} onChange={(ending) => model.set({ ending })} />
        <div className="timer">
          <button type="button" className={`soft wide${s.timerOn ? " active" : ""}`} aria-pressed={s.timerOn} disabled={!connected || (empty && !s.timerOn)} onClick={() => model.toggleTimer()}>
            <Icon name={s.timerOn ? "stop" : "repeat"} size={12} />定时
          </button>
          <span className="timer-line" />
          <input className="timer-ms mono" placeholder="1000" aria-label="定时发送的间隔，单位毫秒" value={s.timerMs} onChange={(e) => model.set({ timerMs: e.target.value.replace(/\D/g, "") })} />
          <span className="sub small">ms</span>
        </div>
        <ChecksumButton />
        <span className="composer-hint">
          {s.inputProblem ? <span className="bad clip" role="alert">{problemMessage(s.inputProblem)}</span> : <span className="faint hint-text">↩ 发送  ↑ 上一条</span>}
        </span>
        <button type="button" className="primary" disabled={!connected || empty} title="回车发送，↑ 翻出上一条" onClick={() => model.submit()}>
          发送<Icon name="plane" size={11} />
        </button>
      </div>
    </div>
  );
}

/** 发送时飞向日志区的纸飞机。 */
function PaperPlanes() {
  const tick = model.state.sendTick;
  const [flights, setFlights] = useState<number[]>([]);
  const first = useRef(true);

  useEffect(() => {
    if (first.current) {
      first.current = false;
      return;
    }
    setFlights((f) => [...f, tick]);
    const timer = setTimeout(() => setFlights((f) => f.filter((x) => x !== tick)), 750);
    return () => clearTimeout(timer);
  }, [tick]);

  return (
    <div className="planes" aria-hidden="true">
      {flights.map((id) => <span className="plane" key={id}><Icon name="plane" size={17} /></span>)}
    </div>
  );
}

export function MainPane() {
  const s = model.state;
  return (
    <main className="main">
      <Toolbar />
      <Banners />
      <div className="workspace">
        <LogArea />
        {s.multiOpen && <MultiSendPanel />}
      </div>
      <Composer />
      <PaperPlanes />
    </main>
  );
}
