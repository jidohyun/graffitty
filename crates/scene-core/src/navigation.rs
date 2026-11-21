//! Weighted world navigation, independent of world loading and camera presentation.
/// World-owned navigation data. Queries borrow the graph; replacement happens
/// only when loading a different graph, never as part of a route query.
#[derive(Default)]
pub struct NavigationGraph {
    edges: Vec<Vec<(usize, f64)>>,
}

impl NavigationGraph {
    pub fn replace(&mut self, edges: Vec<Vec<(usize, f64)>>) {
        self.edges = edges;
    }

    pub fn clear(&mut self) {
        self.edges.clear();
    }

    /// Recompute edge costs after a world adjusts its authored camera positions.
    pub fn reweight(&mut self, positions: &[glam::Vec3]) -> bool {
        if positions.len() != self.edges.len() || positions.iter().any(|p| !p.is_finite()) {
            return false;
        }
        for (from, links) in self.edges.iter_mut().enumerate() {
            for (to, cost) in links {
                if let Some(position) = positions.get(*to) {
                    *cost = f64::from(positions[from].distance(*position));
                }
            }
        }
        true
    }

    pub fn route(&self, from: usize, to: usize) -> Vec<usize> {
        shortest_path(&self.edges, from, to)
    }
}

#[derive(Clone, Copy, Debug)]
struct Visit {
    cost: f64,
    node: usize,
}

/// Preserve Godot's equal-cost expansion order as well as its f64 costs. A
/// different heap tie policy can select a different camera route at a junction.
#[derive(Default)]
struct Frontier(Vec<Visit>);
impl Frontier {
    fn push(&mut self, visit: Visit) {
        self.0.push(visit);
        let mut child = self.0.len() - 1;
        while child > 0 {
            let parent = (child - 1) / 2;
            if self.0[parent].cost <= self.0[child].cost {
                break;
            }
            self.0.swap(parent, child);
            child = parent;
        }
    }
    fn pop(&mut self) -> Option<Visit> {
        let top = *self.0.first()?;
        let last = self.0.pop().unwrap();
        if !self.0.is_empty() {
            self.0[0] = last;
            let mut parent = 0;
            loop {
                let left = parent * 2 + 1;
                let right = left + 1;
                let mut smallest = parent;
                if left < self.0.len() && self.0[left].cost < self.0[smallest].cost {
                    smallest = left;
                }
                if right < self.0.len() && self.0[right].cost < self.0[smallest].cost {
                    smallest = right;
                }
                if smallest == parent {
                    break;
                }
                self.0.swap(parent, smallest);
                parent = smallest;
            }
        }
        Some(top)
    }
}

/// Includes both endpoints. Invalid endpoints and unreachable destinations have no path.
/// Costs remain f64: reducing the accumulated cost to f32 can discard valid heap entries.
pub fn shortest_path(edges: &[Vec<(usize, f64)>], from: usize, to: usize) -> Vec<usize> {
    if from >= edges.len() || to >= edges.len() {
        return vec![];
    }
    let mut costs = vec![f64::INFINITY; edges.len()];
    let mut previous = vec![usize::MAX; edges.len()];
    let mut heap = Frontier::default();
    costs[from] = 0.;
    heap.push(Visit {
        cost: 0.,
        node: from,
    });
    while let Some(Visit { cost, node }) = heap.pop() {
        if cost > costs[node] {
            continue;
        }
        if node == to {
            break;
        }
        for &(next, distance) in &edges[node] {
            if next >= edges.len() || !distance.is_finite() || distance < 0. {
                continue;
            }
            let cost = cost + distance;
            if cost < costs[next] {
                costs[next] = cost;
                previous[next] = node;
                heap.push(Visit { cost, node: next });
            }
        }
    }
    if !costs[to].is_finite() {
        return vec![];
    }
    let mut path = vec![to];
    while *path.last().unwrap() != from {
        path.push(previous[*path.last().unwrap()]);
    }
    path.reverse();
    path
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn queries_borrow_owned_graph_and_replacement_retires_old_edges() {
        let mut graph = NavigationGraph::default();
        assert!(graph.route(0, 1).is_empty());
        graph.replace(vec![vec![(1, 2.)], vec![(2, 3.)], vec![]]);
        let storage = graph.edges.as_ptr();
        for _ in 0..20 {
            assert_eq!(graph.route(0, 2), [0, 1, 2]);
            assert_eq!(graph.edges.as_ptr(), storage);
        }
        graph.replace(vec![vec![], vec![]]);
        assert!(graph.route(0, 1).is_empty());
        assert!(graph.route(0, 2).is_empty());
        graph.clear();
        assert!(graph.route(0, 0).is_empty());
    }
    #[test]
    fn moved_destinations_update_costs_without_replacing_topology() {
        use glam::Vec3;
        let mut graph = NavigationGraph::default();
        graph.replace(vec![vec![(1, 1.), (2, 4.)], vec![(2, 1.)], vec![]]);
        assert_eq!(graph.route(0, 2), [0, 1, 2]);
        assert!(!graph.reweight(&[Vec3::ZERO]));
        assert_eq!(graph.route(0, 2), [0, 1, 2]);
        assert!(graph.reweight(&[Vec3::ZERO, Vec3::Y * 20., Vec3::X * 2.]));
        assert_eq!(graph.route(0, 2), [0, 2]);
    }
    #[test]
    fn equal_cost_branches_keep_the_authored_godot_route() {
        let graph = vec![
            vec![(1, 1.), (2, 1.), (3, 1.)],
            vec![],
            vec![(4, 1.)],
            vec![(4, 1.)],
            vec![],
        ];
        assert_eq!(shortest_path(&graph, 0, 4), [0, 3, 4]);
    }
    #[test]
    fn weighted_paths_keep_precision_and_reject_invalid_edges() {
        let graph = vec![
            vec![(1, 0.10000000001), (2, 0.3), (9, 1.)],
            vec![(2, 0.1)],
            vec![],
            vec![],
        ];
        assert_eq!(shortest_path(&graph, 0, 2), [0, 1, 2]);
        assert_eq!(shortest_path(&graph, 1, 1), [1]);
        assert!(shortest_path(&graph, 0, 3).is_empty());
        assert!(shortest_path(&graph, 9, 0).is_empty());
        assert!(shortest_path(&[vec![(1, f64::NAN), (1, -1.)], vec![]], 0, 1).is_empty());
    }
}
