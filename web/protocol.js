export const PROTOCOL_VERSION = 1;
export const HEADER_BYTES = 32;
export const STREAM_IDS = Object.freeze({ rgb: 1, depth: 2, cloud: 3 });

export function parseEnvelope(arrayBuffer, expectedStream) {
  if (!(arrayBuffer instanceof ArrayBuffer) || arrayBuffer.byteLength < HEADER_BYTES) {
    throw new Error("short gateway frame");
  }
  const bytes = new Uint8Array(arrayBuffer);
  if (String.fromCharCode(...bytes.slice(0, 4)) !== "ZXR1") {
    throw new Error("bad gateway magic");
  }
  const view = new DataView(arrayBuffer);
  const version = view.getUint16(4, true);
  const stream = view.getUint8(6);
  const flags = view.getUint8(7);
  const sequence = view.getUint32(8, true);
  const stampSec = view.getInt32(12, true);
  const stampNsec = view.getUint32(16, true);
  const metadataBytes = view.getUint32(20, true);
  const payloadBytes = view.getUint32(24, true);
  const reserved = view.getUint32(28, true);
  if (version !== PROTOCOL_VERSION || stream !== expectedStream || flags !== 0 || reserved !== 0) {
    throw new Error(`unsupported gateway header v=${version} stream=${stream}`);
  }
  if (HEADER_BYTES + metadataBytes + payloadBytes !== arrayBuffer.byteLength) {
    throw new Error("gateway frame length mismatch");
  }
  const metadataText = new TextDecoder().decode(
    bytes.slice(HEADER_BYTES, HEADER_BYTES + metadataBytes),
  );
  const metadata = JSON.parse(metadataText);
  const payload = arrayBuffer.slice(HEADER_BYTES + metadataBytes);
  return { sequence, stampSec, stampNsec, metadata, payload };
}
