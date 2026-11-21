//! The element description buffer.
//!
//! Adapted from gpui-kit `crates/shell/src/spec.rs` (Apache-2.0, Longbridge).
//! A script builder records operations into this arena during `render()`; a
//! successful render freezes it and layout replays it on every frame.
//!
//! Reading is non-destructive, which is what keeps repainting off the VM.
//!
//! Templates, registered components and virtual lists are not carried over:
//! the four elements here (`div`, text, `svg`, `image`) are what Graffitty's
//! frontends can paint everywhere, Android included.
use crate::value::Bridged;

pub type SpecId = u32;
pub type CallbackId = u32;

#[derive(Clone, Debug, PartialEq)]
pub enum Component {
    Div,
    Text(String),
    /// An SVG file path, tinted with the text colour, as gpui-kit's `svg()`.
    Svg(String),
    /// A full-colour picture.
    Image(String),
}

/// One recorded builder call.
#[derive(Clone, Debug, PartialEq)]
pub enum SpecOp {
    /// A no-argument style method, addressed by index into the style table.
    NullaryStyle(u16),
    /// A style method that takes one argument.
    ParamStyle(&'static str, Bridged),
    /// A behaviour method (`id`, `tooltip`, `mode`, `spin`, `frames`, …).
    Method(&'static str, Vec<Bridged>),
    /// An event handler: the method, its non-function arguments
    /// (`on_mouse_down("left", …)` carries the button), and the callback.
    Callback(&'static str, Vec<Bridged>, CallbackId),
    /// A state style — hover, active — recorded into a detached node, so the
    /// ordinary style methods serve there too and there is no second grammar.
    StateStyle(&'static str, SpecId),
}

#[derive(Clone, Debug, Default)]
pub struct SpecNode {
    pub component: Option<Component>,
    pub ops: Vec<SpecOp>,
    pub children: Vec<SpecId>,
}

/// Element descriptions for one script render.
#[derive(Clone, Debug, Default)]
pub struct SpecArena {
    nodes: Vec<SpecNode>,
    callbacks: u32,
}

impl SpecArena {
    pub fn push(&mut self, component: Component) -> SpecId {
        self.nodes.push(SpecNode { component: Some(component), ops: Vec::new(), children: Vec::new() });
        (self.nodes.len() - 1) as SpecId
    }

    /// A node that collects styles without being drawn (a hover declaration).
    pub fn detached(&mut self) -> SpecId {
        self.nodes.push(SpecNode::default());
        (self.nodes.len() - 1) as SpecId
    }

    pub fn record(&mut self, id: SpecId, op: SpecOp) -> Result<(), String> {
        self.node_mut(id)?.ops.push(op);
        Ok(())
    }

    pub fn next_callback(&mut self) -> CallbackId {
        self.callbacks += 1;
        self.callbacks - 1
    }

    pub fn attach(&mut self, parent: SpecId, child: SpecId) -> Result<(), String> {
        if parent == child {
            return Err("an element cannot be its own child".into());
        }
        self.node(child)?;
        self.node_mut(parent)?.children.push(child);
        Ok(())
    }

    pub fn node(&self, id: SpecId) -> Result<&SpecNode, String> {
        self.nodes.get(id as usize).ok_or_else(|| format!("unknown element {id}"))
    }

    fn node_mut(&mut self, id: SpecId) -> Result<&mut SpecNode, String> {
        self.nodes.get_mut(id as usize).ok_or_else(|| format!("unknown element {id}"))
    }

    pub fn len(&self) -> usize {
        self.nodes.len()
    }

    pub fn is_empty(&self) -> bool {
        self.nodes.is_empty()
    }

    pub fn callback_count(&self) -> u32 {
        self.callbacks
    }

    /// The tree as indented text, for tests and diagnostics.
    pub fn debug_tree(&self, root: SpecId) -> String {
        fn walk(arena: &SpecArena, id: SpecId, depth: usize, out: &mut String) {
            let Ok(node) = arena.node(id) else { return };
            let name = match &node.component {
                Some(Component::Div) => "div".to_owned(),
                Some(Component::Text(text)) => format!("text {text:?}"),
                Some(Component::Svg(path)) => format!("svg {path:?}"),
                Some(Component::Image(path)) => format!("image {path:?}"),
                None => "<detached>".to_owned(),
            };
            out.push_str(&"  ".repeat(depth));
            out.push_str(&name);
            for op in &node.ops {
                match op {
                    SpecOp::NullaryStyle(index) => out.push_str(&format!(" .{}", crate::style::nullary_name(*index))),
                    SpecOp::ParamStyle(name, value) => out.push_str(&format!(" .{name}({value:?})")),
                    SpecOp::Method(name, args) => out.push_str(&format!(" .{name}({args:?})")),
                    SpecOp::Callback(name, args, _) => out.push_str(&format!(" .{name}({args:?}, fn)")),
                    SpecOp::StateStyle(name, _) => out.push_str(&format!(" .{name}(…)")),
                }
            }
            out.push('\n');
            for child in &node.children {
                walk(arena, *child, depth + 1, out);
            }
        }
        let mut out = String::new();
        walk(self, root, 0, &mut out);
        out
    }
}
