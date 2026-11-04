import { useEffect } from "react";
import { isNative, model } from "../app/model";
import { MainPane } from "./MainPane";
import { Sidebar } from "./Sidebar";
import { useSource } from "./hooks";

export function App() {
  useSource(model);

  useEffect(() => {
    const onKey = (event: KeyboardEvent) => {
      // 正式版里关掉浏览器的快捷键，这是桌面应用，不该被刷新或打印
      if (isNative && !import.meta.env.DEV && (event.key === "F5" || event.key === "F12" || ((event.ctrlKey || event.metaKey) && /^[rpgj]$/i.test(event.key)))) {
        event.preventDefault();
        return;
      }
      if (!(event.ctrlKey || event.metaKey)) return;
      const key = event.key.toLowerCase();
      const run = (action: () => void) => {
        event.preventDefault();
        action();
      };
      if (event.shiftKey) {
        if (key === "p") run(() => model.togglePause());
        else if (key === "f") run(() => model.set({ focusMode: !model.state.focusMode }));
        else if (key === "m") run(() => model.set({ multiOpen: !model.state.multiOpen }));
      } else if (key === "k") run(() => model.toggleLink());
      else if (key === "f") run(() => model.focusSearch());
      else if (key === "l") run(() => model.clearLog());
      else if (key === "s") run(() => void model.saveLog());
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
