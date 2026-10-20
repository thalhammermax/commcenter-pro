import { defineConfig } from "vite";

export default defineConfig({
  build: {
    // Modern field devices only; avoids legacy transforms that bloat the bundle.
    target: "es2022",
    rollupOptions: {
      output: {
        // Stable vendor chunks: a CommCenter deploy no longer forces every field
        // phone to re-download Leaflet and the Supabase client.
        manualChunks: {
          leaflet: ["leaflet"],
          supabase: ["@supabase/supabase-js"]
        }
      }
    }
  }
});
