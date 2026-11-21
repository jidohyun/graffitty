//! Presentation input queue. PTY creation, sizing and child lifetime belong to
//! gft; this adapter cannot start an in-process shell.
use std::{cell::RefCell, rc::Rc};
use godot::builtin::Callable;
use crate::input_delivery::InputDelivery;
use std::time::Instant;

pub enum Drained { Data, Empty, Eof }
#[derive(Clone, Default)]
pub struct Writer(Rc<RefCell<InputDelivery>>, Rc<RefCell<Option<Callable>>>);
impl Writer {
    pub fn notify(&self) {
        if let Some(callback) = self.1.borrow().as_ref() { callback.call_deferred(&[]); }
    }
    pub fn on_input(&self, callback: Callable) { *self.1.borrow_mut() = Some(callback); }
    pub fn write(&self, data: &[u8]) { self.write_key(data, false); }
    pub fn write_key(&self, data: &[u8], commit: bool) {
        self.0.borrow_mut().push(data, commit);
        if self.0.borrow().ready(Instant::now()) { self.notify(); }
    }
    pub fn flush(&self) {}
    pub fn take_remote(&self) -> Vec<u8> { self.0.borrow_mut().take(Instant::now()) }
    pub fn waiting(&self) -> bool { self.0.borrow().waiting() }
    pub fn remaining(&self) -> Option<std::time::Duration> { self.0.borrow().remaining(Instant::now()) }
    pub fn poll(&self) {
        if self.0.borrow().ready(Instant::now()) { self.notify(); }
    }
    pub fn output_received(&self) {
        self.0.borrow_mut().output_received();
        self.poll();
    }
    pub fn take_all(&self) -> Vec<u8> { self.0.borrow_mut().take_all() }
    // Replica parsing can emit terminal replies. Preserve the complete user
    // queue, including its boundary/deadline, while discarding those replies.
    pub fn suspend(&self) -> InputDelivery { std::mem::take(&mut *self.0.borrow_mut()) }
    pub fn restore(&self, pending: InputDelivery) { *self.0.borrow_mut() = pending; }

}
pub struct Pty(Writer);
impl Pty {
    pub fn remote() -> Self { Self(Writer::default()) }
    pub fn is_remote(&self) -> bool { true }
    pub fn writer(&self) -> Writer { self.0.clone() }
    pub fn child_pid(&self) -> Option<u32> { None }
    pub fn drain(&mut self, _sink: impl FnMut(&[u8])) -> Drained { Drained::Empty }
    pub fn resize(&self, _cols: u16, _rows: u16, _cell_w: u16, _cell_h: u16) {}
    pub fn exit_status(&mut self) -> Option<u32> { None }
    #[cfg(windows)]
    pub fn has_running_children(&self) -> bool { false }
}
