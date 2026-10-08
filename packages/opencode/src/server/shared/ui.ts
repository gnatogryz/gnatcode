import { Effect } from "effect"
import { HttpServerResponse } from "effect/unstable/http"

// This fork ships the terminal (TUI) client only. There is no embedded web UI
// and no upstream fallback, so browser requests to the server receive 404.
export function serveUIEffect() {
  return Effect.succeed(HttpServerResponse.jsonUnsafe({ error: "Not Found" }, { status: 404 }))
}
