import assert from "node:assert/strict";
import { decodePackedCloud, PACKED_POINT_BYTES } from "../../web/cloud_codec.js";

const payload = new ArrayBuffer(PACKED_POINT_BYTES * 2);
const view = new DataView(payload);
const samples = [
  { xyz: [1.25, -2.5, 3.75], rgb: [17, 34, 51] },
  { xyz: [-4.5, 5.25, 6.0], rgb: [200, 150, 100] },
];
for (let point = 0; point < samples.length; point += 1) {
  const offset = point * PACKED_POINT_BYTES;
  for (let axis = 0; axis < 3; axis += 1) {
    view.setFloat32(offset + axis * 4, samples[point].xyz[axis], true);
  }
  for (let channel = 0; channel < 3; channel += 1) {
    view.setUint8(offset + 12 + channel, samples[point].rgb[channel]);
  }
  view.setUint8(offset + 15, 255);
}

const decoded = decodePackedCloud(payload, 2);
assert.equal(decoded.count, 2);
assert.deepEqual(Array.from(decoded.positions), samples.flatMap((sample) => sample.xyz));
assert.deepEqual(Array.from(decoded.colors), samples.flatMap((sample) => sample.rgb));
assert.throws(() => decodePackedCloud(new ArrayBuffer(15)), /invalid length/);
assert.throws(() => decodePackedCloud(new ArrayBuffer(16), 2), /count mismatch/);

console.log("packed cloud codec: PASS");
