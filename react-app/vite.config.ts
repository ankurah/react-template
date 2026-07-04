import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

// https://vitejs.dev/config/
export default defineConfig({
  plugins: [react()],
  server: {
    host: '0.0.0.0',
    // dev.sh randomizes ports and passes them in via env (VITE_PORT / VITE_SERVER_PORT).
    port: parseInt(process.env.VITE_PORT || '5173'),
    proxy: {
      // Proxy the ankurah websocket to the backend so the client uses a single,
      // same-origin URL — the randomized server port never leaks into the app.
      '/ws': {
        target: `ws://127.0.0.1:${process.env.VITE_SERVER_PORT || '9898'}`,
        ws: true,
      },
    },
    fs: {
      allow: [
        '.',
        '../wasm-bindings/pkg',
      ],
    },
  },
})
