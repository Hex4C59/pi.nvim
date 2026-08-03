import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { createSessionRootGuard } from "./lib/security-policy.mjs";

export default function (pi: ExtensionAPI) {
  pi.on("session_before_switch", createSessionRootGuard());
}
