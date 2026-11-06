export type ShortcutAction = "togglePause" | "toggleFocus" | "toggleMulti" | "toggleLink" | "focusSearch" | "clearLog" | "saveLog";

interface Keys {
  key: string;
  ctrlKey: boolean;
  metaKey: boolean;
  shiftKey: boolean;
}

/** 应用自己的快捷键。要先于浏览器快捷键判断，Ctrl+Shift+P 不能被当成打印。 */
export function appShortcut(event: Keys): ShortcutAction | null {
  if (!(event.ctrlKey || event.metaKey)) return null;
  const key = event.key.toLowerCase();
  if (event.shiftKey) {
    if (key === "p") return "togglePause";
    if (key === "f") return "toggleFocus";
    if (key === "m") return "toggleMulti";
    return null;
  }
  if (key === "k") return "toggleLink";
  if (key === "f") return "focusSearch";
  if (key === "l") return "clearLog";
  if (key === "s") return "saveLog";
  return null;
}

/** 正式版要拦下的浏览器快捷键：刷新、打印、查找下一个、下载列表。 */
export function isBrowserShortcut(event: Keys): boolean {
  if (event.key === "F5" || event.key === "F12") return true;
  return (event.ctrlKey || event.metaKey) && /^[rpgj]$/i.test(event.key);
}
