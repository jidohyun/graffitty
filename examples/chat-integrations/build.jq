{
  text: ("Build #" + (.payload.build_id | tostring) + ": " + .text),
  content: (if .payload.screenshot then [{
    type: "image", path: .payload.screenshot, mime_type: "image/png",
    alt: "Completed build screenshot"
  }] else [] end)
}
