# Playwright attachment protocol and evidence

Lease lifetime, authorization, and recorded test coverage. For attachment code, see [Playwright attachment](../automation-and-extensions/playwright-compatibility.md).

## Host protocol

`chromium.attach` uses the normal [workspace API](../automation-and-extensions/agent-chromium-api.md), requiring
the owning workspace's token and an explicit chromium ID. It returns a random
single-client loopback WebSocket endpoint and the primary CDP target ID. Unused
leases expire in 30 seconds. The endpoint URL is a bearer credential; do not log
or share it. The wrapper redacts it from attachment errors.

The host bridges this connection to Chromium's private DevTools pipe. There is **no
unauthenticated Chromium debugging listener** and no scanning of chromium profiles.
Chromium-level automation is limited to that Graffitty chromium session; the lease
covers its tabs, not just the primary page. Revoking the workspace or closing the
chromium disconnects automation.

### Release and revocation

Client disconnect releases the lease and detaches protocol sessions without closing the
chromium. `chromium.detach` requires the matching lease, so an old client cannot detach
a newer one.

### Rejected operations

`Browser.close` and chromium-context creation/disposal are rejected. Tests should
borrow the existing page. This is a CDP connection, not a Playwright server:
`use.connectOptions` cannot replace the supplied attachment fixture.

## Verified behavior

The real GUI E2E exercises the ordinary production host, the authenticated socket,
and the package's actual exports. It uses a local HTTP application, not a
replacement chromium or the old test-only remote-debugging wrapper.

Verified with Playwright 1.63.0, Node 26.8.1, Bun 1.4.2, and the bundled CEF
Chromium 150.0.7871.253 on macOS arm64:

- Existing primary-page identity and retained chromium process.
- HTTP navigation, role/label locators, fill, trusted click and condition waits.
- Same-origin iframe and open shadow DOM interactions.
- Playwright screenshots as test artifacts; GPU frames remain the GUI transport.
- Disconnect/reconnect with retained page state.
- Standard Playwright Test fixture, assertions, and worker cleanup.
- Workspace authorization, lease exclusivity, unauthenticated WebSocket rejection,
  transport-disconnect cleanup, stale-lease isolation, and workspace revocation.

Run from `ts/packages/playwright/`:

```sh
npm test
npm run test:e2e
```

Screenshots and host logs remain in the reported temporary artifact directory.
