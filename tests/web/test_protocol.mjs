import assert from "node:assert/strict";
import { HEADER_BYTES, parseEnvelope, STREAM_IDS } from "../../web/protocol.js";

const encoder = new TextEncoder();
const metadata = encoder.encode('{"frame_id":"zed_camera_link","format":"jpeg"}');
const payload = Uint8Array.from([0xff, 0xd8, 0xff, 0xd9]);
const bytes = new Uint8Array(HEADER_BYTES + metadata.length + payload.length);
bytes.set(encoder.encode("ZXR1"), 0);
const view = new DataView(bytes.buffer);
view.setUint16(4, 1, true);
view.setUint8(6, STREAM_IDS.rgb);
view.setUint32(8, 42, true);
view.setInt32(12, 1234, true);
view.setUint32(16, 5678, true);
view.setUint32(20, metadata.length, true);
view.setUint32(24, payload.length, true);
bytes.set(metadata, HEADER_BYTES);
bytes.set(payload, HEADER_BYTES + metadata.length);

const decoded = parseEnvelope(bytes.buffer, STREAM_IDS.rgb);
assert.equal(decoded.sequence, 42);
assert.equal(decoded.stampSec, 1234);
assert.equal(decoded.stampNsec, 5678);
assert.equal(decoded.metadata.frame_id, "zed_camera_link");
assert.deepEqual([...new Uint8Array(decoded.payload)], [...payload]);

const badVersion = bytes.slice();
new DataView(badVersion.buffer).setUint16(4, 2, true);
assert.throws(() => parseEnvelope(badVersion.buffer, STREAM_IDS.rgb), /unsupported/);
assert.throws(() => parseEnvelope(bytes.buffer.slice(0, -1), STREAM_IDS.rgb), /length/);
assert.throws(() => parseEnvelope(bytes.buffer, STREAM_IDS.depth), /unsupported/);

console.log("protocol fixture: PASS");
