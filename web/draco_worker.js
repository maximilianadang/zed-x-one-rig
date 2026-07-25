/* global DracoDecoderModule */

importScripts("/vendor/draco/draco_wasm_wrapper.js");

const modulePromise = new Promise((resolve, reject) => {
  try {
    const configuration = {
      locateFile: (filename) => `/vendor/draco/${filename}`,
      onModuleLoaded: resolve,
    };
    const result = DracoDecoderModule(configuration);
    if (result && typeof result.then === "function") result.then(resolve, reject);
  } catch (error) {
    reject(error);
  }
});

function destroyAll(draco, objects) {
  for (const object of objects.reverse()) {
    if (object) draco.destroy(object);
  }
}

async function decodeCloud(payload) {
  const draco = await modulePromise;
  const allocated = [];
  try {
    const decoderBuffer = new draco.DecoderBuffer();
    allocated.push(decoderBuffer);
    decoderBuffer.Init(new Int8Array(payload), payload.byteLength);
    const decoder = new draco.Decoder();
    allocated.push(decoder);
    if (decoder.GetEncodedGeometryType(decoderBuffer) !== draco.POINT_CLOUD) {
      throw new Error("Draco payload is not a point cloud");
    }
    const pointCloud = new draco.PointCloud();
    allocated.push(pointCloud);
    const status = decoder.DecodeBufferToPointCloud(decoderBuffer, pointCloud);
    if (!status.ok()) throw new Error(status.error_msg());

    const count = pointCloud.num_points();
    const positionAttributes = [];
    let colorAttribute = null;
    for (let index = 0; index < pointCloud.num_attributes(); index += 1) {
      const attribute = decoder.GetAttribute(pointCloud, index);
      if (attribute.attribute_type() === draco.POSITION) positionAttributes.push(attribute);
      if (attribute.attribute_type() === draco.COLOR && colorAttribute === null) {
        colorAttribute = attribute;
      }
    }
    const positions = new Float32Array(count * 3);
    if (positionAttributes.length === 1 && positionAttributes[0].num_components() === 3) {
      const values = new draco.DracoFloat32Array();
      allocated.push(values);
      if (!decoder.GetAttributeFloatForAllPoints(pointCloud, positionAttributes[0], values)) {
        throw new Error("could not decode Draco position attribute");
      }
      for (let index = 0; index < positions.length; index += 1) {
        positions[index] = values.GetValue(index);
      }
    } else if (
      positionAttributes.length >= 3 &&
      positionAttributes.slice(0, 3).every((attribute) => attribute.num_components() === 1)
    ) {
      // point_cloud_transport encodes PointCloud2 x/y/z as three scalar
      // POSITION attributes, in original field order.
      for (let axis = 0; axis < 3; axis += 1) {
        const values = new draco.DracoFloat32Array();
        allocated.push(values);
        if (!decoder.GetAttributeFloatForAllPoints(pointCloud, positionAttributes[axis], values)) {
          throw new Error(`could not decode Draco position axis ${axis}`);
        }
        for (let point = 0; point < count; point += 1) {
          positions[point * 3 + axis] = values.GetValue(point);
        }
      }
    } else {
      throw new Error(
        `unsupported Draco position layout: ${positionAttributes.length} attributes`,
      );
    }

    let colors = null;
    if (colorAttribute) {
      const components = colorAttribute.num_components();
      const values = new draco.DracoUInt8Array();
      allocated.push(values);
      if (!decoder.GetAttributeUInt8ForAllPoints(pointCloud, colorAttribute, values)) {
        throw new Error("could not decode Draco color attribute");
      }
      colors = new Uint8Array(count * 3);
      for (let point = 0; point < count; point += 1) {
        const source = point * components;
        const target = point * 3;
        if (components >= 3) {
          // ROS/PCL packed rgb is 0xAARRGGBB. Its little-endian PointCloud2
          // bytes, which the transport preserves, are B,G,R,A.
          colors[target] = values.GetValue(source + 2);
          colors[target + 1] = values.GetValue(source + 1);
          colors[target + 2] = values.GetValue(source);
        }
      }
    }
    return { count, positions, colors };
  } finally {
    destroyAll(draco, allocated);
  }
}

self.onmessage = async (event) => {
  const { id, payload } = event.data;
  try {
    const decoded = await decodeCloud(payload);
    const transfer = [decoded.positions.buffer];
    if (decoded.colors) transfer.push(decoded.colors.buffer);
    self.postMessage(
      {
        id,
        count: decoded.count,
        positions: decoded.positions.buffer,
        colors: decoded.colors?.buffer || null,
      },
      transfer,
    );
  } catch (error) {
    self.postMessage({ id, error: error instanceof Error ? error.message : String(error) });
  }
};
