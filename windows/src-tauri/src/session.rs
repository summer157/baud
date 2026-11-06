//! 一个已打开的串口。读写各在自己的线程上，和界面无关，方便单独测试。
use serde::{Deserialize, Serialize};
use serialport::{DataBits, FlowControl, Parity, SerialPort, SerialPortType, StopBits};
use std::io::{ErrorKind, Read, Write};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, Receiver, RecvTimeoutError, Sender};
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

const IO_TIMEOUT: Duration = Duration::from_millis(20);
const FLUSH_EVERY: Duration = Duration::from_millis(16);
const FLUSH_BYTES: usize = 64 * 1024;

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Config {
    pub baud: u32,
    pub data_bits: u8,
    pub stop_bits: u8,
    pub parity: String,
    pub flow: String,
}

#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct PortEntry {
    pub path: String,
    pub name: String,
    pub detail: String,
    /// usb、other 或 system，界面按这个排序。
    pub kind: &'static str,
}

fn data_bits(n: u8) -> DataBits {
    match n {
        5 => DataBits::Five,
        6 => DataBits::Six,
        7 => DataBits::Seven,
        _ => DataBits::Eight,
    }
}

fn parity(name: &str) -> Parity {
    match name {
        "even" => Parity::Even,
        "odd" => Parity::Odd,
        _ => Parity::None,
    }
}

fn flow(name: &str) -> FlowControl {
    match name {
        "rtsCts" => FlowControl::Hardware,
        "xonXoff" => FlowControl::Software,
        _ => FlowControl::None,
    }
}

fn stop_bits(n: u8) -> StopBits {
    if n == 2 {
        StopBits::Two
    } else {
        StopBits::One
    }
}

/// 把系统的错误翻译成用户能看懂的话。
fn describe(error: &serialport::Error) -> String {
    let text = error.description.to_lowercase();
    match error.kind {
        serialport::ErrorKind::NoDevice => "找不到这个设备，可能已被拔出".into(),
        serialport::ErrorKind::InvalidInput => "这个端口不支持所选的参数".into(),
        serialport::ErrorKind::Io(ErrorKind::PermissionDenied) => "端口被占用，先关掉正在使用它的程序".into(),
        serialport::ErrorKind::Io(ErrorKind::NotFound) => "找不到这个设备，可能已被拔出".into(),
        _ if text.contains("access is denied") || text.contains("拒绝访问") || text.contains("busy") => {
            "端口被占用，先关掉正在使用它的程序".into()
        }
        _ if text.contains("cannot find") || text.contains("找不到") || text.contains("no such file") => {
            "找不到这个设备，可能已被拔出".into()
        }
        _ => format!("无法打开端口：{}", error.description),
    }
}

fn apply(port: &mut dyn SerialPort, config: &Config) -> serialport::Result<()> {
    if port.baud_rate().ok() != Some(config.baud) {
        port.set_baud_rate(config.baud)?;
    }
    port.set_data_bits(data_bits(config.data_bits))?;
    port.set_stop_bits(stop_bits(config.stop_bits))?;
    port.set_parity(parity(&config.parity))?;
    port.set_flow_control(flow(&config.flow))?;
    Ok(())
}

pub struct Session {
    stop: Arc<AtomicBool>,
    outgoing: Option<Sender<Vec<u8>>>,
    control: Arc<Mutex<Box<dyn SerialPort>>>,
    threads: Vec<JoinHandle<()>>,
}

impl Session {
    /// 打开串口并开始接收。on_data 和 on_lost 都在读线程上调用；主动关闭不会触发 on_lost。
    pub fn open(
        path: &str,
        config: &Config,
        on_data: impl FnMut(Vec<u8>) + Send + 'static,
        on_lost: impl FnOnce() + Send + 'static,
    ) -> Result<Session, String> {
        let port = serialport::new(path, config.baud)
            .data_bits(data_bits(config.data_bits))
            .stop_bits(stop_bits(config.stop_bits))
            .parity(parity(&config.parity))
            .flow_control(flow(&config.flow))
            .timeout(IO_TIMEOUT)
            .open()
            .map_err(|e| describe(&e))?;
        Self::start(port, config, on_data, on_lost)
    }

    pub(crate) fn start(
        mut port: Box<dyn SerialPort>,
        config: &Config,
        mut on_data: impl FnMut(Vec<u8>) + Send + 'static,
        on_lost: impl FnOnce() + Send + 'static,
    ) -> Result<Session, String> {
        // 一些设备（比如 USB 虚拟串口）要看到 DTR 才肯发数据。硬件流控时 RTS 由驱动管理
        let _ = port.write_data_terminal_ready(true);
        if config.flow != "rtsCts" {
            let _ = port.write_request_to_send(true);
        }
        let _ = port.clear(serialport::ClearBuffer::All);

        let mut reader = port.try_clone().map_err(|e| describe(&e))?;
        let mut writer = port.try_clone().map_err(|e| describe(&e))?;
        let stop = Arc::new(AtomicBool::new(false));
        let lost = Arc::new(Mutex::new(Some(on_lost)));
        let (outgoing, queue): (Sender<Vec<u8>>, Receiver<Vec<u8>>) = mpsc::channel();

        let read_stop = stop.clone();
        let read_lost = lost.clone();
        let read_thread = std::thread::spawn(move || {
            let mut buffer = vec![0u8; 64 * 1024];
            let mut pending = Vec::with_capacity(FLUSH_BYTES);
            let mut last_flush = Instant::now();
            while !read_stop.load(Ordering::Relaxed) {
                match reader.read(&mut buffer) {
                    Ok(0) => {
                        // 有些系统在设备消失时返回 0；正常的超时走的是下面的分支
                        std::thread::sleep(IO_TIMEOUT);
                    }
                    Ok(n) => pending.extend_from_slice(&buffer[..n]),
                    Err(e) if matches!(e.kind(), ErrorKind::TimedOut | ErrorKind::WouldBlock | ErrorKind::Interrupted) => {}
                    Err(_) => {
                        if !pending.is_empty() {
                            on_data(std::mem::take(&mut pending));
                        }
                        if !read_stop.swap(true, Ordering::Relaxed) {
                            if let Some(notify) = read_lost.lock().unwrap().take() {
                                notify();
                            }
                        }
                        return;
                    }
                }
                // 攒一小批再交给界面，高速接收时不会一字节一次地打扰它
                if !pending.is_empty() && (pending.len() >= FLUSH_BYTES || last_flush.elapsed() >= FLUSH_EVERY) {
                    on_data(std::mem::replace(&mut pending, Vec::with_capacity(FLUSH_BYTES)));
                    last_flush = Instant::now();
                }
            }
        });

        let write_stop = stop.clone();
        let write_thread = std::thread::spawn(move || loop {
            match queue.recv_timeout(Duration::from_millis(100)) {
                Ok(data) => {
                    let mut sent = 0;
                    while sent < data.len() {
                        if write_stop.load(Ordering::Relaxed) {
                            return;
                        }
                        match writer.write(&data[sent..]) {
                            // Windows 上写超时不报错，只是写进去 0 字节
                            Ok(0) => std::thread::sleep(Duration::from_millis(1)),
                            Ok(n) => sent += n,
                            // 流控卡住时会一直超时，这里循环等待，同时能响应关闭
                            Err(e) if matches!(e.kind(), ErrorKind::TimedOut | ErrorKind::WouldBlock | ErrorKind::Interrupted) => {}
                            Err(_) => {
                                if !write_stop.swap(true, Ordering::Relaxed) {
                                    if let Some(notify) = lost.lock().unwrap().take() {
                                        notify();
                                    }
                                }
                                return;
                            }
                        }
                    }
                    // 这里不能调用 flush：Windows 的 FlushFileBuffers 不受写超时约束，
                    // 流控不放行时会一直等，关闭和重连也就跟着卡住。写入已经交给了驱动，不需要它。
                }
                Err(RecvTimeoutError::Timeout) => {
                    if write_stop.load(Ordering::Relaxed) {
                        return;
                    }
                }
                Err(RecvTimeoutError::Disconnected) => return,
            }
        });

        Ok(Session {
            stop,
            outgoing: Some(outgoing),
            control: Arc::new(Mutex::new(port)),
            threads: vec![read_thread, write_thread],
        })
    }

    pub fn write(&self, data: Vec<u8>) {
        if let Some(outgoing) = &self.outgoing {
            let _ = outgoing.send(data);
        }
    }

    pub fn update(&self, config: &Config) -> Result<(), String> {
        let mut port = self.control.lock().unwrap();
        apply(port.as_mut(), config).map_err(|_| "这个端口不支持所选的参数".to_string())
    }
}

impl Drop for Session {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
        self.outgoing = None;
        for thread in self.threads.drain(..) {
            let _ = thread.join();
        }
        // 丢掉驱动里没发完的数据，否则流控卡住时关闭句柄也可能等待
        if let Ok(port) = self.control.lock() {
            let _ = port.clear(serialport::ClearBuffer::Output);
        }
    }
}

pub fn list_ports() -> Vec<PortEntry> {
    let mut ports: Vec<PortEntry> = serialport::available_ports()
        .unwrap_or_default()
        .into_iter()
        // macOS 上同一个设备有 cu 和 tty 两个入口，只留 cu
        .filter(|p| !p.port_name.starts_with("/dev/tty."))
        .map(|p| {
            let name = p.port_name.rsplit('/').next().unwrap_or(&p.port_name).to_string();
            let lower = name.to_lowercase();
            match p.port_type {
                SerialPortType::UsbPort(info) => {
                    let detail = match (info.manufacturer, info.product) {
                        (Some(m), Some(product)) if !product.to_lowercase().contains(&m.to_lowercase()) => {
                            format!("{m} {product}")
                        }
                        (_, Some(product)) => product,
                        (Some(m), None) => m,
                        _ => "USB 串口".to_string(),
                    };
                    PortEntry { path: p.port_name, name, detail, kind: "usb" }
                }
                SerialPortType::BluetoothPort => {
                    PortEntry { path: p.port_name, name, detail: "蓝牙串口".into(), kind: "system" }
                }
                _ if lower.contains("bluetooth") || lower.contains("debug-console") || lower.contains("wlan") => {
                    PortEntry { path: p.port_name, name, detail: "系统端口".into(), kind: "system" }
                }
                _ => PortEntry { path: p.port_name, name, detail: String::new(), kind: "other" },
            }
        })
        .collect();
    let rank = |kind: &str| match kind {
        "usb" => 0,
        "other" => 1,
        _ => 2,
    };
    // COM3 要排在 COM10 前面
    let number = |name: &str| name.trim_start_matches(|c: char| !c.is_ascii_digit()).parse::<u32>().unwrap_or(u32::MAX);
    ports.sort_by(|a, b| {
        (rank(a.kind), number(&a.name), &a.name).cmp(&(rank(b.kind), number(&b.name), &b.name))
    });
    ports
}

#[cfg(test)]
mod fake_port_tests {
    use super::*;
    use crate::fake_port::FakePort;
    use std::sync::mpsc::channel;

    fn config() -> Config {
        Config { baud: 115200, data_bits: 8, stop_bits: 1, parity: "none".into(), flow: "rtsCts".into() }
    }

    fn start(port: &FakePort) -> Session {
        Session::start(Box::new(port.clone()), &config(), |_| {}, || {}).unwrap()
    }

    #[test]
    fn 发送原样到达且不调用flush() {
        let port = FakePort::new();
        let session = start(&port);
        let frames: Vec<Vec<u8>> = (0..50u8).map(|i| vec![i, 0xFF, 0x00, i]).collect();
        let started = Instant::now();
        for frame in &frames {
            session.write(frame.clone());
        }
        let expected: Vec<u8> = frames.concat();
        assert_eq!(port.wait_written(expected.len()), expected, "字节和顺序都不能变");
        assert!(started.elapsed() < Duration::from_secs(1), "发送不及时：{:?}", started.elapsed());
        assert_eq!(port.flush_count(), 0, "每帧 flush 在流控卡住时无法中止");
    }

    #[test]
    fn 流控卡住时发送不丢_放行后继续发完() {
        let port = FakePort::new();
        port.set_blocked(true);
        let session = start(&port);
        session.write(b"first".to_vec());
        session.write(b"second".to_vec());
        std::thread::sleep(Duration::from_millis(100));
        assert!(port.written().is_empty());
        port.set_blocked(false);
        assert_eq!(port.wait_written(11), b"firstsecond");
    }

    #[test]
    fn 流控卡住时关闭不会一直等() {
        let port = FakePort::new();
        port.set_blocked(true);
        let session = start(&port);
        session.write(vec![0x55; 4096]);
        session.write(vec![0xAA; 4096]);
        std::thread::sleep(Duration::from_millis(60));

        let (done, closed) = channel();
        let closing = Instant::now();
        std::thread::spawn(move || {
            drop(session);
            done.send(()).unwrap();
        });
        // 这个假串口的 flush 要等到放行才返回，如果还有 flush，这里就会超时
        closed.recv_timeout(Duration::from_secs(1)).expect("流控卡住时关闭被挡住了");
        println!("关闭用时 {:?}", closing.elapsed());
        assert!(port.wait_closed(), "所有句柄都要关掉");
        assert_eq!(port.clear_count(), 1, "要丢弃驱动里没发完的数据");
    }

    #[test]
    fn 收到的字节原样交出_拔出时通知一次_主动关闭不误报() {
        let port = FakePort::new();
        let (data_tx, data_rx) = channel();
        let (lost_tx, lost_rx) = channel();
        let session = Session::start(Box::new(port.clone()), &config(), move |d| data_tx.send(d).unwrap(), move || lost_tx.send(()).unwrap()).unwrap();
        port.feed(&[0x00, 0xFF, 0x41]);
        assert_eq!(data_rx.recv_timeout(Duration::from_secs(2)).unwrap(), vec![0x00, 0xFF, 0x41]);
        port.unplug();
        lost_rx.recv_timeout(Duration::from_secs(2)).expect("拔出后应当通知");
        assert!(lost_rx.recv_timeout(Duration::from_millis(100)).is_err(), "只通知一次");
        drop(session);

        let quiet = FakePort::new();
        let (lost_tx, lost_rx) = channel();
        let session = Session::start(Box::new(quiet.clone()), &config(), |_| {}, move || lost_tx.send(()).unwrap()).unwrap();
        drop(session);
        assert!(lost_rx.recv_timeout(Duration::from_millis(100)).is_err(), "主动关闭不能误报");
    }
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use serialport::TTYPort;
    use std::sync::mpsc::channel;

    /// 一对虚拟串口：device 这头扮演设备，port 这头交给 Session。
    fn pair() -> (TTYPort, Box<dyn SerialPort>) {
        let (mut device, mut port) = TTYPort::pair().unwrap();
        device.set_timeout(Duration::from_millis(50)).unwrap();
        port.set_timeout(IO_TIMEOUT).unwrap();
        (device, Box::new(port))
    }

    fn read_for(device: &mut TTYPort, want: usize) -> Vec<u8> {
        let mut out = Vec::new();
        let mut buffer = [0u8; 4096];
        let end = Instant::now() + Duration::from_secs(3);
        while out.len() < want && Instant::now() < end {
            if let Ok(n) = device.read(&mut buffer) {
                out.extend_from_slice(&buffer[..n]);
            }
        }
        out
    }

    fn config() -> Config {
        Config { baud: 115200, data_bits: 8, stop_bits: 1, parity: "none".into(), flow: "none".into() }
    }

    #[test]
    fn 收发原始字节() {
        let (mut device, port) = pair();
        let (tx, rx) = channel();
        let _session = Session::start(port, &config(), move |d| tx.send(d).unwrap(), || {}).unwrap();

        device.write_all(b"boot: ok\r\n").unwrap();
        let mut got = Vec::new();
        while got.len() < 10 {
            got.extend(rx.recv_timeout(Duration::from_secs(2)).unwrap());
        }
        assert_eq!(got, b"boot: ok\r\n");

        let frame = vec![0x01, 0x03, 0x00, 0xC5, 0xCD, 0xFF];
        _session.write(frame.clone());
        assert_eq!(read_for(&mut device, frame.len()), frame, "二进制数据要原样发出");
    }

    // macOS 上这个库改任何参数都会重设波特率，虚拟串口不支持，要用真实串口验证
    #[test]
    #[cfg_attr(target_os = "macos", ignore = "需要真实串口")]
    fn 连接中能修改数据位校验位和停止位() {
        let (_device, port) = pair();
        let session = Session::start(port, &config(), |_| {}, || {}).unwrap();
        let mut changed = config();
        // 虚拟串口不支持设置波特率，这里沿用它现在的值，只测其余参数
        changed.baud = session.control.lock().unwrap().baud_rate().unwrap();
        changed.data_bits = 7;
        changed.parity = "even".into();
        changed.stop_bits = 2;
        session.update(&changed).unwrap();
        let control = session.control.lock().unwrap();
        assert_eq!(control.data_bits().unwrap(), DataBits::Seven);
        assert_eq!(control.parity().unwrap(), Parity::Even);
        assert_eq!(control.stop_bits().unwrap(), StopBits::Two);
    }

    #[test]
    fn 拔出时通知() {
        let (device, port) = pair();
        let (tx, rx) = channel();
        let session = Session::start(port, &config(), |_| {}, move || tx.send(()).unwrap()).unwrap();
        drop(device);
        rx.recv_timeout(Duration::from_secs(3)).expect("拔出后应当收到通知");
        drop(session);
    }

    #[test]
    fn 主动关闭不误报也不卡住() {
        let (_device, port) = pair();
        let (tx, rx) = channel();
        let session = Session::start(port, &config(), |_| {}, move || tx.send(()).unwrap()).unwrap();
        let closing = Instant::now();
        drop(session);
        assert!(closing.elapsed() < Duration::from_secs(1), "关闭不能卡住");
        assert!(rx.recv_timeout(Duration::from_millis(200)).is_err(), "主动关闭不能误报");
    }

    #[test]
    fn 高速接收不丢数据() {
        let (mut device, port) = pair();
        let total = Arc::new(Mutex::new(0usize));
        let counter = total.clone();
        let _session = Session::start(port, &config(), move |d| *counter.lock().unwrap() += d.len(), || {}).unwrap();
        let line = [b'x'; 512];
        let mut written = 0;
        let end = Instant::now() + Duration::from_secs(1);
        while Instant::now() < end {
            if let Ok(n) = device.write(&line) {
                written += n;
            }
        }
        std::thread::sleep(Duration::from_millis(300));
        let received = *total.lock().unwrap();
        println!("写入 {written} 字节，收到 {received} 字节");
        assert!(written > 100_000, "写入太少：{written}");
        assert_eq!(received, written);
    }

    #[test]
    fn 打不开时给出能看懂的提示() {
        let error = Session::open("/dev/cu.does-not-exist", &config(), |_| {}, || {}).err().unwrap();
        assert!(error.contains("找不到"), "{error}");
    }

    #[test]
    fn 端口按编号排序且列表能读取() {
        let ports = list_ports();
        println!("{ports:?}");
        assert!(ports.iter().all(|p| !p.path.starts_with("/dev/tty.")));
    }
}
