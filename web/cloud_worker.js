import { decodePackedCloud, PACKED_CLOUD_FORMAT } from "./cloud_codec.js";

self.onmessage = (event) => {
  const { id, payload, format, expectedPoints } = event.data;
  try {
    if (format !== PACKED_CLOUD_FORMAT) {
      throw new Error(`unsupported point-cloud format: ${format || "missing"}`);
    }
    const decoded = decodePackedCloud(payload, expectedPoints);
    let nearestRange = Number.POSITIVE_INFINITY;
    let nearestForward = Number.POSITIVE_INFINITY;
    for (let point = 0; point < decoded.count; point += 1) {
      const offset = point * 3;
      const x = decoded.positions[offset];
      const y = decoded.positions[offset + 1];
      const z = decoded.positions[offset + 2];
      nearestRange = Math.min(nearestRange, Math.hypot(x, y, z));
      nearestForward = Math.min(nearestForward, x);
    }
    self.postMessage(
      {
        id,
        count: decoded.count,
        nearestRange,
        nearestForward,
        positions: decoded.positions.buffer,
        colors: decoded.colors.buffer,
      },
      [decoded.positions.buffer, decoded.colors.buffer],
    );
  } catch (error) {
    self.postMessage({ id, error: error instanceof Error ? error.message : String(error) });
  }
};
