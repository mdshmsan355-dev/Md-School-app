import { copyFileSync, readFileSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";

const root = process.cwd();
copyFileSync(resolve(root, "build/mobile/index.html"), resolve(root, "index.html"));
copyFileSync(resolve(root, "build/mobile/mobile-main.tsx"), resolve(root, "src/mobile-main.tsx"));
copyFileSync(resolve(root, "build/mobile/vite.mobile.config.ts"), resolve(root, "vite.mobile.config.ts"));

const pkgPath = resolve(root, "package.json");
const pkg = JSON.parse(readFileSync(pkgPath, "utf8"));
pkg.scripts = { ...pkg.scripts, "build:mobile": "vite build --config vite.mobile.config.ts" };
writeFileSync(pkgPath, JSON.stringify(pkg, null, 2) + "\n");

const capPath = resolve(root, "capacitor.config.ts");
let cap = readFileSync(capPath, "utf8");
cap = cap.replace(/webDir:\s*"[^"]+"/, 'webDir: "mobile-dist"');
writeFileSync(capPath, cap);
