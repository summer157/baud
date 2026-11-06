import { useEffect } from "react";
import { isNative, model } from "../app/model";
import { appShortcut, isBrowserShortcut, type ShortcutAction } from "../app/shortcuts";
import { MainPane } from "./MainPane";
import { Sidebar } from "./Sidebar";
import { useSource } from "./hooks";

const ACTIONS: Record<ShortcutAction, () => void> = {
  togglePause: () => model.togglePause(),
  toggleFocus: () => model.set({ focusMode: !model.state.focusMode }),
  toggleMulti: () => model.set({ multiOpen: !model.state.multiOpen }),
  toggleLink: () => model.toggleLink(),
  focusSearch: () => model.focusSearch(),
  clearLog: () => model.clearLog(),
  saveLog: () => void model.saveLog(),
};

export function App() {
  useSource(model);

  useEffect(() => {
    const onKey = (event: KeyboardEvent) => {
      const action = appShortcut(event);
      if (action) {
        event.preventDefault();
        ACTIONS[action]();
        return;
      }
      // 正式版里关掉浏览器的快捷键，这是桌面应用，不该被刷新或打印
      if (isNative && !import.meta.env.DEV && isBrowserShortcut(event)) event.preventDefault();
    };
    const onMenu = (event: MouseEvent) => {
      // 留下输入框和选中文字的右键菜单（复制、粘贴），其余地方不显示网页的菜单
      const target = event.target as HTMLElement;
      const selected = !window.getSelection()?.isCollapsed;
      if (!target.closest("input") && !selected) event.preventDefault();
    };
    window.addEventListener("keydown", onKey);
    window.addEventListener("contextmenu", onMenu);
    return () => {
      window.removeEventListener("keydown", onKey);
      window.removeEventListener("contextmenu", onMenu);
    };
  }, []);

  return (
    <div className="app">
      <Sidebar />
      <MainPane />
    </div>
  );
}
