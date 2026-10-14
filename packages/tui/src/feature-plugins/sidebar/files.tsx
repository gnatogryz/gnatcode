import type { TuiPlugin, TuiPluginApi } from "@opencode-ai/plugin/tui"
import type { BuiltinTuiPlugin } from "../builtins"
import { createMemo, For, Show, createSignal } from "solid-js"
import { spawn } from "node:child_process"
import { createHash } from "node:crypto"
import { existsSync, mkdirSync, writeFileSync } from "node:fs"
import os from "node:os"
import path from "node:path"
import { Locale } from "../../util/locale"

const id = "internal:sidebar-files"

type DiffItem = { file: string; additions: number; deletions: number; patch?: string; status?: string }

function launch(command: string, args: string[]) {
  const child = spawn(command, args, { stdio: "ignore", detached: true })
  child.on("error", () => {})
  child.unref()
}

function splitPatch(patch: string) {
  const before: string[] = []
  const after: string[] = []
  let hunk = false
  let side: "before" | "after" | "both" = "both"
  let beforeNewline = true
  let afterNewline = true
  for (const line of patch.split("\n")) {
    if (line.startsWith("@@")) {
      hunk = true
      continue
    }
    if (!hunk || line === "") continue
    if (line.startsWith("\\")) {
      if (line.includes("No newline at end of file")) {
        if (side !== "after") beforeNewline = false
        if (side !== "before") afterNewline = false
      }
      continue
    }
    const content = line.slice(1)
    const sign = line.charAt(0)
    if (sign === "-") {
      before.push(content)
      side = "before"
    } else if (sign === "+") {
      after.push(content)
      side = "after"
    } else {
      before.push(content)
      after.push(content)
      side = "both"
    }
  }
  return {
    before: before.length === 0 ? "" : before.join("\n") + (beforeNewline ? "\n" : ""),
    after: after.length === 0 ? "" : after.join("\n") + (afterNewline ? "\n" : ""),
  }
}

function snapshotFile(file: string, content: string) {
  const dir = path.join(os.tmpdir(), "opencode-snapshot", createHash("sha1").update(file).digest("hex"))
  mkdirSync(dir, { recursive: true })
  const target = path.join(dir, path.basename(file))
  writeFileSync(target, content)
  return target
}

function openInCode(root: string, item: DiffItem) {
  const target = path.isAbsolute(item.file) ? item.file : path.join(root, item.file)
  if (!item.patch || !item.status) {
    launch("code", [target])
    return
  }
  const { before, after } = splitPatch(item.patch)
  const original = snapshotFile(item.file, before)
  const current = existsSync(target) ? target : snapshotFile(`${item.file}.after`, after)
  launch("code", ["--diff", original, current])
}

function changeCountWidth(item: { additions: number; deletions: number }) {
  return [item.additions ? `+${item.additions}` : "", item.deletions ? `-${item.deletions}` : ""]
    .filter(Boolean)
    .join(" ").length
}

function View(props: { api: TuiPluginApi; session_id: string }) {
  const [open, setOpen] = createSignal(true)
  const theme = () => props.api.theme.current
  const list = createMemo(() => props.api.state.session.diff(props.session_id))

  return (
    <Show when={list().length > 0}>
      <box>
        <box flexDirection="row" gap={1} justifyContent="space-between">
          <box flexDirection="row" gap={1} onMouseDown={() => list().length > 2 && setOpen((x) => !x)}>
            <Show when={list().length > 2}>
              <text fg={theme().text}>{open() ? "▼" : "▶"}</text>
            </Show>
            <text fg={theme().text}>
              <b>Modified Files</b>
            </text>
          </box>
          <box
            onMouseDown={() => {
              void props.api.client.session.clearDiff({ sessionID: props.session_id }).catch(() => {})
            }}
          >
            <text fg={theme().textMuted}>✕</text>
          </box>
        </box>
        <Show when={list().length <= 2 || open()}>
          <For each={list()}>
            {(item) => (
              <box
                flexDirection="row"
                gap={1}
                justifyContent="space-between"
                onMouseDown={() => openInCode(props.api.state.path.worktree, item as DiffItem)}
              >
                <text fg={theme().textMuted} wrapMode="none">
                  {Locale.truncateLeft(item.file, Math.max(2, 36 - changeCountWidth(item)))}
                </text>
                <box flexDirection="row" gap={1} flexShrink={0}>
                  <Show when={item.additions}>
                    <text fg={theme().diffAdded}>+{item.additions}</text>
                  </Show>
                  <Show when={item.deletions}>
                    <text fg={theme().diffRemoved}>-{item.deletions}</text>
                  </Show>
                </box>
              </box>
            )}
          </For>
        </Show>
      </box>
    </Show>
  )
}

const tui: TuiPlugin = async (api) => {
  api.slots.register({
    order: 500,
    slots: {
      sidebar_content(_ctx, props) {
        return <View api={api} session_id={props.session_id} />
      },
    },
  })
}

const plugin: BuiltinTuiPlugin = {
  id,
  tui,
}

export default plugin
