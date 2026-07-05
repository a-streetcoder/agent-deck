import js from "@eslint/js";
import tseslint from "typescript-eslint";

export default tseslint.config(
  { ignores: ["**/dist/", "**/node_modules/", "**/coverage/"] },
  js.configs.recommended,
  ...tseslint.configs.recommended,
  {
    rules: {
      "@typescript-eslint/no-unused-vars": [
        "error",
        { argsIgnorePattern: "^_", varsIgnorePattern: "^_" },
      ],
      "@typescript-eslint/consistent-type-imports": "error",
    },
  },
  {
    // Electron main is ESM node code; give it the host timers it uses.
    files: ["apps/desktop/**/*.js"],
    languageOptions: {
      globals: {
        setTimeout: "readonly",
        clearTimeout: "readonly",
        console: "readonly",
      },
    },
  },
  {
    files: ["**/*.cjs"],
    languageOptions: {
      globals: {
        require: "readonly",
        module: "writable",
        process: "readonly",
        __dirname: "readonly",
        console: "readonly",
      },
    },
    rules: {
      "@typescript-eslint/no-require-imports": "off",
    },
  },
);
