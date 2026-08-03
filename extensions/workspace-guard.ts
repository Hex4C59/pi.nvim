import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { createWorkspaceGuard, permissionModeGuidance } from "./lib/security-policy.mjs";

export default function (pi: ExtensionAPI) {
  pi.on("tool_call", createWorkspaceGuard());
  pi.on("before_agent_start", (event) => ({
    systemPrompt: `${event.systemPrompt}\n\n${permissionModeGuidance("plan")}\n- All reads are restricted to the canonical current workspace.`,
  }));
}
