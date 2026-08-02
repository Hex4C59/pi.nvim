import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const dangerous = [
  /\brm\s+(?:-[^\s]*r[^\s]*\s+|--recursive\b)/i,
  /\bsudo\b/i,
  /\bgit\s+reset\s+--hard\b/i,
  /\bgit\s+clean\s+-[^\s]*f/i,
  /\b(?:mkfs|shutdown|reboot|poweroff)\b/i,
  /\bdd\b[^\n]*\bof=\/dev\//i,
  /\b(?:chmod|chown)\s+-R\b/i,
];

export default function (pi: ExtensionAPI) {
  pi.on("tool_call", async (event, ctx) => {
    if (event.toolName !== "bash") return;
    const command = String(event.input.command ?? "");
    if (!dangerous.some((pattern) => pattern.test(command))) return;

    if (!ctx.hasUI) {
      return { block: true, reason: "Dangerous command blocked because no confirmation UI is available" };
    }

    const allowed = await ctx.ui.confirm("Allow dangerous command?", command);
    if (!allowed) {
      return { block: true, reason: "Blocked by user" };
    }
  });
}
