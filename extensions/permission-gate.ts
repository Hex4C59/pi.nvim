import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { createPermissionController, createPermissionToolModeController } from "./lib/security/permission.mjs";

export default function (pi: ExtensionAPI) {
  const tools = createPermissionToolModeController(pi);
  const permissions = createPermissionController({ onModeChange: tools.onModeChange });
  pi.on("tool_call", permissions.onToolCall);
  pi.on("session_start", permissions.onSessionStart);
  pi.on("before_agent_start", (event, ctx) => {
    tools.enforce(permissions.getMode());
    return permissions.onBeforeAgentStart(event, ctx);
  });
  pi.on("session_shutdown", () => {
    tools.clear();
    permissions.onSessionShutdown();
  });
  pi.registerCommand("permissions", {
    description: "Select the session permission mode",
    handler: permissions.command,
  });
  pi.registerCommand("mode", {
    description: "Alias for /permissions",
    handler: permissions.command,
  });
}
