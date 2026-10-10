import { defineConfig } from 'vite'

// 铁律提醒（架构 §5.4.1）：前端只允许走 WebSocket，禁止改成轮询。
// 1 秒轮询 = 86,400 请求/天/观众，两个观众就把 CF 免费档 100,000/天 烧光。
export default defineConfig({
  base: './',
  build: {
    outDir: 'dist',
    target: 'es2020',
    sourcemap: false,
  },
  server: {
    host: '127.0.0.1',
    port: 5173,
  },
})
