# Peon Avatar Desktop App Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build an Electron desktop app that renders the Warcraft Peon character as an always-on-top transparent corner widget using Three.js, reacting visually with sprite animations and WebGL shader effects when peon-ping events fire.

**Architecture:** Electron main process polls `~/.claude/hooks/peon-ping/.state.json` every 200ms, detects new events by comparing `last_active.timestamp`, maps the raw hook event name to a CESP category, and sends it to the renderer via IPC. The renderer runs a Three.js WebGL scene on a transparent canvas with a sprite atlas animation state machine and shader effects.

**Tech Stack:** Electron 33+, Three.js r168+, Node.js canvas (for placeholder art generation), no bundler (plain ES modules via Electron's renderer)

---

## Key Context

**State file location:** `~/.claude/hooks/peon-ping/.state.json`

**State file `last_active` shape:**
```json
{
  "last_active": {
    "session_id": "abc123",
    "pack": "peon",
    "timestamp": 1234567890.123,
    "event": "Stop"
  }
}
```

**Raw event → CESP category mapping (from peon.sh):**
| Raw event | CESP category | Avatar animation |
|---|---|---|
| `SessionStart` | `session.start` | wave |
| `Stop` | `task.complete` | celebrate |
| `PermissionRequest` | `input.required` | alarmed |
| `PostToolUseFailure` | `task.error` | facepalm |
| `UserPromptSubmit` (repeated) | `user.spam` | annoyed |
| `PreCompact` | `resource.limit` | alarmed |
| (no event / default) | `idle` | idle |

**Sprite atlas layout (6 rows × 6 frames, each frame 64×64px → total 384×384px):**
```
Row 0: idle      (breathing bob, loops forever)
Row 1: celebrate (jump + arms up, plays once then returns to idle)
Row 2: alarmed   (wave arms, plays once then returns to idle)
Row 3: facepalm  (slump, plays once then returns to idle)
Row 4: wave      (friendly wave, plays once then returns to idle)
Row 5: annoyed   (arms crossed, shake head, plays once then returns to idle)
```

---

## Task 1: Initialize the project

**Files:**
- Create: `peonping-repos/peon-ping-avatar/package.json`
- Create: `peonping-repos/peon-ping-avatar/.gitignore`

**Step 1: Create the directory**

```bash
mkdir /Users/garysheng/Documents/github-repos/peonping-repos/peon-ping-avatar
cd /Users/garysheng/Documents/github-repos/peonping-repos/peon-ping-avatar
```

**Step 2: Initialize npm**

```bash
npm init -y
```

**Step 3: Install dependencies**

```bash
npm install --save-dev electron@latest
npm install three
npm install canvas  # for generating placeholder sprite atlas
```

**Step 4: Edit `package.json` to look like this:**

```json
{
  "name": "peon-ping-avatar",
  "version": "0.1.0",
  "description": "Always-on-top Peon avatar that reacts to peon-ping events",
  "main": "main.js",
  "scripts": {
    "start": "electron .",
    "dev": "electron . --dev"
  },
  "dependencies": {
    "three": "^0.168.0",
    "canvas": "^2.11.2"
  },
  "devDependencies": {
    "electron": "^33.0.0"
  }
}
```

**Step 5: Create `.gitignore`**

```
node_modules/
dist/
*.log
```

**Step 6: Create directory structure**

```bash
mkdir -p renderer/assets renderer/shaders
touch main.js preload.js renderer/index.html renderer/app.js
touch renderer/shaders/flash.vert renderer/shaders/flash.frag
touch scripts/gen-placeholder-atlas.js
```

**Step 7: Initialize git and commit**

```bash
git init
git add .
git commit -m "chore: initialize peon-ping-avatar project"
```

---

## Task 2: Generate placeholder sprite atlas

**Files:**
- Create: `scripts/gen-placeholder-atlas.js`
- Output: `renderer/assets/peon-atlas.png`

**Purpose:** Before real pixel art exists, this script generates a colored-rectangle atlas so we can build and test the entire app visually.

**Step 1: Write `scripts/gen-placeholder-atlas.js`**

```js
// Generates a placeholder peon-atlas.png for development.
// 6 rows (animations) × 6 frames × 64×64px per frame = 384×384px total.
// Replace renderer/assets/peon-atlas.png with real pixel art when ready.

const { createCanvas } = require('canvas');
const fs = require('fs');
const path = require('path');

const FRAME_SIZE = 64;
const COLS = 6;
const ROWS = 6;

const ROW_COLORS = [
  '#4a7c4e', // idle      - green
  '#f0c040', // celebrate - gold
  '#e05050', // alarmed   - red
  '#8855cc', // facepalm  - purple
  '#40a0e0', // wave      - blue
  '#e08030', // annoyed   - orange
];

const ROW_LABELS = [
  'idle', 'celebrate', 'alarmed', 'facepalm', 'wave', 'annoyed'
];

const canvas = createCanvas(FRAME_SIZE * COLS, FRAME_SIZE * ROWS);
const ctx = canvas.getContext('2d');

for (let row = 0; row < ROWS; row++) {
  for (let col = 0; col < COLS; col++) {
    const x = col * FRAME_SIZE;
    const y = row * FRAME_SIZE;

    // Background
    ctx.fillStyle = ROW_COLORS[row];
    ctx.fillRect(x + 2, y + 2, FRAME_SIZE - 4, FRAME_SIZE - 4);

    // Frame number indicator (brightness varies per frame to show animation)
    const brightness = 0.5 + (col / COLS) * 0.5;
    ctx.globalAlpha = brightness;
    ctx.fillStyle = '#ffffff';
    ctx.fillRect(x + 8, y + 8, FRAME_SIZE - 16, FRAME_SIZE - 16);
    ctx.globalAlpha = 1;

    // Draw a simple peon silhouette (head + body rectangle)
    ctx.fillStyle = '#2a1810';
    // Head
    ctx.fillRect(x + 22, y + 10, 20, 16);
    // Body
    ctx.fillRect(x + 18, y + 26, 28, 20);
    // Legs (shift per frame for walk cycle illusion)
    const legShift = (col % 2 === 0) ? 0 : 4;
    ctx.fillRect(x + 20, y + 46, 8, 12 - legShift);
    ctx.fillRect(x + 36, y + 46, 8, 12 + legShift);

    // Label
    ctx.fillStyle = '#000000';
    ctx.font = '8px monospace';
    ctx.fillText(ROW_LABELS[row][0] + col, x + 4, y + FRAME_SIZE - 4);
  }
}

const outPath = path.join(__dirname, '../renderer/assets/peon-atlas.png');
const buffer = canvas.toBuffer('image/png');
fs.writeFileSync(outPath, buffer);
console.log(`Generated ${outPath} (${FRAME_SIZE * COLS}x${FRAME_SIZE * ROWS}px)`);
```

**Step 2: Run it**

```bash
node scripts/gen-placeholder-atlas.js
```

Expected output: `Generated .../renderer/assets/peon-atlas.png (384x384px)`

Verify the file exists: `ls -lh renderer/assets/peon-atlas.png`

**Step 3: Commit**

```bash
git add scripts/gen-placeholder-atlas.js renderer/assets/peon-atlas.png
git commit -m "feat: add placeholder sprite atlas generator"
```

---

## Task 3: Electron main process — transparent window

**Files:**
- Create: `main.js`

**Step 1: Write `main.js` (window creation only, no polling yet)**

```js
const { app, BrowserWindow, ipcMain, screen } = require('electron');
const path = require('path');

let win;

function createWindow() {
  const { width, height } = screen.getPrimaryDisplay().workAreaSize;

  win = new BrowserWindow({
    width: 200,
    height: 200,
    // Position bottom-right corner with 20px margin
    x: width - 220,
    y: height - 220,
    transparent: true,
    frame: false,
    alwaysOnTop: true,
    skipTaskbar: true,
    resizable: false,
    focusable: false,
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false,
    },
  });

  // Pass clicks through to apps below
  win.setIgnoreMouseEvents(true);

  // Hide from macOS dock
  if (process.platform === 'darwin') {
    app.dock.hide();
  }

  win.loadFile('renderer/index.html');

  // Open DevTools only in dev mode (run with: electron . --dev)
  if (process.argv.includes('--dev')) {
    win.webContents.openDevTools({ mode: 'detach' });
  }
}

app.whenReady().then(createWindow);

app.on('window-all-closed', () => {
  app.quit();
});
```

**Step 2: Create minimal `preload.js`**

```js
const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('peonBridge', {
  onEvent: (callback) => ipcRenderer.on('peon-event', (_e, data) => callback(data)),
});
```

**Step 3: Create minimal `renderer/index.html`**

```html
<!DOCTYPE html>
<html>
<head>
  <meta charset="UTF-8">
  <style>
    * { margin: 0; padding: 0; }
    html, body { width: 200px; height: 200px; overflow: hidden; background: transparent; }
    canvas { display: block; }
  </style>
</head>
<body>
  <canvas id="c"></canvas>
  <script type="module" src="app.js"></script>
</body>
</html>
```

**Step 4: Create stub `renderer/app.js`**

```js
// Stub — just proves the window loads
const canvas = document.getElementById('c');
canvas.width = 200;
canvas.height = 200;
const ctx = canvas.getContext('2d');
ctx.fillStyle = 'rgba(255,0,0,0.3)';
ctx.fillRect(0, 0, 200, 200);
ctx.fillStyle = 'white';
ctx.font = '14px sans-serif';
ctx.fillText('peon loading...', 10, 100);
```

**Step 5: Run and verify the window appears**

```bash
npm start
```

Expected: A small semi-transparent red rectangle appears in the bottom-right corner of your screen with "peon loading..." text. It should float over all other windows.

**Step 6: Quit with Ctrl+C and commit**

```bash
git add main.js preload.js renderer/index.html renderer/app.js
git commit -m "feat: add transparent always-on-top Electron window"
```

---

## Task 4: State file polling and IPC

**Files:**
- Modify: `main.js` (add polling logic)

**Step 1: Add the polling code to `main.js`**

Replace the contents of `main.js` with:

```js
const { app, BrowserWindow, ipcMain, screen } = require('electron');
const path = require('path');
const fs = require('fs');
const os = require('os');

let win;

// Path to peon-ping state file
const STATE_FILE = path.join(os.homedir(), '.claude', 'hooks', 'peon-ping', '.state.json');

// Map raw hook event names to avatar animation states
const EVENT_TO_ANIM = {
  SessionStart:        'wave',
  Stop:                'celebrate',
  PermissionRequest:   'alarmed',
  PostToolUseFailure:  'facepalm',
  UserPromptSubmit:    'annoyed',   // only fires when spam threshold hit
  PreCompact:          'alarmed',
};

let lastTimestamp = 0;

function readStateFile() {
  try {
    const raw = fs.readFileSync(STATE_FILE, 'utf8');
    return JSON.parse(raw);
  } catch {
    return null;
  }
}

function startPolling() {
  setInterval(() => {
    const state = readStateFile();
    if (!state || !state.last_active) return;

    const { timestamp, event } = state.last_active;
    if (timestamp === lastTimestamp) return;
    lastTimestamp = timestamp;

    const anim = EVENT_TO_ANIM[event];
    if (!anim) return;  // Unknown or suppressed event

    if (win && !win.isDestroyed()) {
      win.webContents.send('peon-event', { anim, event });
    }
  }, 200);
}

function createWindow() {
  const { width, height } = screen.getPrimaryDisplay().workAreaSize;

  win = new BrowserWindow({
    width: 200,
    height: 200,
    x: width - 220,
    y: height - 220,
    transparent: true,
    frame: false,
    alwaysOnTop: true,
    skipTaskbar: true,
    resizable: false,
    focusable: false,
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false,
    },
  });

  win.setIgnoreMouseEvents(true);

  if (process.platform === 'darwin') {
    app.dock.hide();
  }

  win.loadFile('renderer/index.html');

  if (process.argv.includes('--dev')) {
    win.webContents.openDevTools({ mode: 'detach' });
  }

  // Start polling once window is ready
  win.webContents.once('did-finish-load', startPolling);
}

app.whenReady().then(createWindow);
app.on('window-all-closed', () => app.quit());
```

**Step 2: Test the polling manually**

Run the app in dev mode:

```bash
npm run dev
```

In a second terminal, simulate a peon-ping event by editing the state file:

```bash
python3 -c "
import json, time, os
f = os.path.expanduser('~/.claude/hooks/peon-ping/.state.json')
state = json.load(open(f))
state['last_active'] = {'session_id': 'test', 'pack': 'peon', 'timestamp': time.time(), 'event': 'Stop'}
json.dump(state, open(f, 'w'))
print('Wrote Stop event to state file')
"
```

Expected: In the Electron DevTools console (--dev mode) you'll see no errors. In step 7 (after wiring renderer) you'll see the animation trigger.

**Step 3: Commit**

```bash
git add main.js
git commit -m "feat: add peon-ping state file polling and IPC event dispatch"
```

---

## Task 5: Three.js scene — basic sprite rendering

**Files:**
- Modify: `renderer/app.js`

**Step 1: Replace `renderer/app.js` with Three.js scene**

```js
import * as THREE from '../node_modules/three/build/three.module.js';

// --- Config ---
const ATLAS_COLS = 6;     // frames per row
const ATLAS_ROWS = 6;     // animation rows
const FRAME_SIZE = 64;    // px per frame in atlas

const ANIM_CONFIG = {
  idle:      { row: 0, frames: 6, fps: 4, loop: true  },
  celebrate: { row: 1, frames: 6, fps: 8, loop: false },
  alarmed:   { row: 2, frames: 6, fps: 8, loop: false },
  facepalm:  { row: 3, frames: 5, fps: 6, loop: false },
  wave:      { row: 4, frames: 6, fps: 6, loop: false },
  annoyed:   { row: 5, frames: 6, fps: 6, loop: false },
};

// --- Scene setup ---
const canvas = document.getElementById('c');
const renderer = new THREE.WebGLRenderer({
  canvas,
  alpha: true,          // transparent background
  antialias: false,     // pixel art — keep sharp
});
renderer.setSize(200, 200);
renderer.setPixelRatio(window.devicePixelRatio);
renderer.setClearColor(0x000000, 0);  // fully transparent

const scene = new THREE.Scene();

// Orthographic camera: 200x200 world units = 200x200 pixels
const camera = new THREE.OrthographicCamera(-100, 100, 100, -100, 0.1, 10);
camera.position.z = 1;

// --- Sprite mesh ---
const loader = new THREE.TextureLoader();
const atlas = loader.load('./assets/peon-atlas.png', () => {
  atlas.magFilter = THREE.NearestFilter;  // crisp pixel art scaling
  atlas.minFilter = THREE.NearestFilter;
  atlas.generateMipmaps = false;
});

// UV repeat: show only one frame (1/6 of atlas width and height)
atlas.repeat.set(1 / ATLAS_COLS, 1 / ATLAS_ROWS);

const geometry = new THREE.PlaneGeometry(160, 160);  // 160x160 in a 200x200 viewport
const material = new THREE.MeshBasicMaterial({
  map: atlas,
  transparent: true,
  alphaTest: 0.01,
});
const sprite = new THREE.Mesh(geometry, material);
scene.add(sprite);

// --- Animation state machine ---
let currentAnim = 'idle';
let currentFrame = 0;
let frameTimer = 0;

function setFrame(animName, frame) {
  const { row } = ANIM_CONFIG[animName];
  // UV offset: col offset = frame/COLS, row offset = (ROWS - 1 - row)/ROWS (Y flipped in Three.js)
  atlas.offset.set(
    frame / ATLAS_COLS,
    (ATLAS_ROWS - 1 - row) / ATLAS_ROWS
  );
}

function playAnim(animName) {
  if (!ANIM_CONFIG[animName]) return;
  currentAnim = animName;
  currentFrame = 0;
  frameTimer = 0;
  setFrame(animName, 0);
}

// Start on idle
playAnim('idle');

// --- IPC events from main process ---
window.peonBridge.onEvent(({ anim }) => {
  playAnim(anim);
});

// --- Render loop ---
let lastTime = 0;
function animate(time) {
  requestAnimationFrame(animate);
  const delta = (time - lastTime) / 1000;
  lastTime = time;

  const cfg = ANIM_CONFIG[currentAnim];
  frameTimer += delta;
  if (frameTimer >= 1 / cfg.fps) {
    frameTimer = 0;
    currentFrame++;
    if (currentFrame >= cfg.frames) {
      if (cfg.loop) {
        currentFrame = 0;
      } else {
        // Animation finished — return to idle
        currentFrame = cfg.frames - 1;
        setTimeout(() => playAnim('idle'), 300);
      }
    }
    setFrame(currentAnim, currentFrame);
  }

  renderer.render(scene, camera);
}
requestAnimationFrame(animate);
```

**Step 2: Update `renderer/index.html` to use ES module script**

The `<script>` tag is already `type="module"` from Task 3. Confirm it reads:
```html
<script type="module" src="app.js"></script>
```

**Step 3: Run the app**

```bash
npm run dev
```

Expected: The placeholder sprite atlas is visible in the corner. The peon figure animates through the idle row (green frames cycling). No console errors.

**Step 4: Test animation trigger**

In a second terminal, run the state file simulation from Task 4 Step 2. The avatar should switch from green (idle) to gold (celebrate) frames, then return to green after ~1 second.

**Step 5: Commit**

```bash
git add renderer/app.js
git commit -m "feat: add Three.js sprite atlas animation state machine"
```

---

## Task 6: Shader effects — screen flash

**Files:**
- Create: `renderer/shaders/flash.vert`
- Create: `renderer/shaders/flash.frag`
- Modify: `renderer/app.js`

**Step 1: Write `renderer/shaders/flash.vert`**

```glsl
varying vec2 vUv;
void main() {
  vUv = uv;
  gl_Position = projectionMatrix * modelViewMatrix * vec4(position, 1.0);
}
```

**Step 2: Write `renderer/shaders/flash.frag`**

```glsl
uniform vec3 flashColor;
uniform float flashIntensity;  // 0.0 = no flash, 1.0 = full color overlay
varying vec2 vUv;

void main() {
  // Pure color overlay — blended with transparency
  gl_FragColor = vec4(flashColor, flashIntensity);
}
```

**Step 3: Add flash overlay mesh to `renderer/app.js`**

Add these lines after the sprite mesh is created (before the animation state machine section):

```js
// --- Flash overlay (full-screen color burst) ---
// Load shaders as text — fetch from same origin (renderer/)
async function loadShader(url) {
  const r = await fetch(url);
  return r.text();
}

let flashMesh = null;
let flashIntensity = 0;
let flashColor = new THREE.Color(1, 1, 0);  // default gold
let flashDecay = 2.0;  // intensity units per second

async function setupFlash() {
  const vert = await loadShader('./shaders/flash.vert');
  const frag = await loadShader('./shaders/flash.frag');

  const flashMat = new THREE.ShaderMaterial({
    vertexShader: vert,
    fragmentShader: frag,
    uniforms: {
      flashColor: { value: flashColor },
      flashIntensity: { value: 0.0 },
    },
    transparent: true,
    depthTest: false,
  });

  const flashGeo = new THREE.PlaneGeometry(200, 200);
  flashMesh = new THREE.Mesh(flashGeo, flashMat);
  flashMesh.position.z = 0.5;  // in front of sprite
  scene.add(flashMesh);
}

setupFlash();

function triggerFlash(r, g, b, intensity = 0.6, decay = 3.0) {
  if (!flashMesh) return;
  flashColor.setRGB(r, g, b);
  flashMesh.material.uniforms.flashColor.value = flashColor;
  flashIntensity = intensity;
  flashDecay = decay;
}

// Flash colors per animation
const ANIM_FLASH = {
  celebrate: () => triggerFlash(1.0, 0.8, 0.0, 0.5, 2.5),  // gold
  alarmed:   () => triggerFlash(1.0, 0.1, 0.1, 0.4, 3.0),  // red pulse
  facepalm:  () => triggerFlash(0.8, 0.0, 0.0, 0.5, 2.0),  // dark red
  wave:      () => triggerFlash(0.4, 0.8, 1.0, 0.3, 2.0),  // blue glow
  annoyed:   () => triggerFlash(1.0, 0.4, 0.0, 0.4, 3.0),  // orange
};
```

**Step 4: Update `playAnim` to trigger flash**

Replace the existing `playAnim` function with:

```js
function playAnim(animName) {
  if (!ANIM_CONFIG[animName]) return;
  currentAnim = animName;
  currentFrame = 0;
  frameTimer = 0;
  setFrame(animName, 0);

  if (ANIM_FLASH[animName]) {
    ANIM_FLASH[animName]();
  }
}
```

**Step 5: Update the render loop to decay the flash**

In the `animate` function, add inside the loop before `renderer.render`:

```js
// Decay flash overlay
if (flashMesh && flashIntensity > 0) {
  flashIntensity = Math.max(0, flashIntensity - delta * flashDecay);
  flashMesh.material.uniforms.flashIntensity.value = flashIntensity;
}
```

**Step 6: Run and test flash**

```bash
npm run dev
```

Simulate a `Stop` event (triggers `celebrate` → gold flash):
```bash
python3 -c "
import json, time, os
f = os.path.expanduser('~/.claude/hooks/peon-ping/.state.json')
state = json.load(open(f))
state['last_active'] = {'session_id': 'test', 'pack': 'peon', 'timestamp': time.time(), 'event': 'Stop'}
json.dump(state, open(f, 'w'))
"
```

Expected: Gold flash fades out over ~0.5 seconds on top of the avatar. Sprite switches to celebrate frames.

**Step 7: Commit**

```bash
git add renderer/shaders/ renderer/app.js
git commit -m "feat: add WebGL shader flash effects for peon-ping events"
```

---

## Task 7: Particle burst for task.complete

**Files:**
- Modify: `renderer/app.js`

**Step 1: Add particle system after the flash setup in `renderer/app.js`**

```js
// --- Particle burst (task.complete celebration) ---
const PARTICLE_COUNT = 30;
const particlePositions = new Float32Array(PARTICLE_COUNT * 3);
const particleColors = new Float32Array(PARTICLE_COUNT * 3);
const particleVelocities = [];

const particleGeo = new THREE.BufferGeometry();
particleGeo.setAttribute('position', new THREE.BufferAttribute(particlePositions, 3));
particleGeo.setAttribute('color', new THREE.BufferAttribute(particleColors, 3));

const particleMat = new THREE.PointsMaterial({
  size: 6,
  vertexColors: true,
  transparent: true,
  opacity: 1.0,
  depthTest: false,
  sizeAttenuation: false,
});

const particles = new THREE.Points(particleGeo, particleMat);
particles.visible = false;
particles.position.z = 0.8;
scene.add(particles);

let particleLifetime = 0;
const PARTICLE_DURATION = 1.2;  // seconds

function burstParticles() {
  particleLifetime = PARTICLE_DURATION;
  particles.visible = true;
  particleMat.opacity = 1.0;

  const goldColors = [
    [1.0, 0.85, 0.0],
    [1.0, 1.0, 0.4],
    [0.9, 0.6, 0.1],
  ];

  for (let i = 0; i < PARTICLE_COUNT; i++) {
    // Start at center-bottom of avatar
    particlePositions[i * 3 + 0] = (Math.random() - 0.5) * 40;
    particlePositions[i * 3 + 1] = -40 + (Math.random() - 0.5) * 20;
    particlePositions[i * 3 + 2] = 0;

    // Random upward velocity
    const angle = (Math.random() * Math.PI) - Math.PI / 2;  // upward arc
    const speed = 40 + Math.random() * 80;
    particleVelocities[i] = {
      x: Math.cos(angle) * speed,
      y: Math.abs(Math.sin(angle)) * speed + 20,
      gravity: -60 - Math.random() * 40,
    };

    const c = goldColors[Math.floor(Math.random() * goldColors.length)];
    particleColors[i * 3 + 0] = c[0];
    particleColors[i * 3 + 1] = c[1];
    particleColors[i * 3 + 2] = c[2];
  }

  particleGeo.attributes.position.needsUpdate = true;
  particleGeo.attributes.color.needsUpdate = true;
}
```

**Step 2: Update the render loop to animate particles**

Add inside `animate` before `renderer.render`:

```js
// Update particles
if (particleLifetime > 0) {
  particleLifetime -= delta;
  particleMat.opacity = Math.max(0, particleLifetime / PARTICLE_DURATION);

  for (let i = 0; i < PARTICLE_COUNT; i++) {
    const v = particleVelocities[i];
    if (!v) continue;
    particlePositions[i * 3 + 0] += v.x * delta;
    particlePositions[i * 3 + 1] += v.y * delta;
    v.y += v.gravity * delta;
  }
  particleGeo.attributes.position.needsUpdate = true;

  if (particleLifetime <= 0) {
    particles.visible = false;
  }
}
```

**Step 3: Trigger particles on celebrate**

Update `ANIM_FLASH.celebrate`:

```js
const ANIM_FLASH = {
  celebrate: () => {
    triggerFlash(1.0, 0.8, 0.0, 0.5, 2.5);
    burstParticles();
  },
  // ... rest unchanged
};
```

**Step 4: Test**

```bash
npm run dev
```

Simulate `Stop` event again. Expected: Gold flash + gold particle confetti bursting upward from the avatar, fading out over 1.2 seconds.

**Step 5: Commit**

```bash
git add renderer/app.js
git commit -m "feat: add particle burst effect for task.complete celebration"
```

---

## Task 8: Screen shake for user.spam

**Files:**
- Modify: `renderer/app.js`

**Step 1: Add shake logic to `renderer/app.js`**

Add after the particle system setup:

```js
// --- Screen shake ---
let shakeIntensity = 0;
const SHAKE_DECAY = 8.0;

function triggerShake(intensity = 12) {
  shakeIntensity = intensity;
}
```

**Step 2: Update render loop to apply shake**

Add inside `animate` before `renderer.render`:

```js
// Screen shake (moves the sprite mesh)
if (shakeIntensity > 0) {
  shakeIntensity = Math.max(0, shakeIntensity - SHAKE_DECAY * delta * 60 * delta);
  sprite.position.x = (Math.random() - 0.5) * shakeIntensity;
  sprite.position.y = (Math.random() - 0.5) * shakeIntensity;
} else {
  sprite.position.x = 0;
  sprite.position.y = 0;
}
```

**Step 3: Trigger shake on annoyed**

Update `ANIM_FLASH.annoyed`:

```js
annoyed: () => {
  triggerFlash(1.0, 0.4, 0.0, 0.4, 3.0);
  triggerShake(10);
},
```

**Step 4: Test**

Simulate `UserPromptSubmit` spam:

```bash
python3 -c "
import json, time, os
f = os.path.expanduser('~/.claude/hooks/peon-ping/.state.json')
for i in range(3):
    state = json.load(open(f))
    state['last_active'] = {'session_id': 'test', 'pack': 'peon', 'timestamp': time.time() + i * 0.5, 'event': 'UserPromptSubmit'}
    json.dump(state, open(f, 'w'))
    time.sleep(0.6)
print('done')
"
```

Expected: Avatar shakes and shows orange flash, then returns to idle.

**Step 5: Commit**

```bash
git add renderer/app.js
git commit -m "feat: add screen shake for user.spam annoyed animation"
```

---

## Task 9: Real sprite art guide

**Files:**
- Create: `docs/sprite-art-guide.md`

**Step 1: Write the guide**

```markdown
# Peon Sprite Art Guide

## Atlas Spec

- **Dimensions:** 384×384px (can scale up to 768×768 for retina — keep power-of-2)
- **Frame size:** 64×64px (or 128×128 for retina)
- **Layout:** 6 columns × 6 rows
- **Format:** PNG with transparency

## Row Mapping

| Row | Animation | Frames | Notes |
|-----|-----------|--------|-------|
| 0 | idle | 6 | Gentle breathing bob. Loops. |
| 1 | celebrate | 6 | Jump with arms raised. Plays once. |
| 2 | alarmed | 6 | Wave arms overhead. Plays once. |
| 3 | facepalm | 5-6 | Slump/head drop. Plays once. |
| 4 | wave | 6 | Friendly wave. Plays once. |
| 5 | annoyed | 6 | Arms crossed, head shake. Plays once. |

## AI Generation (Recommended for v1)

Use Midjourney or DALL-E with this prompt style:
> "Warcraft 2 peon character, pixel art, 64x64, sprite sheet, 6 frames of idle animation, transparent background, retro game art style, brown skin, loincloth, hunchback posture"

Generate each row separately, then composite into the atlas using Aseprite, Photoshop, or Figma.

## Aseprite Workflow

1. New file: 384×384px
2. Create 6 layers named: idle, celebrate, alarmed, facepalm, wave, annoyed
3. Draw each animation in its row
4. Export as PNG sprite sheet: File → Export Sprite Sheet → rows=6, cols=6

## Swapping Art

Replace `renderer/assets/peon-atlas.png` with real art.
No code changes needed as long as dimensions match the spec above.
If you change frame count for any row, update `ANIM_CONFIG` in `renderer/app.js`.
```

**Step 2: Commit**

```bash
git add docs/sprite-art-guide.md
git commit -m "docs: add peon sprite art guide for atlas creation"
```

---

## Task 10: README and auto-start

**Files:**
- Create: `README.md`
- Create: `scripts/install-autostart.sh`

**Step 1: Write `README.md`**

```markdown
# peon-ping-avatar

Always-on-top Peon character desktop widget that reacts to peon-ping events.

## Requirements

- macOS (Linux/Windows untested)
- Node.js 18+
- peon-ping installed: https://peonping.com

## Install

```bash
git clone <repo> peon-ping-avatar
cd peon-ping-avatar
npm install
node scripts/gen-placeholder-atlas.js  # generate placeholder art
```

## Run

```bash
npm start
```

The Peon appears in the bottom-right corner of your screen.

## Real sprite art

See `docs/sprite-art-guide.md` for creating the real Peon pixel art atlas.
Replace `renderer/assets/peon-atlas.png` — no code changes needed.

## Auto-start on login (macOS)

```bash
bash scripts/install-autostart.sh
```

## Events

| peon-ping event | Animation | Effect |
|---|---|---|
| Task complete | Celebrate (jump) | Gold flash + confetti |
| Permission needed | Alarmed (arms up) | Red pulse |
| Tool error | Facepalm | Red flash |
| Session start | Wave | Blue glow |
| Repeated prompts | Annoyed | Orange flash + shake |
```

**Step 2: Write `scripts/install-autostart.sh`**

```bash
#!/bin/bash
# Creates a macOS LaunchAgent to start peon-ping-avatar on login.

APP_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PLIST_PATH="$HOME/Library/LaunchAgents/com.peonping.avatar.plist"
NODE_PATH="$(which node)"

cat > "$PLIST_PATH" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.peonping.avatar</string>
  <key>ProgramArguments</key>
  <array>
    <string>$NODE_PATH</string>
    <string>$APP_DIR/node_modules/.bin/electron</string>
    <string>$APP_DIR</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <false/>
  <key>StandardErrorPath</key>
  <string>$HOME/.peon-avatar.log</string>
  <key>StandardOutPath</key>
  <string>$HOME/.peon-avatar.log</string>
</dict>
</plist>
EOF

launchctl load "$PLIST_PATH"
echo "Auto-start installed. Avatar will launch on next login."
echo "To start now: launchctl start com.peonping.avatar"
echo "To remove: launchctl unload $PLIST_PATH && rm $PLIST_PATH"
```

**Step 3: Make it executable**

```bash
chmod +x scripts/install-autostart.sh
```

**Step 4: Final commit**

```bash
git add README.md scripts/install-autostart.sh
git commit -m "docs: add README and macOS auto-start script"
```

---

## Final Verification

Run the complete end-to-end test:

1. Start the app: `npm start`
2. Open a Claude Code session in another terminal
3. Let it complete a task (or simulate with state file test script)
4. Verify: gold flash + confetti burst + celebrate animation fires
5. Hit permission request (or simulate `PermissionRequest`): red flash + alarmed animation

The avatar should return to idle breathing animation between events.

---

## Next Steps (out of scope for v1)

- **Real pixel art** — See `docs/sprite-art-guide.md`
- **Click-to-mute** — Remove `setIgnoreMouseEvents(true)`, add click handler to toggle peon-ping
- **Multiple characters** — Swap atlas + animation config per character (Kerrigan, GLaDOS, etc.)
- **Pack-aware avatar** — Read `last_active.pack` from state, show matching character
- **Electron packager** — `electron-builder` to ship a `.app` bundle
