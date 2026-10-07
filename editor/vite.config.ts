import { defineConfig } from "vitest/config";
import react from "@vitejs/plugin-react";
import tailwind from "@tailwindcss/vite";

// Tauri drives this dev server; 1420 keeps it clear of the retired desktop/ shell on 5173.
export default defineConfig({
  plugins: [react(), tailwind()],
  clearScreen: false,
  server: { port: 1420, strictPort: true },
  envPrefix: ["VITE_", "TAURI_"],
  build: { target: "safari18", sourcemap: true },
  test: { environment: "jsdom", include: ["src/**/*.test.{ts,tsx}"] },
});
