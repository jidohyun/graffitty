//! Canonical workspace persistence and session membership.
use crate::{Error, Server};
use graffitty_workspace_core::{
    state::{Authority, Edit, Snapshot},
    tiling::{Side, TabLayout, Window},
};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::{
    collections::BTreeMap,
    fs,
    io::Write,
    path::{Path, PathBuf},
};

#[derive(Serialize, Deserialize)]
struct Document {
    version: u32,
    epoch: String,
    workspaces: BTreeMap<String, Snapshot>,
}
pub struct Store {
    path: PathBuf,
    epoch: String,
    workspaces: BTreeMap<String, Authority>,
}
impl Store {
    pub fn new(descriptor: &Path, epoch: &str) -> Result<Self, Error> {
        let path = descriptor.with_extension("workspace.json");
        let mut workspaces = BTreeMap::new();
        if path.is_file() {
            // Session IDs belong to one owner epoch. A new daemon must not give
            // freshly allocated PTYs a previous daemon's identity/layout.
            let metadata = fs::metadata(&path)?;
            if metadata.len() <= 16 * 1024 * 1024 {
                let document = serde_json::from_slice::<Value>(&fs::read(&path)?).and_then(|value| {
                    serde_json::from_value::<Document>(value)
                });
                if let Ok(document) = document {
                    if document.version == 1 && document.epoch == epoch {
                        for (name, state) in document.workspaces {
                            workspaces.insert(
                                name,
                                Authority::from_snapshot(state).map_err(|e| e.to_string())?,
                            );
                        }
                    }
                }
            }
        }
        Ok(Self {
            path,
            epoch: epoch.into(),
            workspaces,
        })
    }
    pub fn snapshot(&self, workspace: &str) -> Snapshot {
        self.workspaces
            .get(workspace)
            .map(|v| v.snapshot().clone())
            .unwrap_or_default()
    }
    pub fn revision(&self, workspace: &str) -> u64 {
        self.workspaces.get(workspace).map_or(0, |v| v.snapshot().revision)
    }
    pub fn remove(&mut self, workspace: &str) -> Result<(), Error> {
        let previous = self.workspaces.remove(workspace);
        if let Err(error) = self.persist_all(None) {
            if let Some(previous) = previous { self.workspaces.insert(workspace.into(), previous); }
            return Err(error);
        }
        Ok(())
    }
    pub fn sync(&mut self, name: &str, live: &[(u64, Window)]) -> Result<(), Error> {
        let mut next = self.workspaces.get(name).cloned().unwrap_or_default();
        let changed = next.reconcile(live).map_err(|e| e.to_string())?;
        if changed || !self.workspaces.contains_key(name) {
            self.persist(name, next.snapshot())?;
            self.workspaces.insert(name.into(), next);
        }
        Ok(())
    }
    pub fn regroup(&mut self, name: &str, keys: &std::collections::BTreeSet<String>, source: u64, destination: u64, preserve: bool) -> Result<(), Error> {
        let mut next = self.workspaces.get(name).cloned().ok_or("Unknown workspace")?;
        next.regroup(keys, source, destination, preserve).map_err(|e| e.to_string())?;
        self.persist(name, next.snapshot())?;
        self.workspaces.insert(name.into(), next);
        Ok(())
    }
    pub fn edit(&mut self, name: &str, revision: u64, edit: Edit) -> Result<Snapshot, Error> {
        let mut next = self
            .workspaces
            .get(name)
            .cloned()
            .ok_or("Unknown workspace")?;
        let state = next
            .apply(revision, edit)
            .map_err(|e| e.to_string())?
            .clone();
        self.persist(name, &state)?;
        self.workspaces.insert(name.into(), next);
        Ok(state)
    }
    /// Commit both sides before live PTY membership changes. A failed write
    /// leaves both in-memory authorities and their undo histories untouched.
    pub fn transfer_tab(&mut self, source: &str, target: &str, tab: u64) -> Result<(), Error> {
        let old_source = self.workspaces.get(source).cloned().ok_or("Unknown source session")?;
        let old_target = self.workspaces.get(target).cloned();
        let mut from = old_source.clone();
        let mut to = old_target.clone().unwrap_or_default();
        let layout = from.snapshot().layout.tabs.get(&tab).cloned().ok_or("Unknown source tab")?;
        let settings = from.snapshot().tabs[&tab].clone();
        let remaining: Vec<_> = from.snapshot().layout.tabs.iter().filter(|(id, _)| **id != tab)
            .flat_map(|(id, layout)| layout.windows.iter().cloned().map(move |w| (*id, w))).collect();
        let arriving: Vec<_> = to.snapshot().layout.tabs.iter()
            .flat_map(|(id, layout)| layout.windows.iter().cloned().map(move |w| (*id, w)))
            .chain(layout.windows.iter().cloned().map(|w| (tab, w))).collect();
        from.reconcile(&remaining)?;
        to.reconcile(&arriving)?;
        to.apply(to.snapshot().revision, Edit::Tab { tab, layout, settings: Some(settings) })?;
        to.apply(to.snapshot().revision, Edit::Activate { tab })?;
        if remaining.is_empty() { self.workspaces.remove(source); }
        else { self.workspaces.insert(source.into(), from); }
        self.workspaces.insert(target.into(), to);
        if let Err(error) = self.persist_all(None) {
            self.workspaces.insert(source.into(), old_source);
            if let Some(old) = old_target { self.workspaces.insert(target.into(), old); }
            else { self.workspaces.remove(target); }
            return Err(error);
        }
        Ok(())
    }
    fn persist(&self, name: &str, next: &Snapshot) -> Result<(), Error> {
        self.persist_all(Some((name, next)))
    }
    fn persist_all(&self, update: Option<(&str, &Snapshot)>) -> Result<(), Error> {
        let mut workspaces: BTreeMap<_, _> = self
            .workspaces
            .iter()
            .map(|(name, owner)| (name.clone(), owner.snapshot().clone()))
            .collect();
        if let Some((name, next)) = update { workspaces.insert(name.into(), next.clone()); }
        let document = Document {
            version: 1,
            epoch: self.epoch.clone(),
            workspaces,
        };
        let bytes = serde_json::to_vec(&document)?;
        let temporary = self
            .path
            .with_extension(format!("{}.tmp", uuid::Uuid::new_v4()));
        let result = (|| -> Result<(), Error> {
            let mut options = fs::OpenOptions::new();
            options.write(true).create_new(true);
            #[cfg(unix)]
            {
                use std::os::unix::fs::OpenOptionsExt;
                options.mode(0o600);
            }
            let mut file = options.open(&temporary)?;
            file.write_all(&bytes)?;
            file.sync_all()?;
            fs::rename(&temporary, &self.path)?;
            Ok(())
        })();
        if result.is_err() {
            let _ = fs::remove_file(temporary);
        }
        result
    }
}

pub fn sync(server: &mut Server, name: &str) -> Result<(), Error> {
    let snapshot = server.workspace_state.snapshot(name);
    let live: Vec<_> = server
        .sessions
        .values()
        .filter(|s| s.workspace == name)
        .map(|s| {
            (
                s.tab,
                Window::new(format!("%{}", s.id), s.rect.map(|v| v as f32)),
            )
        })
        .chain(
            server
                .chromiums
                .values()
                .filter(|b| b.workspace == name)
                .map(|b| {
                    (
                        b.tab,
                        Window::new(format!("%{}", b.id), if b.main_window { [1050., 60., 1000., 750.] } else {
                            let owner = format!("%{}", b.owner);
                            let parent = snapshot.layout.tabs.get(&b.tab).and_then(|tab|tab.windows.iter().find(|w|w.key == owner));
                            let offset = server.chromiums.values().filter(|other|other.session_id==b.session_id && !other.main_window && other.id<b.id).count() as f32;
                            parent.map(|w|[w.rect[0]+w.rect[2]+40.+offset*1040.,w.rect[1],1000.,750.])
                                .unwrap_or([2090.+offset*1040.,60.,1000.,750.])
                        }),
                    )
                }),
        )
        .collect();
    server.workspace_state.sync(name, &live)?;
    sync_terminal_geometry(server, name)
}

/// A Chromium opened from a terminal outside the Main view (floating, stashed,
/// a graph node, or in a floating tab) goes beside it, to its right, in the
/// terminal's own layer, instead of tiling into Main. A terminal in Main keeps
/// its Chromium in Main.
pub fn place_chromium_beside_owner(server: &mut Server, name: &str, tab: u64, owner: u64, pane: u64) -> Result<(), Error> {
    sync(server, name)?;
    let state = server.workspace_state.snapshot(name);
    let (Some(mut layout), Some(settings)) = (state.layout.tabs.get(&tab).cloned(), state.tabs.get(&tab)) else {
        return Ok(());
    };
    if !beside_owner(&mut layout, &format!("%{owner}"), &format!("%{pane}"), settings.area)? {
        return Ok(());
    }
    server.workspace_state.edit(name, state.revision, Edit::Tab { tab, layout, settings: None })?;
    sync_terminal_geometry(server, name)
}

/// Moves `pane` to the right of `owner` when the owner is outside Main.
/// Returns whether it moved.
fn beside_owner(layout: &mut TabLayout, owner: &str, pane: &str, area: [f32; 4]) -> Result<bool, Error> {
    let Some(anchor) = layout.window(owner) else { return Ok(false) };
    if !anchor.shown || (layout.enabled && anchor.in_main()) || layout.window(pane).is_none() {
        return Ok(false);
    }
    layout.move_beside(pane, owner, Side::Right, area)?;
    layout.focused = pane.into();
    Ok(true)
}

pub fn sync_terminal_geometry(server: &mut Server, name: &str) -> Result<(), Error> {
    let state = server.workspace_state.snapshot(name);
    let inset = server.settings.terminal.content_insets;
    let mut rectangles = BTreeMap::new();
    for (id, layout) in &state.layout.tabs {
        rectangles.extend(layout.clone().arrange(state.tabs[id].area));
    }
    for session in server.sessions.values_mut().filter(|s| s.workspace == name) {
        if let Some(rect) = rectangles.get(&format!("%{}", session.id)) {
            let extent = (f64::from(rect[2]), f64::from(rect[3]));
            if session.layout_extent != Some(extent) {
                session.resize_pixels((extent.0-inset[0]-inset[2]).max(1.), (extent.1-inset[1]-inset[3]).max(1.))?;
                session.layout_extent = Some(extent);
            }
        }
    }
    Ok(())
}

/// Validate and prepare directional layout before spawning the authoritative PTY.
pub fn create_pane(
    server: &mut Server,
    workspace: &str,
    source: u64,
    value: &Value,
) -> Result<u64, Error> {
    let (tab, spawn_source) = server
        .sessions
        .get(&source)
        .filter(|s| s.workspace == workspace)
        .map(|s| (s.tab, Some(s.id)))
        .or_else(|| {
            server.chromiums.get(&source)
                .filter(|b| b.workspace == workspace)
                .map(|b| {
                    let owner = server.sessions.get(&b.owner)
                        .filter(|s| s.workspace == workspace).map(|s| s.id);
                    (b.tab, owner)
                })
        })
        .ok_or("Unknown split source")?;
    let options = value
        .get("spawn")
        .cloned()
        .map(serde_json::from_value::<crate::spawn::SpawnOptions>)
        .transpose()?;
    // A restore recreates a tab's later panes this way, with their saved IDs.
    let saved = crate::SavedIdentity { tab: None, ..crate::SavedIdentity::parse(value)? };
    // An omitted axis creates a free-positioned pane in the source tab.
    let Some(axis) = value.get("axis") else {
        return server.create_with_environment(workspace, Some(tab), spawn_source, options, &[], saved);
    };
    let axis = serde_json::from_value::<graffitty_workspace_core::tiling::Axis>(axis.clone())?;
    let before = value
        .get("before")
        .map(|v| v.as_bool().ok_or("Expected boolean before flag"))
        .transpose()?
        .unwrap_or(false);
    sync(server, workspace)?;
    let old = server.workspace_state.snapshot(workspace);
    let mut layout = old
        .layout
        .tabs
        .get(&tab)
        .cloned()
        .ok_or("Unknown workspace tab")?;
    let key = format!("%{}", server.next);
    layout.add_neighbor(
        &format!("%{source}"),
        &key,
        axis,
        before,
        old.tabs[&tab].area,
    )?;
    let created = server.create_with_environment(workspace, Some(tab), spawn_source, options, &[], saved)?;
    server.sessions.get_mut(&created).unwrap().rect =
        layout.window(&key).unwrap().rect.map(f64::from);
    let applied = (|| -> Result<(), Error> {
        sync(server, workspace)?;
        let revision = server.workspace_state.snapshot(workspace).revision;
        server.workspace_state.edit(
            workspace,
            revision,
            Edit::Tab {
                tab,
                layout,
                settings: None,
            },
        )?;
        Ok(())
    })();
    if let Err(error) = applied {
        server.close(created);
        return Err(error);
    }
    Ok(created)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn tab_transfer_preserves_layout_and_rolls_back_failed_persistence() {
        let dir = std::env::temp_dir().join(format!("graffitty-transfer-{}", uuid::Uuid::new_v4()));
        fs::create_dir(&dir).unwrap();
        let descriptor = dir.join("server.json");
        let mut store = Store::new(&descriptor, "epoch").unwrap();
        store.sync("0", &[(1, Window::new("%1", [0., 0., 100., 80.])),
                          (2, Window::new("%2", [20., 10., 100., 80.]))]).unwrap();
        store.sync("1", &[(3, Window::new("%3", [0., 0., 100., 80.]))]).unwrap();
        let before_source = store.snapshot("0");
        let before_target = store.snapshot("1");
        let backup = dir.join("backup.json");
        fs::rename(&store.path, &backup).unwrap();
        fs::create_dir(&store.path).unwrap();
        assert!(store.transfer_tab("0", "1", 2).is_err());
        assert_eq!(store.snapshot("0"), before_source);
        assert_eq!(store.snapshot("1"), before_target);
        fs::remove_dir(&store.path).unwrap();
        fs::rename(backup, &store.path).unwrap();
        store.transfer_tab("0", "1", 2).unwrap();
        assert_eq!(store.snapshot("0").order, vec![1]);
        assert_eq!(store.snapshot("1").layout.tabs[&2], before_source.layout.tabs[&2]);
        assert_eq!(store.snapshot("1").order, vec![3, 2]);
        let reopened = Store::new(&descriptor, "epoch").unwrap();
        assert_eq!(reopened.snapshot("0"), store.snapshot("0"));
        assert_eq!(reopened.snapshot("1"), store.snapshot("1"));
        fs::remove_dir_all(dir).unwrap();
    }
    #[test]
    fn persisted_layout_is_private_and_scoped_to_its_owner_epoch() {
        let dir =
            std::env::temp_dir().join(format!("graffitty-workspace-{}", uuid::Uuid::new_v4()));
        fs::create_dir(&dir).unwrap();
        let descriptor = dir.join("server.json");
        let mut store = Store::new(&descriptor, "one").unwrap();
        store
            .sync(
                "main",
                &[(1, Window::new("%1", [0., 0., 100., 80.]))],
            )
            .unwrap();
        let current = store.snapshot("main");
        let mut changed = current.layout.tabs[&1].clone();
        changed.windows[0].rect[0] = 320.;
        store
            .edit(
                "main",
                current.revision,
                Edit::Tab {
                    tab: 1,
                    layout: changed,
                    settings: None,
                },
            )
            .unwrap();
        let reopened = Store::new(&descriptor, "one").unwrap();
        assert_eq!(reopened.snapshot("main"), store.snapshot("main"));
        assert!(
            Store::new(&descriptor, "two")
                .unwrap()
                .snapshot("main")
                .layout
                .tabs
                .is_empty()
        );
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            assert_eq!(
                fs::metadata(&store.path).unwrap().permissions().mode() & 0o777,
                0o600
            );
        }
        fs::remove_dir_all(dir).unwrap();
    }
}

#[cfg(test)]
mod chromium_placement_tests {
    use super::*;

    const AREA: [f32; 4] = [0., 0., 2000., 1200.];

    fn tab(enabled: bool, owner: impl FnOnce(&mut Window)) -> TabLayout {
        let mut layout = TabLayout { enabled, gap: Some(10.), ..Default::default() };
        let mut terminal = Window::new("%1", [100., 100., 600., 400.]);
        owner(&mut terminal);
        layout.windows.push(terminal);
        layout.windows.push(Window::new("%2", [300., 300., 800., 500.])); // Main's other pane.
        // The new Chromium, where a new pane lands by default.
        layout.windows.push(Window::new("%9", [1050., 60., 1000., 750.]));
        layout
    }

    #[test]
    fn chromium_from_a_terminal_outside_main_goes_to_its_right_in_its_layer() {
        let cases: [(&str, bool, fn(&mut Window)); 3] = [
            ("floating tab", false, |_| {}),
            ("stashed in a tiling tab", true, |w| w.stashed = true),
            ("graph node in a tiling tab", true, |w| w.graph_floating = true),
        ];
        for (name, enabled, owner) in cases {
            let mut layout = tab(enabled, owner);
            assert!(beside_owner(&mut layout, "%1", "%9", AREA).unwrap(), "{name}");
            let anchor = layout.window("%1").unwrap().clone();
            let chromium = layout.window("%9").unwrap();
            assert_eq!(chromium.rect[0], anchor.rect[0] + anchor.rect[2] + 10., "{name}: one gap to the right");
            assert_eq!(chromium.rect[1], anchor.rect[1], "{name}: level with the terminal");
            assert_eq!((chromium.stashed, chromium.graph_floating), (anchor.stashed, anchor.graph_floating), "{name}: same layer");
            assert!(!chromium.in_main() || !enabled, "{name}: not tiled into Main");
            assert_eq!(layout.focused, "%9", "{name}: the new Chromium is focused");
        }
    }

    #[test]
    fn chromium_from_a_terminal_in_main_stays_in_main() {
        let mut layout = tab(true, |_| {});
        assert!(!beside_owner(&mut layout, "%1", "%9", AREA).unwrap());
        assert_eq!(layout.window("%9").unwrap().rect, [1050., 60., 1000., 750.]);
    }
}
