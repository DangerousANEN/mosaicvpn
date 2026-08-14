const fs = require('fs');
const {setTimeout: delay} = require('timers/promises');

const state = process.argv[2];
const outputPath = process.argv[3];
if (!['connected', 'route-picker'].includes(state) || !outputPath) {
  throw new Error('Usage: node capture_dashboard_state.js <connected|route-picker> <output.png>');
}

async function requestJson(url) {
  const response = await fetch(url);
  if (!response.ok) throw new Error(`DevTools request failed: ${response.status}`);
  return response.json();
}

async function connect() {
  const targets = await requestJson('http://127.0.0.1:9222/json/list');
  const target = targets.find((item) => item.type === 'page');
  if (!target) throw new Error('No page target available in headless Chromium');

  const socket = new WebSocket(target.webSocketDebuggerUrl);
  await new Promise((resolve, reject) => {
    socket.addEventListener('open', resolve, {once: true});
    socket.addEventListener('error', reject, {once: true});
  });

  let nextId = 0;
  const pending = new Map();
  socket.addEventListener('message', ({data}) => {
    const message = JSON.parse(data);
    if (message.id && pending.has(message.id)) {
      const {resolve, reject} = pending.get(message.id);
      pending.delete(message.id);
      if (message.error) reject(new Error(message.error.message));
      else resolve(message.result);
    }
  });

  const call = (method, params = {}) => new Promise((resolve, reject) => {
    const id = ++nextId;
    pending.set(id, {resolve, reject});
    socket.send(JSON.stringify({id, method, params}));
  });

  return {socket, call};
}

async function click(call, x, y) {
  await call('Input.dispatchMouseEvent', {type: 'mousePressed', x, y, button: 'left', clickCount: 1});
  await call('Input.dispatchMouseEvent', {type: 'mouseReleased', x, y, button: 'left', clickCount: 1});
}

(async () => {
  const {socket, call} = await connect();
  try {
    await call('Page.enable');
    await call('Emulation.setDeviceMetricsOverride', {
      width: 390,
      height: 844,
      deviceScaleFactor: 1,
      mobile: false,
    });
    await call('Page.navigate', {url: 'http://127.0.0.1:4173/'});
    await delay(8000);

    if (state === 'connected') {
      await click(call, 195, 548);
      await delay(2500);
    } else {
      await click(call, 195, 473);
      await delay(700);
    }

    const {data} = await call('Page.captureScreenshot', {format: 'png', fromSurface: true});
    fs.mkdirSync(require('path').dirname(outputPath), {recursive: true});
    fs.writeFileSync(outputPath, Buffer.from(data, 'base64'));
  } finally {
    socket.close();
  }
})().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
