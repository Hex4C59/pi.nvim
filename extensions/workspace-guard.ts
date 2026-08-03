import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { createWorkspaceGuard, workspaceReadOnlyGuidance } from "./lib/security/workspace.mjs";

export default function (pi: ExtensionAPI) {
  pi.on("tool_call", createWorkspaceGuard());
  pi.on("before_agent_start", (event) => ({
    systemPrompt: `${event.systemPrompt}\n\n${workspaceReadOnlyGuidance()}`,
  }));
}
