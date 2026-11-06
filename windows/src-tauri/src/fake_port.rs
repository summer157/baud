//! 测试用的假串口，不依赖虚拟串口对，所以 Windows CI 上也能跑。
//! 行为按 Windows 的串口来模拟：读写超时后返回，flush 不受超时限制，会一直等到流控放行。
use serialport::{ClearBuffer, DataBits, Error, FlowControl, Parity, Result, SerialPort, StopBits};
use std::collections::VecDeque;
use std::io;
use std::sync::atomic::{AtomicBool, AtomicU8, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

const TICK: Duration = Duration::from_millis(5);
const LONG: Duration = Duration::from_secs(5);

#[derive(Default)]
struct Shared {
    incoming: Mutex<VecDeque<u8>>,
    written: Mutex<Vec<u8>>,
    /// 流控不放行：写入超时，flush 一直等。
    blocked: AtomicBool,
    /// 读线程卡在一次读取里出不来，用来测试关闭时的等待。
    hold_reads: AtomicBool,
    unplugged: AtomicBool,
    flushes: AtomicUsize,
    clears: AtomicUsize,
    /// 还没关掉的句柄数，包括 try_clone 出来的。
    handles: AtomicUsize,
    opened: AtomicBool,
    data_bits: AtomicU8,
}

pub struct FakePort {
    shared: Arc<Shared>,
    /// 这一份是否算打开的句柄。测试代码留着观察状态的把手不算，
    /// try_clone 出来的读写句柄才算。
    counted: bool,
}

impl Clone for FakePort {
    fn clone(&self) -> Self {
        FakePort { shared: self.shared.clone(), counted: false }
    }
}

impl Drop for FakePort {
    fn drop(&mut self) {
        if self.counted {
            self.shared.handles.fetch_sub(1, Ordering::SeqCst);
        }
    }
}

impl FakePort {
    pub fn new() -> Self {
        FakePort { shared: Arc::default(), counted: false }
    }

    fn count(&mut self) {
        if !self.counted {
            self.counted = true;
            self.shared.handles.fetch_add(1, Ordering::SeqCst);
            self.shared.opened.store(true, Ordering::SeqCst);
        }
    }

    pub fn feed(&self, data: &[u8]) {
        self.shared.incoming.lock().unwrap().extend(data);
    }

    pub fn written(&self) -> Vec<u8> {
        self.shared.written.lock().unwrap().clone()
    }

    pub fn wait_written(&self, count: usize) -> Vec<u8> {
        let end = Instant::now() + LONG;
        while self.written().len() < count && Instant::now() < end {
            std::thread::sleep(TICK);
        }
        self.written()
    }

    pub fn set_blocked(&self, blocked: bool) {
        self.shared.blocked.store(blocked, Ordering::SeqCst);
    }

    pub fn hold_reads(&self, hold: bool) {
        self.shared.hold_reads.store(hold, Ordering::SeqCst);
    }

    pub fn unplug(&self) {
        self.shared.unplugged.store(true, Ordering::SeqCst);
    }

    pub fn data_bits(&self) -> u8 {
        self.shared.data_bits.load(Ordering::SeqCst)
    }

    pub fn flush_count(&self) -> usize {
        self.shared.flushes.load(Ordering::SeqCst)
    }

    pub fn clear_count(&self) -> usize {
        self.shared.clears.load(Ordering::SeqCst)
    }

    pub fn was_opened(&self) -> bool {
        self.shared.opened.load(Ordering::SeqCst)
    }

    pub fn is_closed(&self) -> bool {
        self.was_opened() && self.shared.handles.load(Ordering::SeqCst) == 0
    }

    pub fn wait_closed(&self) -> bool {
        let end = Instant::now() + LONG;
        while !self.is_closed() && Instant::now() < end {
            std::thread::sleep(TICK);
        }
        self.is_closed()
    }
}

impl io::Read for FakePort {
    fn read(&mut self, buffer: &mut [u8]) -> io::Result<usize> {
        while self.shared.hold_reads.load(Ordering::SeqCst) {
            std::thread::sleep(TICK);
        }
        if self.shared.unplugged.load(Ordering::SeqCst) {
            return Err(io::Error::new(io::ErrorKind::BrokenPipe, "设备被拔出"));
        }
        let mut incoming = self.shared.incoming.lock().unwrap();
        if incoming.is_empty() {
            drop(incoming);
            std::thread::sleep(TICK);
            return Err(io::Error::new(io::ErrorKind::TimedOut, "读超时"));
        }
        let count = buffer.len().min(incoming.len());
        for slot in &mut buffer[..count] {
            *slot = incoming.pop_front().unwrap();
        }
        Ok(count)
    }
}

impl io::Write for FakePort {
    fn write(&mut self, data: &[u8]) -> io::Result<usize> {
        if self.shared.unplugged.load(Ordering::SeqCst) {
            return Err(io::Error::new(io::ErrorKind::BrokenPipe, "设备被拔出"));
        }
        if self.shared.blocked.load(Ordering::SeqCst) {
            // Windows 上写超时不算错误，只是写进去 0 字节
            std::thread::sleep(Duration::from_millis(20));
            return Ok(0);
        }
        self.shared.written.lock().unwrap().extend_from_slice(data);
        Ok(data.len())
    }

    fn flush(&mut self) -> io::Result<()> {
        self.shared.flushes.fetch_add(1, Ordering::SeqCst);
        // FlushFileBuffers 受流控约束，不受写超时约束
        while self.shared.blocked.load(Ordering::SeqCst) {
            std::thread::sleep(TICK);
        }
        Ok(())
    }
}

impl SerialPort for FakePort {
    fn name(&self) -> Option<String> {
        Some("FAKE".into())
    }
    fn baud_rate(&self) -> Result<u32> {
        Ok(115200)
    }
    fn data_bits(&self) -> Result<DataBits> {
        Ok(DataBits::Eight)
    }
    fn flow_control(&self) -> Result<FlowControl> {
        Ok(FlowControl::None)
    }
    fn parity(&self) -> Result<Parity> {
        Ok(Parity::None)
    }
    fn stop_bits(&self) -> Result<StopBits> {
        Ok(StopBits::One)
    }
    fn timeout(&self) -> Duration {
        Duration::from_millis(20)
    }
    fn set_baud_rate(&mut self, _: u32) -> Result<()> {
        Ok(())
    }
    fn set_data_bits(&mut self, data_bits: DataBits) -> Result<()> {
        self.shared.data_bits.store(data_bits.into(), Ordering::SeqCst);
        Ok(())
    }
    fn set_flow_control(&mut self, _: FlowControl) -> Result<()> {
        Ok(())
    }
    fn set_parity(&mut self, _: Parity) -> Result<()> {
        Ok(())
    }
    fn set_stop_bits(&mut self, _: StopBits) -> Result<()> {
        Ok(())
    }
    fn set_timeout(&mut self, _: Duration) -> Result<()> {
        Ok(())
    }
    fn write_request_to_send(&mut self, _: bool) -> Result<()> {
        Ok(())
    }
    fn write_data_terminal_ready(&mut self, _: bool) -> Result<()> {
        Ok(())
    }
    fn read_clear_to_send(&mut self) -> Result<bool> {
        Ok(true)
    }
    fn read_data_set_ready(&mut self) -> Result<bool> {
        Ok(true)
    }
    fn read_ring_indicator(&mut self) -> Result<bool> {
        Ok(false)
    }
    fn read_carrier_detect(&mut self) -> Result<bool> {
        Ok(true)
    }
    fn bytes_to_read(&self) -> Result<u32> {
        Ok(self.shared.incoming.lock().unwrap().len() as u32)
    }
    fn bytes_to_write(&self) -> Result<u32> {
        Ok(0)
    }
    fn clear(&self, buffer: ClearBuffer) -> Result<()> {
        if matches!(buffer, ClearBuffer::Output) {
            self.shared.clears.fetch_add(1, Ordering::SeqCst);
        }
        Ok(())
    }
    fn try_clone(&self) -> Result<Box<dyn SerialPort>> {
        let mut clone = self.clone();
        clone.count();
        Ok(Box::new(clone))
    }
    fn set_break(&self) -> Result<()> {
        Err(Error::new(serialport::ErrorKind::Unknown, "假串口不支持"))
    }
    fn clear_break(&self) -> Result<()> {
        Err(Error::new(serialport::ErrorKind::Unknown, "假串口不支持"))
    }
}
