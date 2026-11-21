# Local changes

Vendored from the published `portable-pty` 0.9.0 crate (WezTerm, MIT license).
Upstream revision: `f8921727a11b9f8b073e8c24821d72fd41283500`, path `pty`.
Crate checksum: `b4a596a2b3d2752d94f51fac2d4a96737b8705dddd311a32b9af47211f08671e`.
The original `LICENSE.md` is retained.

Windows `CommandBuilder::set_job(Arc<OwnedHandle>)` retains a job handle through
process creation. ConPTY adds `PROC_THREAD_ATTRIBUTE_JOB_LIST` alongside the
pseudoconsole attribute. Windows assigns membership before any user code can run;
assignment failures propagate from `CreateProcessW`. The caller owns job policy
and lifetime. Attribute-list storage is initialized and pointer-aligned. Unix behavior is unchanged. Serde intentionally skips OS handles.

API reference: https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-updateprocthreadattribute

ConPTY cursor inheritance is disabled because Graffitty creates a fresh terminal
grid. Its query/reply handshake can hang shutdown when a terminal is freed before
the first frame services output.
Reference: https://learn.microsoft.com/en-us/windows/console/creating-a-pseudoconsole-session#ending-the-pseudoconsole-session

Integration tests live in `crates/platform/resource-monitor/tests/windows.rs` and run via
`cargo test --manifest-path crates/platform/resource-monitor/Cargo.toml --test windows`.
