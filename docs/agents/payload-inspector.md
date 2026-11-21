# Inspect a payload


```sh
gft node payload-inspector
```

Connect an upstream output to both the inspector and your normal consumer.
The inspector prints its own copy; it does not consume the consumer's event.

- `--json`: compact JSON lines for capture.
- `--once`: exit after one event.
- `--name "Review debug"`: choose a recognizable node title.
- **Ctrl+C**: exit; unread events remain queued for a later restart.

This is a live debugging view, not guaranteed durable capture.
A crash after printing but before acknowledgment can print the same event again; compare `event_id` to detect duplicates.

See [Automation nodes](automation.md) for other tools.
