extends RefCounted
## The two clocks of a session/tab switch, shared by every world and effect.
##
## The live destination takes over as soon as its arrival has landed (and the
## camera with it).
##
## The departure never holds it back: departing pieces still in flight at the
## handoff keep their own clock over the live surface.
##
## An effect therefore describes only when each half moves; worlds that travel
## between walls lengthen the camera, not the effect.

enum Anchor {
	START, ## Arrival begins `delay` after the start: the old view is replaced.
	DEADLINE, ## Arrival lands at the deadline, sharing the camera's landing.
	STRETCH, ## Both halves span the whole deadline (one shared dolly clock).
}

var departure := 0.0
var arrival := 0.0
var delay := 0.0
var anchor: Anchor = Anchor.DEADLINE
## Earliest handoff for DEADLINE effects (camera flight plus settle).
var floor := 0.0


static func make(anchor: Anchor, departure: float, arrival: float, delay := 0.0, floor := 0.0) -> RefCounted:
	var timeline = load("res://scenes/SwitchTimeline.gd").new()
	timeline.anchor = anchor
	timeline.departure = departure
	timeline.arrival = arrival
	timeline.delay = delay
	timeline.floor = floor
	return timeline


## When the live destination can replace the captured arrival.
func landing() -> float:
	match anchor:
		Anchor.START: return delay + arrival
		Anchor.STRETCH: return arrival
	return maxf(floor, arrival)


func departure_duration(deadline: float) -> float:
	return deadline if anchor == Anchor.STRETCH else departure


func arrival_duration(deadline: float) -> float:
	return deadline if anchor == Anchor.STRETCH else minf(arrival, deadline)


func arrival_start(deadline: float) -> float:
	var latest := maxf(deadline - arrival_duration(deadline), 0.0)
	return minf(delay, latest) if anchor == Anchor.START else latest
