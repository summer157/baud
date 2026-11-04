import { useEffect, useRef, useState, useSyncExternalStore } from "react";

interface Source {
  subscribe(listener: () => void): () => void;
  getVersion(): number;
}

/** 让组件跟着一个模型刷新。 */
export function useSource(source: Source): number {
  return useSyncExternalStore(source.subscribe, source.getVersion);
}

export function useWidth<T extends HTMLElement>(): [React.RefObject<T>, number] {
  const ref = useRef<T>(null);
  const [width, setWidth] = useState(10_000);
  useEffect(() => {
    if (!ref.current) return;
    const observer = new ResizeObserver(([entry]) => setWidth(entry.contentRect.width));
    observer.observe(ref.current);
    return () => observer.disconnect();
  }, []);
  return [ref, width];
}
