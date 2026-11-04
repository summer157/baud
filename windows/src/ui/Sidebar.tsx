import { useEffect, useRef, useState } from "react";
import { model, portTitle } from "../app/model";
import { Clawd, StickerStage } from "./Sticker";
import { Icon, keepFocus, Led, Picker, Segment, SunflowerSwitch } from "./Controls";
import { useSource } from "./hooks";

const BAUDS = ["9600", "19200", "38400", "57600", "115200", "230400", "460800", "921600", "1500000"];

function formatBytes(n: number): string {
  if (n < 1024) return `${n} B`;
  if (n < 1_048_576) return `${(n / 1024).toFixed(1)} KB`;
  return `${(n / 1_048_576).toFixed(2)} MB`;
}

function StatsFooter() {
  useSource(model.stats);
  const s = model.stats;
  const connected = model.state.link === "connected";
  return (
    <div className="stats">
      <div className="stat"><Led hot={s.rxHot} color="var(--ok)" /><span className="sub">RX</span><span>{formatBytes(s.rx)}</span><span className="grow" /><span className="sub">{connected ? `${formatBytes(s.rate)}/s` : ""}</span></div>
      <div className="stat"><Led hot={s.txHot} color="var(--clay)" /><span className="sub">TX</span><span>{formatBytes(s.tx)}</span></div>
    </div>
  );
}

const STATUS = { idle: "未连接", connecting: "正在连接…", connected: "已连接", lost: "等待设备…" };

function PortFields() {
  const s = model.state;
  const demoLive = model.isDemoSelected && s.link === "connected";
  return (
    <div className="fields">
      <label className="field">
        <span className="field-label">端口</span>
        <Picker
          label="端口"
          value={s.selectedPort}
          options={s.ports.map((p) => [p.path, portTitle(p)] as [string, string])}
          fallback={s.selectedPort ? `${model.selectedName}（未找到）` : "没有可用端口"}
          onChange={(selectedPort) => model.set({ selectedPort })}
        />
      </label>
      {model.isDemoSelected && (
        <div className="demo-tools">
          {s.demoPlugged ? (
            <button type="button" className="mini" disabled={!demoLive} onClick={() => model.demoUnplug()}>模拟拔出</button>
          ) : (
            <button type="button" className="mini" onClick={() => model.demoPlugBack()}>模拟插回</button>
          )}
          <button type="button" className={`mini${s.flooding ? " on" : ""}`} disabled={!demoLive} onClick={() => model.demoToggleFlood()}>
            {s.flooding ? "停止高速数据" : "高速数据"}
          </button>
        </div>
      )}
      <label className="field">
        <span className="field-label">波特率</span>
        <Picker
          label="波特率"
          value={s.baudChoice}
          options={[...BAUDS.map((b) => [b, b] as [string, string]), ["custom", "自定义…"]]}
          onChange={(baudChoice) => model.set({ baudChoice })}
        />
      </label>
      {s.baudChoice === "custom" && (
        <input className="text-field mono appear" placeholder="例如 250000" aria-label="自定义波特率" value={s.customBaud} onChange={(e) => model.set({ customBaud: e.target.value.replace(/\D/g, "") })} />
      )}
    </div>
  );
}

function AdvancedFields() {
  const s = model.state;
  return (
    <div className="advanced">
      <button type="button" className="disclosure" aria-expanded={s.advancedOpen} onClick={() => model.set({ advancedOpen: !s.advancedOpen })}>
        <span className={`turn${s.advancedOpen ? " open" : ""}`}><Icon name="right" size={10} /></span>高级设置
      </button>
      {s.advancedOpen && (
        <div className="advanced-grid appear">
          <label className="field"><span className="field-label">数据位</span><Picker label="数据位" value={s.dataBits} options={[5, 6, 7, 8].map((n) => [n, String(n)] as [number, string])} onChange={(dataBits) => model.set({ dataBits })} /></label>
          <label className="field"><span className="field-label">停止位</span><Picker label="停止位" value={s.stopBits} options={[[1, "1"], [2, "2"]]} onChange={(stopBits) => model.set({ stopBits })} /></label>
          <label className="field"><span className="field-label">校验位</span><Picker label="校验位" value={s.parity} options={[["none", "无"], ["even", "偶校验"], ["odd", "奇校验"]]} onChange={(parity) => model.set({ parity })} /></label>
          <label className="field"><span className="field-label">流控</span><Picker label="流控" value={s.flow} options={[["none", "无"], ["rtsCts", "RTS/CTS"], ["xonXoff", "XON/XOFF"]]} onChange={(flow) => model.set({ flow })} /></label>
          <label className="field"><span className="field-label">文本编码</span><Picker label="文本编码" value={s.encoding} options={[["utf8", "UTF-8"], ["gbk", "GBK"]]} onChange={(encoding) => model.set({ encoding })} /></label>
        </div>
      )}
    </div>
  );
}

function QuickCommands() {
  const s = model.state;
  const enabled = s.link === "connected";
  return (
    <div className="quick">
      <div className="quick-head">
        <span className="field-label">快捷指令</span>
        <button type="button" className="soft" disabled={s.input.trim() === ""} title="把输入框的内容加为快捷指令" aria-label="把输入框的内容加为快捷指令" onClick={() => model.addQuickFromInput()}>
          <Icon name="plus" size={12} />
        </button>
      </div>
      {s.quick.map((command) => (
        <div className="quick-row appear" key={command}>
          <button type="button" className="quick-send mono" disabled={!enabled} onClick={() => model.sendQuick(command)} title={`发送 ${command}`}>
            <span className="quick-text">{command}</span>
            <span className="quick-plane"><Icon name="plane" size={10} /></span>
          </button>
          <button type="button" className="quick-remove" title="删除这条快捷指令" aria-label={`删除快捷指令 ${command}`} onClick={() => model.removeQuick(command)}>
            <Icon name="x" size={10} />
          </button>
        </div>
      ))}
    </div>
  );
}

export function Sidebar() {
  const s = model.state;
  const scroller = useRef<HTMLDivElement>(null);
  const [hasMore, setHasMore] = useState(false);
  const [height, setHeight] = useState(window.innerHeight);

  useEffect(() => {
    const el = scroller.current!;
    const measure = () => setHasMore(el.scrollHeight - el.clientHeight - el.scrollTop > 1);
    measure();
    const onResize = () => {
      setHeight(window.innerHeight);
      measure();
    };
    el.addEventListener("scroll", measure, { passive: true });
    window.addEventListener("resize", onResize);
    const observer = new ResizeObserver(measure);
    observer.observe(el);
    if (el.firstElementChild) observer.observe(el.firstElementChild);
    return () => {
      el.removeEventListener("scroll", measure);
      window.removeEventListener("resize", onResize);
      observer.disconnect();
    };
  }, []);

  /** 贴纸只跟窗口高度走（640 时 132，760 及以上 168），不随连接状态变化。 */
  const side = 132 + 36 * Math.min(1, Math.max(0, (height - 640) / 120));

  return (
    <aside className="sidebar">
      <div className="brand" onMouseDown={keepFocus}>
        <span className="grow" />
        <Segment
          compact
          label="外观"
          value={s.theme}
          options={[
            ["system", <Icon name="auto" size={12} />, "外观：跟随系统"],
            ["light", <Icon name="sun" size={12} />, "外观：浅色"],
            ["dark", <Icon name="night" size={12} />, "外观：深色"],
          ]}
          onChange={(theme) => model.set({ theme })}
        />
        {s.focusMode && <Clawd mood={model.mood} size={27} />}
        <span>Baud</span>
      </div>
      {!s.focusMode && <StickerStage mood={model.mood} side={side} />}
      <div className="connection">
        <SunflowerSwitch state={s.link} onToggle={() => model.toggleLink()} />
        <div className="connection-text">
          <div className={`connection-title${s.link === "lost" ? " bad" : ""}`}>{STATUS[s.link]}</div>
          <div className="connection-summary mono">{model.configSummary}</div>
        </div>
      </div>
      <div className="side-scroll" ref={scroller}>
        <div className="side-content">
          <PortFields />
          <AdvancedFields />
          <QuickCommands />
        </div>
      </div>
      <button
        type="button"
        className={`more-below${hasMore ? " show" : ""}`}
        tabIndex={hasMore ? 0 : -1}
        aria-hidden={!hasMore}
        onClick={() => scroller.current?.scrollTo({ top: scroller.current.scrollHeight, behavior: "smooth" })}
      >
        <Icon name="down" size={9} />下方还有内容
      </button>
      <StatsFooter />
    </aside>
  );
}
