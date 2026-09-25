#!/usr/bin/env bun
/**
 * Build OpenCode for Android (aarch64).
 *
 * Bun cannot directly --compile for Android, so this script builds a Linux
 * standalone binary with host Bun, extracts its module graph, then appends that
 * graph to the Android Bun runtime built by this project.
 */

import { $ } from "bun"
import fs from "fs"
import path from "path"
import { createSolidTransformPlugin } from "@opentui/solid/bun-plugin"

const OPENCODE_DIR = process.env.OPENCODE_DIR || (() => { throw new Error("OPENCODE_DIR env var not set") })()
const ANDROID_BUN = process.env.ANDROID_BUN || (() => { throw new Error("ANDROID_BUN env var not set") })()
const OUTPUT_DIR = process.env.OUTPUT_DIR || (() => { throw new Error("OUTPUT_DIR env var not set") })()

if (!fs.existsSync(ANDROID_BUN)) {
  console.error("Android bun binary not found at:", ANDROID_BUN)
  process.exit(1)
}

process.chdir(OPENCODE_DIR)

const VERSION = process.env.OPENCODE_VERSION || "1.17.10"
const CHANNEL = process.env.OPENCODE_CHANNEL || "latest"

console.log(`Building OpenCode v${VERSION} (channel: ${CHANNEL}) for Android aarch64`)

console.log("\n=== Step 1: Loading models.dev snapshot ===")
const modelsUrl = process.env.OPENCODE_MODELS_URL || "https://models.dev"
let modelsData = ""
if (process.env.MODELS_DEV_API_JSON) {
  modelsData = await Bun.file(process.env.MODELS_DEV_API_JSON).text()
} else {
  let fetchErr: Error | null = null
  for (let attempt = 1; attempt <= 3; attempt++) {
    try {
      const resp = await fetch(`${modelsUrl}/api.json`, { signal: AbortSignal.timeout(15000) })
      if (!resp.ok) throw new Error(`HTTP ${resp.status}`)
      modelsData = await resp.text()
      fetchErr = null
      break
    } catch (err: any) {
      fetchErr = err
      console.error(`  Attempt ${attempt}/3 failed: ${err.message}`)
      if (attempt < 3) await new Promise((r) => setTimeout(r, 2000 * attempt))
    }
  }
  if (fetchErr) {
    console.error(`ERROR: Failed to fetch models after 3 attempts: ${fetchErr.message}`)
    process.exit(1)
  }
}
JSON.parse(modelsData)
console.log("Loaded models.dev snapshot")

console.log("\n=== Step 2: Resolving OpenTUI workers ===")
const localPath = path.resolve(OPENCODE_DIR, "node_modules/@opentui/core/parser.worker.js")
const rootPath = path.resolve(OPENCODE_DIR, "../../node_modules/@opentui/core/parser.worker.js")
let parserWorkerResolved: string
try {
  parserWorkerResolved = fs.realpathSync(fs.existsSync(localPath) ? localPath : rootPath)
} catch {
  parserWorkerResolved = require.resolve("@opentui/core/parser.worker.js")
}
const workerPath = "./src/cli/tui/worker.ts"
console.log(`Parser worker: ${parserWorkerResolved}`)
console.log(`OpenCode worker: ${workerPath}`)



await $`rm -rf ${OUTPUT_DIR}`
await $`mkdir -p ${OUTPUT_DIR}`

console.log("\n=== Step 3: Bundling OpenCode ===")
const hostBinaryPath = path.join(OUTPUT_DIR, "opencode-host")
const plugin = createSolidTransformPlugin()
const bunfsRoot = "/$bunfs/root/"
const workerRelativePath = path.relative(OPENCODE_DIR, parserWorkerResolved).replaceAll("\\", "/")

// Plugin: rewrite OpenTUI's normalizeLoadedFilePath so it returns early on
// undefined. OpenTUI 0.4.5 does a module-scope await on
// import("@opentui/core/parser.worker", { with: { type: "file" } }). Because
// this build also passes parser.worker.js as a Bun.build entrypoint, that
// import resolves to a JS namespace whose .default is undefined. The
// undefined flows into normalizeLoadedFilePath, which calls .startsWith and
// then path.resolve on it -> TUI crashes before render.
//
// Upstream issue: opencode #37556
//
// We rewrite the function header at bundle time so the undefined is returned
// immediately. Downstream callers (which already use ?? fallbacks) then take
// the graceful path.
const patchOpenTuiPlugin: import("bun").BunPlugin = {
  name: "patch-opentui-normpath",
  setup(build) {
    build.onLoad({ filter: /@opentui\/core\/.*\.js$/ }, async (args) => {
      let text = await Bun.file(args.path).text()
      if (text.includes("normalizeLoadedFilePath") && !/loadedPath\s*==\s*null/.test(text)) {
        const before = text
        text = text.replace(
          /function\s+normalizeLoadedFilePath\s*\(\s*(\w+)\s*,\s*([^)]+)\)\s*\{/,
          (m, p1, p2) => `${m} if (${p1} == null) return ${p1};`
        )
        if (text !== before) {
          console.log(`[patch-opentui-normpath] guarded ${args.path}`)
        }
      }
      return { contents: text, loader: "js" }
    })
  },
}

const result = await Bun.build({
  conditions: ["bun", "node"],
  tsconfig: "./tsconfig.json",
  plugins: [plugin, patchOpenTuiPlugin],
  external: ["node-gyp"],
  format: "esm",
  // minify: false is required: Bun 1.3.2's minifier renames bindings that
// the Bun 1.2.13-canary.1 Android standalone loader cannot resolve,
// producing 'ReferenceError: <sym> is not defined' at startup.
minify: false,
  sourcemap: "none",
  // splitting: false is required: enabling code splitting produces a
// circular chunk dependency between drizzle-orm pg-core chunks
// (chunk-esazrzrp <-> chunk-zpkxvayj), which the 1.2.13 module graph
// loader cannot reconcile, producing
// 'TypeError: The superclass is not a constructor'.
splitting: false,
  compile: {
    autoloadBunfig: false,
    autoloadDotenv: false,
    autoloadTsconfig: true,
    autoloadPackageJson: true,
    outfile: hostBinaryPath,
    execArgv: [`--user-agent=opencode/${VERSION}`, "--use-system-ca", "--"],
  },
  entrypoints: ["./src/index.ts", parserWorkerResolved, workerPath],
  define: {
    FFF_LIBC: `"gnu"`,
    OPENCODE_VERSION: `'${VERSION}'`,
    OPENCODE_MODELS_DEV: modelsData,
    OTUI_TREE_SITTER_WORKER_PATH: bunfsRoot + workerRelativePath,
    OPENCODE_WORKER_PATH: workerPath,
    OPENCODE_CHANNEL: `'${CHANNEL}'`,
    OPENCODE_LIBC: `"glibc"`,
    "process.env.OPENTUI_LIBC": `"glibc"`,
  },
})

if (!result.success) {
  console.error("Build failed:")
  for (const msg of result.logs) console.error(msg)
  process.exit(1)
}
console.log(`Host standalone binary: ${hostBinaryPath}`)

console.log("\n=== Step 4: Extracting module graph ===")
const hostBytes = new Uint8Array(await Bun.file(hostBinaryPath).arrayBuffer())
const hostBuf = Buffer.from(hostBytes.buffer, hostBytes.byteOffset, hostBytes.length)
const trailer = Buffer.from("\n---- Bun! ----\n")
const trailerEnd = hostBytes.length - 8
const trailerStart = trailerEnd - trailer.length
if (hostBuf.compare(trailer, 0, trailer.length, trailerStart, trailerEnd) !== 0) {
  console.error("ERROR: Bun standalone trailer not found at expected position")
  console.error("       The standalone binary format may have changed.")
  process.exit(1)
}
const offsetsSize = 32
const offsetsStart = trailerStart - offsetsSize
const offsetsByteCount = Number(hostBuf.readBigUInt64LE(offsetsStart))
const moduleGraphSize = offsetsByteCount + offsetsSize + trailer.length
const hostBunSize = hostBytes.length - 8 - moduleGraphSize
if (hostBunSize <= 0) {
  console.error(`ERROR: Derived host bun size is ${hostBunSize}`)
  process.exit(1)
}
let moduleGraph = Buffer.from(hostBytes.slice(hostBunSize, hostBytes.length - 8))
console.log(`Host standalone size: ${hostBytes.length}`)
console.log(`Derived host bun size: ${hostBunSize}`)
console.log(`Module graph size: ${moduleGraph.length}`)

console.log("\n=== Step 5: Patching module graph for Android ===")
const mgOffsetsStart = moduleGraph.length - trailer.length - offsetsSize
const modOff = moduleGraph.readUInt32LE(mgOffsetsStart + 8)
const modLen = moduleGraph.readUInt32LE(mgOffsetsStart + 12)
console.log(`String data region: [0, ${modOff}), Module list bytes: ${modLen}`)

const undiciSearch = Buffer.from("__reExport(exports_Undici, undici)")
const undiciReplace = Buffer.from("__reExport(exports_Undici, Undici)")
let undiciPatchCount = 0
let searchPos = 0
const strDataRegion = moduleGraph.slice(0, modOff)
while (true) {
  const pos = strDataRegion.indexOf(undiciSearch, searchPos)
  if (pos < 0) break
  undiciReplace.copy(moduleGraph, pos)
  undiciPatchCount++
  searchPos = pos + undiciSearch.length
}
if (undiciPatchCount === 0) {
  console.warn("WARNING: undici global patch pattern not found; continuing")
} else {
  console.log(`Patched ${undiciPatchCount} undici occurrence(s)`)
}

// Fix opencode #37556: normalizeLoadedFilePath crashes when loadedPath is
// undefined. This happens because parser.worker.js is passed as a Bun.build
// entrypoint, so its `import(..., { with: { type: "file" } })` resolves to a
// JS module namespace whose .default is undefined, and .startsWith then
// throws "undefined is not an object (evaluating 'loadedPath.startsWith')".
// Replace with optional chaining. Same byte length, so no offset rebuild.
{
  const lpSearch = Buffer.from('if (loadedPath.startsWith("file:"))')
  const lpReplace = Buffer.from('if(loadedPath?.startsWith("file:"))')
  if (lpSearch.length !== lpReplace.length) {
    throw new Error("loadedPath patch length mismatch; offsets must be rebuilt")
  }
  let patched = 0
  let idx = 0
  while (true) {
    idx = moduleGraph.indexOf(lpSearch, idx)
    if (idx < 0) break
    lpReplace.copy(moduleGraph, idx)
    patched++
    idx += lpSearch.length
  }
  console.log(`Patched loadedPath guard in module graph: ${patched} occurrence(s)`)
  if (patched === 0) {
    console.log("WARNING: loadedPath guard pattern not found in module graph")
  }
}

console.log("\n=== Step 6: Creating Android standalone binary ===")
const androidBunBytes = new Uint8Array(await Bun.file(ANDROID_BUN).arrayBuffer())
const outputSize = androidBunBytes.length + moduleGraph.length + 8
const output = new Uint8Array(outputSize)
output.set(androidBunBytes, 0)
output.set(new Uint8Array(moduleGraph.buffer, moduleGraph.byteOffset, moduleGraph.length), androidBunBytes.length)

const totalView = new DataView(output.buffer, outputSize - 8, 8)
totalView.setUint32(0, outputSize & 0xffffffff, true)
totalView.setUint32(4, Math.floor(outputSize / 0x100000000), true)

const androidOutputPath = path.join(OUTPUT_DIR, "opencode")
await Bun.write(androidOutputPath, output)
fs.chmodSync(androidOutputPath, 0o755)
console.log(`Android standalone binary: ${androidOutputPath}`)
console.log(`Size: ${(outputSize / 1024 / 1024).toFixed(1)} MB`)

console.log("\n=== Step 7: Verifying output ===")
const verifyBytes = new Uint8Array(await Bun.file(androidOutputPath).arrayBuffer())
const verifyView = new DataView(verifyBytes.buffer, verifyBytes.length - 8, 8)
const verifyTotal = verifyView.getUint32(0, true) + verifyView.getUint32(4, true) * 0x100000000
console.log(`total_byte_count=${verifyTotal}, file_size=${verifyBytes.length}, match=${verifyTotal === verifyBytes.length}`)
if (verifyTotal !== verifyBytes.length) process.exit(1)

const elfMagic = String.fromCharCode(verifyBytes[0], verifyBytes[1], verifyBytes[2], verifyBytes[3])
console.log(`ELF magic: ${elfMagic === "\x7fELF" ? "OK" : "INVALID"}`)
if (elfMagic !== "\x7fELF") process.exit(1)

const ELF_MAGIC = [0x7f, 0x45, 0x4c, 0x46]
const EM_AARCH64 = 0xb7
const EM_X86_64 = 0x3e
const EM_X86 = 0x03
let foundElfCount = 0
let foundX64 = false
let foundX86 = false
for (let i = 0; i < verifyBytes.length - 20; i++) {
  if (
    verifyBytes[i] === ELF_MAGIC[0] &&
    verifyBytes[i + 1] === ELF_MAGIC[1] &&
    verifyBytes[i + 2] === ELF_MAGIC[2] &&
    verifyBytes[i + 3] === ELF_MAGIC[3]
  ) {
    foundElfCount++
    const machine = verifyBytes[i + 18] | (verifyBytes[i + 19] << 8)
    if (machine === EM_X86_64) foundX64 = true
    if (machine === EM_X86) foundX86 = true
    console.log(
      `  ELF at offset ${i}: ${
        machine === EM_AARCH64 ? "aarch64" : machine === EM_X86_64 ? "x86_64" : machine === EM_X86 ? "x86" : `machine=0x${machine.toString(16)}`
      }`,
    )
  }
}
console.log(`Found ${foundElfCount} embedded ELF image(s)`)
if (foundX64 || foundX86) {
  console.warn("WARNING: Embedded x86/x86_64 ELF files detected.")
  console.warn("         Usually this is host bun-pty and is ignored unless BUN_PTY_LIB points at it.")
}

console.log("\n=== Build complete! ===")
console.log(`Output: ${androidOutputPath}`)
