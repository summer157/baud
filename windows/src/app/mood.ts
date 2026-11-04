export type Mood = "cool" | "peek" | "link" | "read" | "flood" | "wait" | "send" | "hex" | "unplug" | "fail" | "failx" | "doze" | "shy" | "annoyed";

export const MOODS: Record<Mood, { sticker: string; line: string; burst?: string }> = {
  cool: { sticker: "r1c3", line: "……有事吗？" },
  peek: { sticker: "r3c5", line: "端口……还没连哦。" },
  link: { sticker: "r3c1", line: "连上啦！", burst: "★" },
  read: { sticker: "r2c3", line: "我看着呢。" },
  flood: { sticker: "r3c3", line: "好、好多数据！", burst: "✦" },
  wait: { sticker: "r2c6", line: "不急，喝口咖啡。" },
  send: { sticker: "r1c1", line: "送出去了～", burst: "♥" },
  hex: { sticker: "r1c5", line: "这个……不是成对的吧？", burst: "?" },
  unplug: { sticker: "r1c6", line: "诶？！线呢？！", burst: "!" },
  fail: { sticker: "r1c4", line: "连不上，哼！", burst: "✖" },
  failx: { sticker: "r2c2", line: "呜呜，还是连不上……" },
  doze: { sticker: "r2c1", line: "zzz……" },
  shy: { sticker: "r4c6", line: "别、别戳了……", burst: "♥" },
  annoyed: { sticker: "r4c4", line: "再戳我要生气了。" },
};

export class MoodModel {
  current: Mood = "peek";
  burstId = 0;
  version = 0;

  private ambient: Mood = "peek";
  private flashUntil = 0;
  private restore: ReturnType<typeof setTimeout> | null = null;
  private pokes = 0;
  private pokeReset: ReturnType<typeof setTimeout> | null = null;
  private listeners = new Set<() => void>();

  subscribe = (listener: () => void) => {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  };

  getVersion = () => this.version;

  setAmbient(mood: Mood) {
    this.ambient = mood;
    if (performance.now() >= this.flashUntil) this.show(mood);
  }

  /** 临时换一个表情，到时间后回到当前状态对应的表情。 */
  flash(mood: Mood, seconds: number) {
    this.flashUntil = performance.now() + seconds * 1000;
    this.show(mood);
    if (this.restore !== null) clearTimeout(this.restore);
    this.restore = setTimeout(() => this.show(this.ambient), seconds * 1000);
  }

  poke() {
    this.pokes += 1;
    if (this.pokeReset !== null) clearTimeout(this.pokeReset);
    this.pokeReset = setTimeout(() => (this.pokes = 0), 2000);
    this.flash(this.pokes >= 3 ? "annoyed" : "shy", 1.8);
  }

  private show(mood: Mood) {
    if (mood === this.current) return;
    this.current = mood;
    if (MOODS[mood].burst) this.burstId += 1;
    this.version += 1;
    for (const listener of this.listeners) listener();
  }
}
