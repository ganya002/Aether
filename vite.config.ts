import tailwindcss from '@tailwindcss/vite'
import react from '@vitejs/plugin-react'
import { defineConfig, type Plugin } from 'vite'

function aetherToken(): Plugin {
  return {
    name: 'aether-token',
    transformIndexHtml(html) {
      return html.replaceAll('__AETHER_TOKEN__', process.env.AETHER_TOKEN ?? '')
    },
  }
}

export default defineConfig({
  plugins: [react(), tailwindcss(), aetherToken()],
  appType: 'spa',
  server: {
    middlewareMode: true,
  },
})
