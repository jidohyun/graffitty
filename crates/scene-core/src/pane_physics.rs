//! Floating-pane contact response. No scene objects or engine callbacks are retained.
use glam::{IVec2, Vec2};
use indexmap::{IndexMap, IndexSet};
use std::collections::BTreeSet;
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Rect {
    pub position: Vec2,
    pub size: Vec2,
}
impl Rect {
    pub fn center(self) -> Vec2 {
        self.position + self.size * 0.5
    }
    pub fn end(self) -> Vec2 {
        self.position + self.size
    }
}
pub type Rectangles = IndexMap<String, Rect>;
/// A movable pane is either free or stashed outside the main area.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Placement {
    Free,
    Stashed,
}
pub type Movable = IndexMap<String, Placement>;
const CELL: f32 = 512.;
const GAP: f32 = 72.;
#[derive(Default)]
pub struct PanePhysics {
    velocities: IndexMap<String, Vec2>,
    active: IndexSet<String>,
    indexed: Rectangles,
    cells: IndexMap<(i32, i32), IndexSet<String>>,
    memberships: IndexMap<String, Vec<(i32, i32)>>,
    last_movable: Movable,
    last_area: Rect,
    pair_checks: usize,
    idle_age: f32,
}
impl PanePhysics {
    pub fn indexed(&self) -> &Rectangles {
        &self.indexed
    }
    pub fn sleep(&mut self) {
        self.active.clear();
        self.velocities.clear();
    }
    pub fn reset(&mut self) {
        *self = Self::default();
    }
    pub fn sleeping(&self) -> bool {
        self.active.is_empty()
    }
    pub fn pair_checks(&self) -> usize {
        self.pair_checks
    }
    pub fn velocities(&self) -> &IndexMap<String, Vec2> {
        &self.velocities
    }
    fn remove(&mut self, key: &str) {
        for cell in self.memberships.shift_remove(key).unwrap_or_default() {
            if let Some(keys) = self.cells.get_mut(&cell) {
                keys.shift_remove(key);
                if keys.is_empty() {
                    self.cells.shift_remove(&cell);
                }
            }
        }
        self.indexed.shift_remove(key);
    }
    fn index(&mut self, key: &str, rect: Rect) {
        self.remove(key);
        self.indexed.insert(key.into(), rect);
        let first: IVec2 = ((rect.position - Vec2::splat(GAP * 0.5)) / CELL)
            .floor()
            .as_ivec2();
        let last: IVec2 = ((rect.end() + Vec2::splat(GAP * 0.5)) / CELL)
            .floor()
            .as_ivec2();
        let mut occupied = vec![];
        for x in first.x..=last.x {
            for y in first.y..=last.y {
                self.cells.entry((x, y)).or_default().insert(key.into());
                occupied.push((x, y));
            }
        }
        self.memberships.insert(key.into(), occupied);
    }
    fn neighbours(&self, key: &str) -> IndexSet<String> {
        self.memberships
            .get(key)
            .into_iter()
            .flatten()
            .flat_map(|cell| self.cells.get(cell).into_iter().flatten().cloned())
            .collect()
    }
    /// The optional projection/reachability policy belongs to the frontend.
    /// Only free panes invoke it; all state and contact integration stay here.
    pub fn step(
        &mut self,
        rectangles: &Rectangles,
        movable: &Movable,
        area: Rect,
        dt: f32,
        mut constrain: impl FnMut(&str, Rect) -> Rect,
    ) -> Rectangles {
        self.pair_checks = 0;
        let mut changed = false;
        let removed: Vec<_> = self
            .indexed
            .keys()
            .filter(|key| !rectangles.contains_key(*key))
            .cloned()
            .collect();
        for key in removed {
            self.active.extend(self.neighbours(&key));
            changed = true;
            self.remove(&key);
            self.active.shift_remove(&key);
            self.velocities.shift_remove(&key);
        }
        for (key, &rect) in rectangles {
            if self.indexed.get(key) != Some(&rect) {
                changed = true;
                self.index(key, rect);
                self.active.insert(key.clone());
            }
            if movable.get(key) != self.last_movable.get(key) || area != self.last_area {
                changed = true;
                self.active.insert(key.clone());
            }
            if !movable.contains_key(key) {
                self.velocities.shift_remove(key);
            }
        }
        self.last_movable = movable.clone();
        self.last_area = area;
        if movable.is_empty() {
            self.active.clear();
        }
        if self.active.is_empty() {
            return rectangles.clone();
        }
        let dt = dt.clamp(0., 1. / 30.);
        self.idle_age = if changed { 0. } else { self.idle_age + dt };
        let warmth = (-(self.idle_age - 2.).max(0.) * 0.6).exp();
        let mut queue: Vec<_> = self.active.iter().cloned().collect();
        let mut visited = self.active.clone();
        let mut pairs = BTreeSet::new();
        let mut forces: IndexMap<String, Vec2> = IndexMap::new();
        let mut cursor = 0;
        while cursor < queue.len() {
            let key = queue[cursor].clone();
            cursor += 1;
            for other in self.neighbours(&key) {
                if key == other || (!movable.contains_key(&key) && !movable.contains_key(&other)) {
                    continue;
                }
                let pair = if key < other {
                    (key.clone(), other.clone())
                } else {
                    (other.clone(), key.clone())
                };
                if !pairs.insert(pair) {
                    continue;
                }
                self.pair_checks += 1;
                let (Some(&a), Some(&b)) = (rectangles.get(&key), rectangles.get(&other)) else {
                    continue;
                };
                let delta = b.center() - a.center();
                let overlap = (a.size + b.size) * 0.5 + Vec2::splat(GAP) - delta.abs();
                if overlap.x <= 0. || overlap.y <= 0. {
                    continue;
                }
                let x_weight = 1. / (1. + ((overlap.x - overlap.y) / 24.).clamp(-20., 20.).exp());
                let push = Vec2::new(
                    if delta.x >= 0. { 1. } else { -1. },
                    if delta.y >= 0. { 1. } else { -1. },
                ) * overlap
                    * Vec2::new(x_weight, 1. - x_weight)
                    * 28.;
                if movable.contains_key(&key) {
                    *forces.entry(key.clone()).or_default() -= push;
                }
                if movable.contains_key(&other) {
                    *forces.entry(other.clone()).or_default() += push;
                }
                if movable.contains_key(&other) && visited.insert(other.clone()) {
                    queue.push(other);
                }
            }
        }
        let mut result = rectangles.clone();
        self.active.clear();
        for key in visited {
            let (Some(&placement), Some(&rect)) = (movable.get(&key), rectangles.get(&key)) else {
                continue;
            };
            let force = forces.get(&key).copied().unwrap_or_default() * warmth;
            let mut velocity = self.velocities.get(&key).copied().unwrap_or_default();
            if force == Vec2::ZERO && velocity.length() < 0.5 {
                self.velocities.shift_remove(&key);
                continue;
            }
            velocity = ((velocity + force * dt) * (-8. * dt).exp()).clamp_length_max(500.);
            let mut next = rect;
            next.position += velocity * dt;
            if placement == Placement::Stashed {
                let center = rect.center();
                if center.x >= area.end().x {
                    next.position.x = next.position.x.max(area.end().x - rect.size.x * 0.5);
                } else if center.x <= area.position.x {
                    next.position.x = next.position.x.min(area.position.x - rect.size.x * 0.5);
                } else if center.y >= area.end().y {
                    next.position.y = next.position.y.max(area.end().y - rect.size.y * 0.5);
                } else {
                    next.position.y = next.position.y.min(area.position.y - rect.size.y * 0.5);
                }
            } else {
                next = constrain(&key, next);
            }
            let actual = (next.position - rect.position) / dt.max(0.00001);
            if actual.length() > 0.5 || (force.length() > 2. && actual.length() > 0.001) {
                self.active.insert(key.clone());
                self.velocities.insert(key.clone(), actual);
            } else {
                self.velocities.shift_remove(&key);
            }
            result.insert(key.clone(), next);
            if next != rect {
                self.index(&key, next);
            }
        }
        result
    }
}
pub fn reachable(mut rect: Rect, area: Rect) -> Rect {
    // max/min also accommodates viewports narrower than the nominal header inset.
    rect.position.x = rect
        .position
        .x
        .max(area.position.x - rect.size.x + 80.)
        .min(area.end().x - 80.);
    rect.position.y = rect.position.y.max(area.position.y).min(area.end().y - 34.);
    rect
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn sparse_contacts_sleep_and_fixed_panes_do_not_move() {
        let area = Rect {
            position: Vec2::ZERO,
            size: Vec2::new(1200., 800.),
        };
        let fixed = Rect {
            position: Vec2::new(100., 100.),
            size: Vec2::splat(200.),
        };
        let mut rects = IndexMap::from([("fixed".into(), fixed), ("free".into(), fixed)]);
        let movable = IndexMap::from([("free".into(), Placement::Free)]);
        let mut physics = PanePhysics::default();
        for _ in 0..1200 {
            rects = physics.step(&rects, &movable, area, 1. / 60., |_, r| reachable(r, area));
        }
        assert_eq!(rects["fixed"], fixed);
        assert_ne!(rects["free"], fixed);
        assert!(physics.sleeping());
        let before = rects.clone();
        assert_eq!(
            physics.step(&rects, &movable, area, 1. / 60., |_, r| r),
            before
        );
        assert_eq!(physics.pair_checks(), 0);
        physics.reset();
        assert!(physics.velocities().is_empty());
    }
}
