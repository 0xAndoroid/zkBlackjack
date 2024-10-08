/** @type {import('tailwindcss').Config} */
export default {
  content: ["./index.html", "./src/**/*.{js,ts,jsx,tsx}"],
  theme: {
    extend: {
      colors: {
        bg0: "#2C2E34",
        bg1: "#33353F",
        bg2: "#363944",
        orange: "#F39660",
        purple: "#B39DF3",
        fg: "#E2E2E3",
        black: "#181819"
      }
    },
  },
  plugins: [],
};
