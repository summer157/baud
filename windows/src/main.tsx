import { createRoot } from "react-dom/client";
import { App } from "./ui/App";
import { model } from "./app/model";
import { runSelfTestIfRequested } from "./app/selftest";
import "./ui/styles.css";

if (import.meta.env.DEV) (window as unknown as { __baud: unknown }).__baud = model;
void runSelfTestIfRequested();

createRoot(document.getElementById("root")!).render(<App />);
