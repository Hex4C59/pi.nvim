import { PLAN_MODE_GUIDANCE } from "./guidance.mjs";
import { canonicalRoot, canonicalTarget, isWithinCanonicalRoot } from "./paths.mjs";
import { blockToolCall, isReadTool, readPathInput } from "./tool-call.mjs";

export function createWorkspaceGuard(options = {}) {
  const rootCache = new Map();
  return async (event, ctx) => {
    if (!isReadTool(event.toolName)) return undefined;
    try {
      const requested = readPathInput(event);
      if (!requested) return blockToolCall("Blocked because the tool path is missing");
      const root = await canonicalRoot(ctx, options, rootCache);
      const target = await canonicalTarget(requested, ctx.cwd, options);
      if (!isWithinCanonicalRoot(root, target)) {
        return blockToolCall("Blocked because the path is outside the workspace");
      }
      event.input.path = target;
      return undefined;
    } catch (error) {
      return blockToolCall(
        `Blocked because the path could not be verified: ${error instanceof Error ? error.message : String(error)}`,
      );
    }
  };
}

export function workspaceReadOnlyGuidance() {
  return `${PLAN_MODE_GUIDANCE}\n- All reads are restricted to the canonical current workspace.`;
}
