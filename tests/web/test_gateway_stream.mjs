import assert from "node:assert/strict";
import { createRequire } from "node:module";
import path from "node:path";
import { parseEnvelope, STREAM_IDS } from "../../web/protocol.js";
import { decodeDepth } from "../../web/depth_worker.js";

const port = Number(process.env.ZED_WEB_TEST_PORT || 8876);
const token = process.env.ZED_WEB_TEST_TOKEN;
const dracoDirectory = process.env.DRACO3D_DIR;
if (!token || !dracoDirectory) {
  throw new Error("ZED_WEB_TEST_TOKEN and DRACO3D_DIR are required");
}

const base = `http://127.0.0.1:${port}`;
const controller = "00112233445566778899aabbccddeeff";
const headers = {
  "X-ZED-Token": token,
  "X-ZED-Controller": controller,
};

async function receiveOne(name, streamId) {
  return new Promise((resolve, reject) => {
    const timeout = setTimeout(() => reject(new Error(`${name} stream timeout`)), 30000);
    const socket = new WebSocket(
      `ws://127.0.0.1:${port}/api/v1/stream/${name}?v=1&token=${token}`,
    );
    socket.binaryType = "arraybuffer";
    socket.onerror = () => reject(new Error(`${name} WebSocket error`));
    socket.onmessage = (event) => {
      clearTimeout(timeout);
      try {
        resolve(parseEnvelope(event.data, streamId));
      } catch (error) {
        reject(error);
      } finally {
        socket.close();
      }
    };
  });
}

const unauthorized = await fetch(`${base}/api/v1/status?mode=replay`);
assert.equal(unauthorized.status, 401);
const wrongOrigin = await fetch(`${base}/api/v1/status?mode=replay`, {
  headers: { ...headers, Origin: "https://example.invalid" },
});
assert.equal(wrongOrigin.status, 401);
const lease = await fetch(`${base}/api/v1/lease`, { method: "POST", headers });
assert.ok(lease.ok, await lease.text());
const competingLease = await fetch(`${base}/api/v1/lease`, {
  method: "POST",
  headers: {
    "X-ZED-Token": token,
    "X-ZED-Controller": "ffeeddccbbaa99887766554433221100",
  },
});
assert.equal(competingLease.status, 423);

const rgbPromise = receiveOne("rgb", STREAM_IDS.rgb);
const depthPromise = receiveOne("depth", STREAM_IDS.depth);
const cloudPromise = receiveOne("cloud", STREAM_IDS.cloud);
await new Promise((resolve) => setTimeout(resolve, 1000));
const play = await fetch(`${base}/api/v1/replay/toggle`, { method: "POST", headers });
assert.ok(play.ok, await play.text());

const [rgb, depth, cloud] = await Promise.all([rgbPromise, depthPromise, cloudPromise]);
assert.ok(rgb.payload.byteLength > 1000);
assert.match(rgb.metadata.format, /jpeg/i);
assert.match(depth.metadata.format, /32FC1/);
assert.equal(cloud.metadata.format, "draco");
assert.equal(cloud.metadata.fixed_frame, "zed_camera_link");
assert.deepEqual(cloud.metadata.fixed_translation, [0, 0, 0.0155]);
assert.equal(rgb.stampSec, depth.stampSec);
assert.equal(rgb.stampNsec, depth.stampNsec);

const decodedDepth = await decodeDepth(depth.payload, depth.metadata.format);
assert.equal(decodedDepth.width, 960);
assert.equal(decodedDepth.height, 600);
assert.ok(decodedDepth.valid > 1000);

const require = createRequire(import.meta.url);
const draco3d = require(path.resolve(dracoDirectory, "draco3d.js"));
const draco = await draco3d.createDecoderModule({});
const decoderBuffer = new draco.DecoderBuffer();
decoderBuffer.Init(new Int8Array(cloud.payload), cloud.payload.byteLength);
const decoder = new draco.Decoder();
const pointCloud = new draco.PointCloud();
const result = decoder.DecodeBufferToPointCloud(decoderBuffer, pointCloud);
assert.ok(result.ok(), result.error_msg());
assert.ok(pointCloud.num_points() > 100);
assert.equal(pointCloud.num_attributes(), 4);
draco.destroy(pointCloud);
draco.destroy(decoder);
draco.destroy(decoderBuffer);

await fetch(`${base}/api/v1/replay/toggle`, { method: "POST", headers });
await fetch(`${base}/api/v1/lease/release`, { method: "POST", headers });
console.log(
  `gateway replay stream: PASS (${decodedDepth.width}x${decodedDepth.height}, ` +
  `${decodedDepth.valid} depth pixels, ${cloud.payload.byteLength} Draco bytes)`,
);
