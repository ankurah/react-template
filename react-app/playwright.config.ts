import { defineConfig, devices } from '@playwright/test';
import { execFileSync } from 'node:child_process';

// Ports: honor dev.sh's exported env (SERVER_PORT / VITE_PORT) when present;
// otherwise pick a free random even/odd pair — the same scheme dev.sh uses — so a
// standalone `npm run test:e2e` never collides with other local services. A fixed
// default like 5173 would collide with anything already using it. CI works either
// way: a clean runner simply gets a free pair.
function freePortPair(): [string, string] {
  const script =
    "const net=require('net');" +
    "const free=p=>new Promise(r=>{const s=net.createServer();s.once('error',()=>r(false));s.once('listening',()=>s.close(()=>r(true)));s.listen(p,'0.0.0.0');});" +
    "(async()=>{for(let i=0;i<200;i++){const b=10000+2*Math.floor(Math.random()*4999);if(await free(b)&&await free(b+1)){process.stdout.write(b+' '+(b+1));return;}}process.exit(1);})();";
  const [s, v] = execFileSync(process.execPath, ['-e', script]).toString().trim().split(' ');
  return [s, v];
}

function resolvePorts(): [string, string] {
  if (process.env.SERVER_PORT && process.env.VITE_PORT) {
    return [process.env.SERVER_PORT, process.env.VITE_PORT];
  }
  const [s, v] = freePortPair();
  // Stabilize across re-imports: Playwright reloads this config in the runner and
  // in each worker. Persisting to env means later evals reuse these ports rather
  // than re-randomizing. (Normally `npm run test:e2e` sets these up front.)
  process.env.SERVER_PORT = s;
  process.env.VITE_PORT = v;
  return [s, v];
}

const [SERVER_PORT, VITE_PORT] = resolvePorts();

export default defineConfig({
  testDir: './e2e',
  fullyParallel: false,
  forbidOnly: !!process.env.CI,
  retries: process.env.CI ? 2 : 0,
  workers: 1,
  reporter: 'list',
  use: {
    baseURL: `http://localhost:${VITE_PORT}`,
    trace: 'on-first-retry',
  },
  projects: [
    {
      name: 'chromium',
      use: { ...devices['Desktop Chrome'] },
    },
  ],
  webServer: [
    {
      command: 'cargo run -p {{project-name}}-server --release',
      cwd: '..',
      port: parseInt(SERVER_PORT),
      env: { SERVER_PORT },
      reuseExistingServer: !process.env.CI,
      timeout: 180000,
    },
    {
      command: 'npm run dev',
      port: parseInt(VITE_PORT),
      env: { VITE_PORT, VITE_SERVER_PORT: SERVER_PORT },
      reuseExistingServer: !process.env.CI,
    },
  ],
});
