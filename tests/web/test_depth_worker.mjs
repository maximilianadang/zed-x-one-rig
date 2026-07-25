import assert from "node:assert/strict";
import { deflateSync } from "node:zlib";
import { decodeDepth } from "../../web/depth_worker.js";

function crc32(bytes) {
  let crc = 0xffffffff;
  for (const byte of bytes) {
    crc ^= byte;
    for (let bit = 0; bit < 8; bit += 1) {
      crc = (crc >>> 1) ^ (0xedb88320 & -(crc & 1));
    }
  }
  return (crc ^ 0xffffffff) >>> 0;
}

function chunk(type, data) {
  const typeBytes = new TextEncoder().encode(type);
  const output = new Uint8Array(12 + data.length);
  const view = new DataView(output.buffer);
  view.setUint32(0, data.length, false);
  output.set(typeBytes, 4);
  output.set(data, 8);
  const checksumInput = new Uint8Array(typeBytes.length + data.length);
  checksumInput.set(typeBytes);
  checksumInput.set(data, typeBytes.length);
  view.setUint32(8 + data.length, crc32(checksumInput), false);
  return output;
}

function concat(parts) {
  const output = new Uint8Array(parts.reduce((sum, part) => sum + part.length, 0));
  let offset = 0;
  for (const part of parts) {
    output.set(part, offset);
    offset += part.length;
  }
  return output;
}

function mono16Png(width, height, values) {
  const ihdr = new Uint8Array(13);
  const header = new DataView(ihdr.buffer);
  header.setUint32(0, width, false);
  header.setUint32(4, height, false);
  ihdr[8] = 16;
  ihdr[9] = 0;
  const scanlines = new Uint8Array(height * (1 + width * 2));
  let input = 0;
  let output = 0;
  for (let row = 0; row < height; row += 1) {
    scanlines[output++] = 0;
    for (let column = 0; column < width; column += 1) {
      const value = values[input++];
      scanlines[output++] = value >> 8;
      scanlines[output++] = value & 0xff;
    }
  }
  return concat([
    Uint8Array.from([137, 80, 78, 71, 13, 10, 26, 10]),
    chunk("IHDR", ihdr),
    chunk("IDAT", deflateSync(scanlines)),
    chunk("IEND", new Uint8Array()),
  ]);
}

const quantA = 10100;
const quantB = -100;
const expected = [Number.NaN, 1, 1.5, 2, 4, 10];
const inverse = expected.map((metres) =>
  Number.isFinite(metres) ? Math.round(quantA / metres + quantB) : 0);
const png = mono16Png(3, 2, inverse);
const payload = new Uint8Array(12 + png.length);
const config = new DataView(payload.buffer);
config.setInt32(0, 0, true);
config.setFloat32(4, quantA, true);
config.setFloat32(8, quantB, true);
payload.set(png, 12);

const decoded = await decodeDepth(
  payload.buffer,
  "32FC1; compressedDepth png",
);
assert.equal(decoded.width, 3);
assert.equal(decoded.height, 2);
assert.equal(decoded.valid, 5);
assert.ok(Number.isNaN(decoded.depth[0]));
for (let index = 1; index < expected.length; index += 1) {
  assert.ok(
    Math.abs(decoded.depth[index] - expected[index]) < 0.002,
    `${decoded.depth[index]} != ${expected[index]}`,
  );
}
assert.equal(decoded.pixels.length, 3 * 2 * 4);
assert.deepEqual(Array.from(decoded.pixels.slice(0, 4)), [0, 0, 0, 255]);
assert.deepEqual(Array.from(decoded.pixels.slice(4, 8)), [0, 0, 0, 255]);
assert.deepEqual(Array.from(decoded.pixels.slice(-4)), [255, 255, 255, 255]);
for (let index = 0; index < decoded.pixels.length; index += 4) {
  assert.equal(decoded.pixels[index], decoded.pixels[index + 1]);
  assert.equal(decoded.pixels[index + 1], decoded.pixels[index + 2]);
}

console.log("compressedDepth metric fixture: PASS");
