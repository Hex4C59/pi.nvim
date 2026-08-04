import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

export default function dialogTimeoutSmoke(pi: ExtensionAPI) {
  pi.registerCommand("smoke-dialog-timeout", {
    description: "Exercise authoritative RPC dialog cancellation",
    handler: async (_args, ctx) => {
      await ctx.ui.input("Smoke timeout", "No response expected", { timeout: 50 });
    },
  });
}
