#[cfg(test)]
mod fake_port;
mod link;
mod session;
#[cfg(unix)]
mod selftest;

use link::{off_thread, Link};
use session::{list_ports, Config, PortEntry, Session};
use std::time::Duration;
use tauri::ipc::{Channel, Response};
use tauri::{AppHandle, Emitter, Manager, State};

fn all_ports() -> Vec<PortEntry> {
    #[allow(unused_mut)]
    let mut ports = list_ports();
    #[cfg(unix)]
    ports.extend(selftest::ports());
    ports
}

#[tauri::command]
fn serial_ports() -> Vec<PortEntry> {
    all_ports()
}

/// 打开串口。id 由界面生成，只增不减，之后的操作都要带上它。
/// 收到的数据从 on_data 送回；设备消失时发 serial-lost 事件。
#[tauri::command]
async fn serial_open(app: AppHandle, id: u64, path: String, config: Config, on_data: Channel<Response>) -> Result<(), String> {
    let link = app.state::<Link>().inner().clone();
    let deliver = move |data| {
        let _ = on_data.send(Response::new(data));
    };
    let lost = move || {
        let _ = app.emit("serial-lost", id);
    };
    off_thread(move || {
        link.open(id, &path, || {
            #[cfg(unix)]
            if selftest::is_selftest_port(&path) {
                return selftest::open(&path, &config, deliver, lost);
            }
            Session::open(&path, &config, deliver, lost)
        })
    })
    .await?
}

#[tauri::command]
fn serial_write(link: State<'_, Link>, id: u64, data: Vec<u8>) {
    link.write(id, data);
}

#[tauri::command]
async fn serial_update(app: AppHandle, id: u64, config: Config) -> Result<(), String> {
    let link = app.state::<Link>().inner().clone();
    off_thread(move || link.update(id, &config)).await?
}

#[tauri::command]
async fn serial_close(app: AppHandle, id: u64) -> Result<(), String> {
    let link = app.state::<Link>().inner().clone();
    off_thread(move || link.close(id)).await
}

#[tauri::command]
async fn write_text_file(path: String, text: String) -> Result<(), String> {
    off_thread(move || std::fs::write(&path, text).map_err(|e| e.to_string())).await?
}

#[cfg(unix)]
macro_rules! handlers {
    () => {
        tauri::generate_handler![
            serial_ports,
            serial_open,
            serial_write,
            serial_update,
            serial_close,
            write_text_file,
            selftest::selftest_path,
            selftest::selftest_device_write,
            selftest::selftest_device_read,
            selftest::selftest_unplug,
            selftest::selftest_device_data_bits,
            selftest::selftest_finish
        ]
    };
}

#[cfg(not(unix))]
macro_rules! handlers {
    () => {
        tauri::generate_handler![serial_ports, serial_open, serial_write, serial_update, serial_close, write_text_file]
    };
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .manage(Link::default())
        .setup(|app| {
            // 每秒看一次端口列表，有变化才通知。这样插拔设备时界面能跟着更新
            let handle = app.handle().clone();
            std::thread::spawn(move || {
                let mut known = all_ports();
                loop {
                    std::thread::sleep(Duration::from_secs(1));
                    let now = all_ports();
                    if now != known {
                        known = now.clone();
                        let _ = handle.emit("ports-changed", now);
                    }
                }
            });
            Ok(())
        })
        .invoke_handler(handlers!())
        .run(tauri::generate_context!())
        .expect("启动失败");
}
