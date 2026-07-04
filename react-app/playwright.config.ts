import { defineConfig, devices } from '@playwright/test';

// dev.sh randomizes ports and exports SERVER_PORT / VITE_PORT; honor them if set,
// otherwise fall back to fixed defaults (fine for isolated CI runs).
const SERVER_PORT = process.env.SERVER_PORT || '9898';
const VITE_PORT = process.env.VITE_PORT || '5173';

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
