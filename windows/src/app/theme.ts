import { getCurrentWindow } from "@tauri-apps/api/window";
import { resolveTheme, type ThemeChoice } from "../core/theme";
import { isNative } from "./native";

const systemDark = window.matchMedia("(prefers-color-scheme: dark)");
let current: ThemeChoice = "system";

function paint() {
  document.documentElement.dataset.theme = resolveTheme(current, systemDark.matches);
}

systemDark.addEventListener("change", paint);

/**
 * 页面的配色由 data-theme 决定，首屏的值由 public/theme.js 先写好。
 * 这里还要告诉窗口，否则 Windows 的标题栏仍然跟着系统。回到跟随系统时，
 * 窗口会把系统当前的深浅色告诉网页，触发上面的 change 事件。
 */
export function applyTheme(choice: ThemeChoice) {
  current = choice;
  paint();
  if (isNative) void getCurrentWindow().setTheme(choice === "system" ? null : choice).catch(() => {});
}
