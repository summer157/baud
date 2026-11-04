# Baud（Windows 版）

和 Mac 版同样的界面和功能，用 Tauri 2 写的：界面在 `src/`，串口层在 `src-tauri/`。

## 开发

```bash
pnpm install
pnpm test                 # 校验、编码、分行、多条发送
pnpm dev                  # 在浏览器里看界面，只有演示设备
pnpm tauri dev            # 完整的 app，能打开真实串口
cd src-tauri && cargo test
```

端到端自检（macOS / Linux，用虚拟串口走真实的 Rust 层）：

```bash
pnpm tauri build --debug --bundles app
BAUD_SELFTEST=/tmp/report.txt src-tauri/target/debug/bundle/macos/Baud.app/Contents/MacOS/baud
```

## 打包 Windows 安装包

推送到 GitHub 后由 `.github/workflows/windows.yml` 自动构建，在 Actions 页面下载 `Baud-Windows`。
里面有安装包（`Baud_x.y.z_x64-setup.exe`）和免安装的 `baud.exe`。没有代码签名，首次运行时要点“更多信息 → 仍要运行”。

## Windows 实测清单

1. 安装并打开：窗口、字体、贴纸、动画。左上角切换外观（跟随系统、浅色、深色）：内容和标题栏都要变，重开后还记得。
2. 演示设备：连接、发送、模拟拔出和插回、高速数据时界面是否流畅。
3. 真实串口（CH340、CP2102、STM32 等）：能列出 COM 口、连接、收发中文和 HEX。
4. 插拔：拔线后等待，插回自动重连；端口被其他程序占用时的提示。
5. 连接中修改波特率、数据位、校验位、停止位（虚拟串口测不了这一项）。
6. 校验：和 SSCOM 发同一条数据对比，尤其是 CCITT-CRC16 和字节序。
7. 多条发送：拖动排序、右键菜单、循环发送；把窗口最小化后循环和定时发送是否还按时。
8. 中文输入法：组字时按回车不会把内容发出去。
9. 保存日志、Ctrl+F / K / L / S、Ctrl+Shift+P / F / M。
10. 高分屏（125%、150% 缩放）下的显示。

## 贴纸来源

看板娘贴纸版权归原作者（ai-girl-stickers），来源见 `../design/source/CREDITS.md`。公开发布前需要作者同意，并注明来源。
