const CONFIG_HEADER_BYTES = 12;
const PNG_SIGNATURE = [137, 80, 78, 71, 13, 10, 26, 10];
const MEDIAN_WINDOW = 5;
const minimumHistory = [];
const maximumHistory = [];

function u32be(view, offset) {
  return view.getUint32(offset, false);
}

async function inflateZlib(bytes) {
  if (typeof DecompressionStream !== "function") {
    throw new Error("This browser does not provide DecompressionStream('deflate')");
  }
  const stream = new Blob([bytes]).stream().pipeThrough(new DecompressionStream("deflate"));
  return new Uint8Array(await new Response(stream).arrayBuffer());
}

function paeth(a, b, c) {
  const prediction = a + b - c;
  const pa = Math.abs(prediction - a);
  const pb = Math.abs(prediction - b);
  const pc = Math.abs(prediction - c);
  if (pa <= pb && pa <= pc) return a;
  if (pb <= pc) return b;
  return c;
}

async function decodeMono16Png(bytes) {
  if (bytes.length < 33 || !PNG_SIGNATURE.every((value, index) => bytes[index] === value)) {
    throw new Error("compressedDepth payload does not contain a PNG");
  }
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  let offset = 8;
  let width = 0;
  let height = 0;
  const chunks = [];
  while (offset + 12 <= bytes.length) {
    const length = u32be(view, offset);
    const type = String.fromCharCode(
      bytes[offset + 4], bytes[offset + 5], bytes[offset + 6], bytes[offset + 7],
    );
    const start = offset + 8;
    const end = start + length;
    if (end + 4 > bytes.length) throw new Error("truncated PNG chunk");
    if (type === "IHDR") {
      width = u32be(view, start);
      height = u32be(view, start + 4);
      const bitDepth = bytes[start + 8];
      const colorType = bytes[start + 9];
      const compression = bytes[start + 10];
      const filter = bytes[start + 11];
      const interlace = bytes[start + 12];
      if (bitDepth !== 16 || colorType !== 0 || compression !== 0 || filter !== 0 || interlace !== 0) {
        throw new Error(
          `unsupported depth PNG: bit=${bitDepth} color=${colorType} interlace=${interlace}`,
        );
      }
    } else if (type === "IDAT") {
      chunks.push(bytes.slice(start, end));
    } else if (type === "IEND") {
      break;
    }
    offset = end + 4;
  }
  if (!width || !height || !chunks.length) throw new Error("incomplete depth PNG");
  const compressedLength = chunks.reduce((sum, chunk) => sum + chunk.length, 0);
  const compressed = new Uint8Array(compressedLength);
  let position = 0;
  for (const chunk of chunks) {
    compressed.set(chunk, position);
    position += chunk.length;
  }
  const filtered = await inflateZlib(compressed);
  const stride = width * 2;
  if (filtered.length !== height * (stride + 1)) {
    throw new Error(`unexpected PNG scanline length ${filtered.length}`);
  }
  const raw = new Uint8Array(width * height * 2);
  let source = 0;
  for (let row = 0; row < height; row += 1) {
    const filterType = filtered[source++];
    const rowOffset = row * stride;
    const priorOffset = rowOffset - stride;
    for (let column = 0; column < stride; column += 1) {
      const encoded = filtered[source++];
      const left = column >= 2 ? raw[rowOffset + column - 2] : 0;
      const above = row > 0 ? raw[priorOffset + column] : 0;
      const upperLeft = row > 0 && column >= 2 ? raw[priorOffset + column - 2] : 0;
      let value;
      if (filterType === 0) value = encoded;
      else if (filterType === 1) value = encoded + left;
      else if (filterType === 2) value = encoded + above;
      else if (filterType === 3) value = encoded + Math.floor((left + above) / 2);
      else if (filterType === 4) value = encoded + paeth(left, above, upperLeft);
      else throw new Error(`unsupported PNG filter ${filterType}`);
      raw[rowOffset + column] = value & 0xff;
    }
  }
  const inverseDepth = new Uint16Array(width * height);
  for (let index = 0; index < inverseDepth.length; index += 1) {
    inverseDepth[index] = (raw[index * 2] << 8) | raw[index * 2 + 1];
  }
  return { width, height, inverseDepth };
}

function medianWithHistory(history, value) {
  history.unshift(value);
  if (history.length > MEDIAN_WINDOW) history.pop();
  const sorted = [...history].sort((a, b) => a - b);
  return sorted[Math.floor(sorted.length / 2)];
}

async function decodeDepth(payload, format) {
  if (payload.byteLength <= CONFIG_HEADER_BYTES) throw new Error("short compressedDepth payload");
  const header = new DataView(payload, 0, CONFIG_HEADER_BYTES);
  const compressionFormat = header.getInt32(0, true);
  const quantA = header.getFloat32(4, true);
  const quantB = header.getFloat32(8, true);
  const png = new Uint8Array(payload, CONFIG_HEADER_BYTES);
  const { width, height, inverseDepth } = await decodeMono16Png(png);
  const isFloat = String(format).toUpperCase().startsWith("32FC1");
  const depth = new Float32Array(width * height);
  let frameLow = Number.MAX_VALUE;
  let frameHigh = Number.MIN_VALUE;
  let valid = 0;
  for (let index = 0; index < inverseDepth.length; index += 1) {
    const raw = inverseDepth[index];
    let metres = Number.NaN;
    if (raw !== 0) {
      metres = isFloat ? quantA / (raw - quantB) : raw / 1000;
    }
    if (Number.isFinite(metres) && metres > 0 && metres <= 1000) {
      depth[index] = metres;
      valid += 1;
      frameLow = Math.min(frameLow, metres);
      frameHigh = Math.max(frameHigh, metres);
    } else {
      depth[index] = Number.NaN;
    }
  }
  let low = valid ? medianWithHistory(minimumHistory, frameLow) : Number.NaN;
  let high = valid ? medianWithHistory(maximumHistory, frameHigh) : Number.NaN;
  if (!Number.isFinite(low) || !Number.isFinite(high) || high <= low) {
    low = 0;
    high = 10;
  }
  const pixels = new Uint8ClampedArray(width * height * 4);
  for (let index = 0; index < depth.length; index += 1) {
    const value = depth[index];
    const target = index * 4;
    if (!Number.isFinite(value)) {
      pixels[target] = 0;
      pixels[target + 1] = 0;
      pixels[target + 2] = 0;
      pixels[target + 3] = 255;
      continue;
    }
    // Match RViz ImageDisplay's PF_BYTE_L path: per-frame float min/max,
    // stabilized by its five-frame median window, then linear 8-bit grayscale.
    const normalized = Math.max(0, Math.min(1, (value - low) / (high - low)));
    const intensity = Math.floor(normalized * 255);
    pixels[target] = intensity;
    pixels[target + 1] = intensity;
    pixels[target + 2] = intensity;
    pixels[target + 3] = 255;
  }
  return {
    width,
    height,
    pixels,
    low,
    high,
    quantA,
    quantB,
    compressionFormat,
    valid,
    depth,
  };
}

if (typeof self !== "undefined") {
  self.onmessage = async (event) => {
    const { id, payload, format } = event.data;
    try {
      const decoded = await decodeDepth(payload, format);
      self.postMessage(
        {
          id,
          width: decoded.width,
          height: decoded.height,
          pixels: decoded.pixels.buffer,
          low: decoded.low,
          high: decoded.high,
          valid: decoded.valid,
          quantA: decoded.quantA,
          quantB: decoded.quantB,
          compressionFormat: decoded.compressionFormat,
        },
        [decoded.pixels.buffer],
      );
    } catch (error) {
      self.postMessage({ id, error: error instanceof Error ? error.message : String(error) });
    }
  };
}

export { decodeDepth, decodeMono16Png };
