// OpenCode v2.0.32+ native plugin; no companion process.
import { client, observe } from "./integration.mjs"
import { OpenCodeIntegration } from "./runtime.mjs"

export default function (ctx, { home }) {
    if (!process.env.GRAFFITTY_SOCKET || !process.env.GRAFFITTY_TOKEN) return
    let cached, revision = 0, exported = -1, stopped = false
    let observer
    const unsubscribe = ctx.data.listen(() => { revision++; observer?.changed() })
    const options = () => ({ signal: AbortSignal.timeout(5000) })
    const current = () => {
      const route = ctx.ui.router.current()
      return route.type === "session" ? ctx.data.session.root(route.sessionID) : ""
    }
    const rpc = client()
    const runtime = new OpenCodeIntegration(rpc, home, {
      async prompt(request) {
        if (stopped || current() !== request.sessionID) throw new Error("OpenCode session changed")
        await ctx.client.session.prompt({ sessionID: request.sessionID, id: request.messageID,
          text: request.text, delivery: "queue" }, options())
        revision++
      },
      async cancel(request) {
        await ctx.client.session.inbox.cancel({ sessionID: request.sessionID, inboxID: request.messageID }, options())
      },
    })
    observer = observe(rpc, async () => {
      const sessionID = current()
      if (!sessionID) {
        cached = undefined
        await runtime.update({ sessionID: "", pid: process.pid })
        return
      }
      const version = revision
      if (exported !== version || cached?.info.id !== sessionID) {
        cached = await ctx.client.session.export({ sessionID, sanitize: false }, options())
      }
      const pending = await ctx.client.session.inbox.list({ sessionID }, options())
      if (current() !== sessionID) return
      await runtime.update({ sessionID, pid: process.pid, messages: cached.messages, pending,
        status: ctx.data.session.status(sessionID),
        waiting: (ctx.data.session.permission.list(sessionID)?.length ?? 0) > 0 ||
          (ctx.data.session.form.list(sessionID)?.length ?? 0) > 0 })
      exported = version
    }, {
      failed: error => ctx.ui.toast.show({ title: "Graffitty", message: `${error.message}. Retrying.`, variant: "error" }),
      recovered: () => ctx.ui.toast.show({ title: "Graffitty", message: "Reconnected.", variant: "success" }),
      keepalive: () => runtime.binding?.refresh(),
      heartbeat: reply => runtime.ensureRegistered(reply),
    })
    return async () => {
      stopped = true
      unsubscribe()
      await observer.stop()
      await runtime.close()
    }
}
