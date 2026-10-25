/// <reference types="vitest/config" />
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import react from '@vitejs/plugin-react';
import { defineConfig } from 'vite';
import { devpanelProxy } from './devProxy.ts';

const here = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(here, '../..');

export default defineConfig({
  plugins: [react(), devpanelProxy(repoRoot)],
  base: '/',
  server: {
    host: '127.0.0.1',
    port: Number(process.env.DEVPANEL_UI_PORT || 5173),
  },
  preview: { host: '127.0.0.1' },
  build: {
    outDir: 'dist',
    assetsDir: 'assets',
    emptyOutDir: true,
  },
  test: {
    include: ['test/**/*.test.ts'],
    environment: 'node',
  },
});
