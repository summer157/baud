#!/usr/bin/env python3
"""从宣传页生成录制专用的页面：只留短片和字幕，时间改由录制工具逐帧推进。"""
import pathlib

here = pathlib.Path(__file__).resolve().parent
page = (here.parent / "index.html").read_text(encoding="utf8")


def patch(text, old, new):
    assert text.count(old) == 1, old
    return text.replace(old, new)


# 虚拟时钟：页面里的 setTimeout 按片中时间走，而不是按渲染耗时走
CLOCK = """<script>
window.__nativeSetTimeout = window.setTimeout.bind(window);
(function () {
  let now = 0, seq = 0, due = new Map();
  window.setTimeout = (fn, ms) => { due.set(++seq, [now + (ms || 0), fn]); return seq; };
  window.clearTimeout = id => due.delete(id);
  window.__tickTimers = ms => {
    now += ms;
    for (const [id, [at, fn]] of [...due]) if (at <= now) { due.delete(id); fn(); }
  };
})();
"""

HOOK = """const legal = document.getElementById("legal");
  const seen = new WeakSet();
  const held = Object.values(MOOD).map(m => { const i = new Image(); i.src = src(m[0]); return i; });
  window.__film = {
    duration: END,
    async ready() {
      await Promise.all(held.map(i => i.decode()));
      const text = CH.map(c => c.cap).join("") + "一个会陪你看日志的 Mac 串口助手";
      await document.fonts.load('40px "ZCOOL KuaiLe"', text);
      await document.fonts.load('600 72px "Fredoka"', "Baud");
      await document.fonts.ready;
      seek(0);
      setPlaying(false);
      await ui.stickerImg.decode();
      return document.fonts.check('40px "ZCOOL KuaiLe"', text) && document.fonts.check('600 72px "Fredoka"', "Baud");
    },
    async step(dt) {
      window.__tickTimers(dt * 1000);
      advance(Math.min(S.t + dt, END));
      render(false);
      syncPlayer();
      capEl.style.opacity = S.t >= 54.8 ? 0 : 1;
      legal.style.opacity = S.t >= 55.6 ? 1 : 0;
      for (const a of document.getAnimations()) {
        if (!seen.has(a)) { seen.add(a); a.pause(); a.currentTime = 0; continue; }
        const t = (a.currentTime || 0) + dt * 1000, end = a.effect.getComputedTiming().endTime;
        if (end !== Infinity && t >= end) a.finish(); else a.currentTime = t;
      }
      await ui.stickerImg.decode().catch(() => {});
      await new Promise(done => { requestAnimationFrame(done); window.__nativeSetTimeout(done, 60); });
    }
  };
  setPlaying(false);"""

COMMON_CSS = """
html, body { margin: 0; overflow: hidden; background: #FFF8EC; }
.hero, .wave, .block, footer, .player, .pokehint { display: none !important; }
.film { position: absolute; inset: 0; max-width: none; padding: 0; margin: 0; }
.cursor { transition: none; }
#frame { position: absolute; }
#cap { position: absolute; margin: 0; min-height: 0; display: flex; align-items: center; justify-content: center; text-align: center; color: #4A342A; transition: opacity .5s; }
#legal { position: absolute; display: flex; align-items: center; justify-content: center; text-align: center; color: #6F5848; opacity: 0; transition: opacity .6s; text-wrap: balance; }
"""

LANDSCAPE_CSS = COMMON_CSS + """
#frame { left: 288px; top: 22px; width: 1344px; }
#cap, #legal { left: 120px; right: 120px; top: 938px; height: 136px; }
#cap { font-size: 38px; line-height: 1.3; }
#legal { font-size: 24px; line-height: 1.5; }
"""

PORTRAIT_CSS = COMMON_CSS + """
#mark { position: absolute; left: 40px; right: 40px; top: 56px; display: flex; align-items: baseline; gap: 24px; }
#mark b { font-family: var(--word); font-weight: 600; font-size: 104px; line-height: 1; color: #D77757; }
#mark span { font-family: var(--display); font-size: 40px; color: #4A342A; }
#frame { left: 40px; top: 194px; width: 1000px; }
#cap, #legal { left: 48px; right: 48px; top: 1668px; height: 232px; }
#cap { font-size: 50px; line-height: 1.32; }
#legal { font-size: 30px; line-height: 1.5; }
"""

LEGAL = """<div id="legal">画面是照着 app 搭的动画演示 · 看板娘贴纸版权归原作者（ai-girl-stickers），仅作非商业展示 · Baud 是个人作品，与 Anthropic 没有官方关系</div>"""


def build(name, css, portrait):
    t = page
    t = patch(t, "<script>\n(function () {", CLOCK + "(function () {")
    t = patch(t, 'const reduced = matchMedia("(prefers-reduced-motion: reduce)").matches;', "const reduced = false;")
    t = patch(t, 'ui.log.scrollTo({ top: Math.max(0, ui.log.scrollHeight - ui.log.clientHeight - 150), behavior: reduced ? "auto" : "smooth" });',
              "{ const to = Math.max(0, ui.log.scrollHeight - ui.log.clientHeight - 150), from = ui.log.scrollTop;"
              " for (let i = 1; i <= 14; i++) setTimeout(() => { const p = i / 14; ui.log.scrollTop = from + (to - from) * (1 - (1 - p) ** 3); }, i * 33); }")
    t = patch(t, "n = w < 640,", f"n = {'true' if portrait else 'false'},")
    t = patch(t, "if (reduced) { seek(16); setPlaying(false); } else setPlaying(true);", HOOK)
    # 录制时光标不做过渡以外的跳动：沿用 CSS 过渡，由时钟逐帧推进
    extra = css.replace(".cursor { transition: none; }\n", "")
    mark = '<div id="mark"><b>Baud</b><span>一个会陪你看日志的串口助手</span></div>' if portrait else ""
    t = patch(t, '<p class="cap" id="cap"></p>', '<p class="cap" id="cap"></p>' + LEGAL + mark)
    head = ('<!doctype html><html data-theme="light"><head><meta charset="utf-8"><base href="../../">'
            f"<style>:root{{color-scheme:light}}body{{margin:0;font:14px system-ui}}img{{max-width:100%}}[hidden]{{display:none!important}}</style>")
    out = head + "</head><body>\n" + t + f"<style>{extra}</style></body></html>"
    build_dir = here / "build"
    build_dir.mkdir(exist_ok=True)
    (build_dir / f"{name}.html").write_text(out, encoding="utf8")


build("landscape", LANDSCAPE_CSS, False)
build("portrait", PORTRAIT_CSS, True)
