/** @type {import("tailwindcss").Config} */
export default {
  content: ["./src/**/*.{astro,html,js,ts}"],
  theme: {
    extend: {
      fontFamily: {
        sans: [
          "Inter",
          "ui-sans-serif",
          "system-ui",
          "-apple-system",
          "Segoe UI",
          "sans-serif",
        ],
        mono: [
          "JetBrains Mono",
          "ui-monospace",
          "SFMono-Regular",
          "Menlo",
          "monospace",
        ],
      },
      colors: {
        // Zinc base with cyan + lime for status, red for danger.
        accent:   "#67e8f9",   // cyan-300
        ok:       "#a3e635",   // lime-400
        warn:     "#fbbf24",   // amber-400
        danger:   "#f87171",   // red-400
        ink:      "#e4e4e7",   // zinc-200
        muted:    "#71717a",   // zinc-500
        panel:    "#18181b",   // zinc-900
        panel2:   "#27272a",   // zinc-800
        line:     "#3f3f46",   // zinc-700
      },
    },
  },
  plugins: [],
};
