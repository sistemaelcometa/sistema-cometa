import assert from "node:assert/strict";
import { access, readFile } from "node:fs/promises";
import test from "node:test";

const root = new URL("../", import.meta.url);

test("project is configured for Next.js and Vercel", async () => {
  const packageJson = JSON.parse(
    await readFile(new URL("package.json", root), "utf8"),
  );

  assert.equal(packageJson.scripts.dev, "next dev");
  assert.equal(packageJson.scripts.build, "next build");
  assert.ok(packageJson.dependencies.next);
  assert.equal(packageJson.dependencies.vinext, undefined);
  assert.equal(packageJson.devDependencies["@cloudflare/vite-plugin"], undefined);
  assert.equal(packageJson.devDependencies.wrangler, undefined);
});

test("public app metadata assets exist", async () => {
  await access(new URL("public/manifest.webmanifest", root));
  await access(new URL("public/el-cometa-logo.png", root));
  await access(new URL("public/favicon-32.png", root));
  await access(new URL("supabase/migrations/001_initial_rentals_schema.sql", root));
});
