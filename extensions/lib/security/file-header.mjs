import { open } from "node:fs/promises";

export const DEFAULT_HEADER_BYTES = 64 * 1024;

export async function readFirstLine(file, maximum = DEFAULT_HEADER_BYTES) {
  const handle = await open(file, "r");
  try {
    const buffer = Buffer.alloc(maximum + 1);
    const { bytesRead } = await handle.read(buffer, 0, buffer.length, 0);
    const newline = buffer.subarray(0, bytesRead).indexOf(0x0a);
    if (newline < 0 && bytesRead > maximum) throw new Error("session header is too large");
    if (newline < 0) throw new Error("session header must end with a newline");
    return buffer.subarray(0, newline).toString("utf8");
  } finally {
    await handle.close();
  }
}
