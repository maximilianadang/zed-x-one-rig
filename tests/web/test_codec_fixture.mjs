import assert from "node:assert/strict";
import { createRequire } from "node:module";
import { readFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { decodeDepth } from "../../web/depth_worker.js";

const here = path.dirname(fileURLToPath(import.meta.url));
const fixture = process.env.ZED_WEB_FIXTURE ||
  path.resolve(here, "../fixtures/synthetic-v1");
const dracoDirectory = process.env.DRACO3D_DIR;

function jpegDimensions(bytes) {
  assert.equal(bytes[0], 0xff);
  assert.equal(bytes[1], 0xd8);
  let offset = 2;
  while (offset + 9 < bytes.length) {
    while (bytes[offset] === 0xff) offset += 1;
    const marker = bytes[offset++];
    if (marker === 0xd8 || marker === 0xd9) continue;
    const length = (bytes[offset] << 8) | bytes[offset + 1];
    if ([0xc0, 0xc1, 0xc2, 0xc3, 0xc5, 0xc6, 0xc7, 0xc9, 0xca, 0xcb, 0xcd, 0xce, 0xcf].includes(marker)) {
      return {
        height: (bytes[offset + 3] << 8) | bytes[offset + 4],
        width: (bytes[offset + 5] << 8) | bytes[offset + 6],
      };
    }
    offset += length;
  }
  throw new Error("JPEG size marker not found");
}

const rgb = new Uint8Array(await readFile(path.join(fixture, "rgb.jpg")));
const rgbMetadata = JSON.parse(await readFile(path.join(fixture, "rgb.json"), "utf8"));
const rgbSize = jpegDimensions(rgb);
assert.equal(rgb.length, rgbMetadata.bytes);
assert.equal(rgbSize.width, rgbMetadata.width);
assert.equal(rgbSize.height, rgbMetadata.height);

const compressedDepth = await readFile(path.join(fixture, "depth.compressed"));
const depthMetadata = JSON.parse(await readFile(path.join(fixture, "depth.json"), "utf8"));
const depthReference = JSON.parse(
  await readFile(path.join(fixture, "depth-reference.json"), "utf8"),
);
const depthBuffer = compressedDepth.buffer.slice(
  compressedDepth.byteOffset,
  compressedDepth.byteOffset + compressedDepth.byteLength,
);
const decodedDepth = await decodeDepth(depthBuffer, depthMetadata.format);
assert.equal(decodedDepth.width, depthReference.width);
assert.equal(decodedDepth.height, depthReference.height);
assert.equal(decodedDepth.valid, depthReference.valid_pixels);
for (const sample of depthReference.samples) {
  const actual = decodedDepth.depth[sample.row * decodedDepth.width + sample.column];
  if (sample.metres === null) {
    assert.ok(Number.isNaN(actual));
  } else {
    assert.ok(
      Math.abs(actual - sample.metres) <= 0.02,
      `depth[${sample.row},${sample.column}] ${actual} != ${sample.metres}`,
    );
  }
}

if (!dracoDirectory) {
  throw new Error("Set DRACO3D_DIR to the unpacked pinned draco3d package");
}
const require = createRequire(import.meta.url);
const draco3d = require(path.resolve(dracoDirectory, "draco3d.js"));
const draco = await draco3d.createDecoderModule({});
const encodedCloud = await readFile(path.join(fixture, "cloud.drc"));
const cloudReference = JSON.parse(
  await readFile(path.join(fixture, "cloud-reference.json"), "utf8"),
);
const decoderBuffer = new draco.DecoderBuffer();
decoderBuffer.Init(new Int8Array(encodedCloud), encodedCloud.length);
const decoder = new draco.Decoder();
assert.equal(decoder.GetEncodedGeometryType(decoderBuffer), draco.POINT_CLOUD);
const pointCloud = new draco.PointCloud();
const decodeStatus = decoder.DecodeBufferToPointCloud(decoderBuffer, pointCloud);
assert.ok(decodeStatus.ok(), decodeStatus.error_msg());
assert.equal(pointCloud.num_points(), cloudReference.finite_points);

const positionAttributes = [];
let colorAttribute = null;
for (let index = 0; index < pointCloud.num_attributes(); index += 1) {
  const attribute = decoder.GetAttribute(pointCloud, index);
  if (attribute.attribute_type() === draco.POSITION) positionAttributes.push(attribute);
  if (attribute.attribute_type() === draco.COLOR) colorAttribute = attribute;
}
assert.equal(positionAttributes.length, 3);
assert.ok(positionAttributes.every((attribute) => attribute.num_components() === 1));
const positionValues = [];
for (const attribute of positionAttributes) {
  const values = new draco.DracoFloat32Array();
  assert.ok(decoder.GetAttributeFloatForAllPoints(pointCloud, attribute, values));
  positionValues.push(values);
}
const minimum = [Infinity, Infinity, Infinity];
const maximum = [-Infinity, -Infinity, -Infinity];
for (let point = 0; point < pointCloud.num_points(); point += 1) {
  for (let axis = 0; axis < 3; axis += 1) {
    const value = positionValues[axis].GetValue(point);
    minimum[axis] = Math.min(minimum[axis], value);
    maximum[axis] = Math.max(maximum[axis], value);
  }
}
for (let axis = 0; axis < 3; axis += 1) {
  assert.ok(Math.abs(minimum[axis] - cloudReference.bounds_min[axis]) <= 1e-5);
  assert.ok(Math.abs(maximum[axis] - cloudReference.bounds_max[axis]) <= 1e-5);
}
for (const sample of cloudReference.samples.slice(0, 24)) {
  for (let axis = 0; axis < 3; axis += 1) {
    const actual = positionValues[axis].GetValue(sample.index);
    assert.ok(
      Math.abs(actual - sample.xyz[axis]) <= 1e-5,
      `cloud[${sample.index}][${axis}] ${actual} != ${sample.xyz[axis]}`,
    );
  }
}

assert.ok(colorAttribute);
assert.equal(colorAttribute.num_components(), 4);
const colorValues = new draco.DracoUInt8Array();
assert.ok(decoder.GetAttributeUInt8ForAllPoints(pointCloud, colorAttribute, colorValues));
for (const sample of cloudReference.samples.slice(0, 24)) {
  const actual = Array.from(
    { length: 4 },
    (_, component) => colorValues.GetValue(sample.index * 4 + component),
  );
  assert.deepEqual(actual, sample.packed_color_bytes);
}

draco.destroy(colorValues);
for (const values of positionValues) draco.destroy(values);
draco.destroy(pointCloud);
draco.destroy(decoder);
draco.destroy(decoderBuffer);

const memoryBefore = process.memoryUsage().rss;
for (let iteration = 0; iteration < 300; iteration += 1) {
  const repeatedDepth = await decodeDepth(depthBuffer, depthMetadata.format);
  assert.equal(repeatedDepth.valid, depthReference.valid_pixels);

  const repeatedBuffer = new draco.DecoderBuffer();
  repeatedBuffer.Init(new Int8Array(encodedCloud), encodedCloud.length);
  const repeatedDecoder = new draco.Decoder();
  const repeatedCloud = new draco.PointCloud();
  const repeatedStatus = repeatedDecoder.DecodeBufferToPointCloud(
    repeatedBuffer,
    repeatedCloud,
  );
  assert.ok(repeatedStatus.ok(), repeatedStatus.error_msg());
  assert.equal(repeatedCloud.num_points(), cloudReference.finite_points);
  for (let index = 0; index < repeatedCloud.num_attributes(); index += 1) {
    const attribute = repeatedDecoder.GetAttribute(repeatedCloud, index);
    const values = attribute.attribute_type() === draco.COLOR
      ? new draco.DracoUInt8Array()
      : new draco.DracoFloat32Array();
    const decoded = attribute.attribute_type() === draco.COLOR
      ? repeatedDecoder.GetAttributeUInt8ForAllPoints(repeatedCloud, attribute, values)
      : repeatedDecoder.GetAttributeFloatForAllPoints(repeatedCloud, attribute, values);
    assert.ok(decoded);
    draco.destroy(values);
  }
  draco.destroy(repeatedCloud);
  draco.destroy(repeatedDecoder);
  draco.destroy(repeatedBuffer);
  if (iteration % 50 === 49 && global.gc) global.gc();
}
if (global.gc) global.gc();
const memoryGrowth = process.memoryUsage().rss - memoryBefore;
assert.ok(
  memoryGrowth < 96 * 1024 * 1024,
  `fixture decode memory grew by ${(memoryGrowth / 1024 / 1024).toFixed(1)} MiB`,
);

console.log(
  `codec fixture: PASS (${rgbSize.width}x${rgbSize.height}, ` +
  `${decodedDepth.valid} depth pixels, ${cloudReference.finite_points} points; ` +
  `300-cycle RSS delta ${(memoryGrowth / 1024 / 1024).toFixed(1)} MiB)`,
);
