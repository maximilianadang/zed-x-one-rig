export const PACKED_POINT_BYTES = 16;
export const PACKED_CLOUD_FORMAT = "xyzrgb-f32-u8-v1";

export function decodePackedCloud(payload, expectedPoints = null) {
  if (!(payload instanceof ArrayBuffer)) {
    throw new Error("packed cloud payload is not an ArrayBuffer");
  }
  if (payload.byteLength % PACKED_POINT_BYTES !== 0) {
    throw new Error("packed cloud payload has an invalid length");
  }
  const count = payload.byteLength / PACKED_POINT_BYTES;
  if (expectedPoints !== null && Number(expectedPoints) !== count) {
    throw new Error(`packed cloud count mismatch: ${count} != ${expectedPoints}`);
  }

  const view = new DataView(payload);
  const positions = new Float32Array(count * 3);
  const colors = new Uint8Array(count * 3);
  for (let point = 0; point < count; point += 1) {
    const source = point * PACKED_POINT_BYTES;
    const target = point * 3;
    positions[target] = view.getFloat32(source, true);
    positions[target + 1] = view.getFloat32(source + 4, true);
    positions[target + 2] = view.getFloat32(source + 8, true);
    colors[target] = view.getUint8(source + 12);
    colors[target + 1] = view.getUint8(source + 13);
    colors[target + 2] = view.getUint8(source + 14);
  }
  return { count, positions, colors };
}
