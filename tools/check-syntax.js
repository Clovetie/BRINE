#!/usr/bin/env node
// Lightweight Luau syntax check for the BRINE project.
//
// `luaparse` understands standard Lua but not Luau-only syntax, so we strip
// Luau type-assertion casts (`:: Type`) before parsing. This catches typos,
// missing `end`, and other structural mistakes without requiring the full
// Luau toolchain.
//
// By default it checks the folders used by the new scripts:
//   src/ReplicatedStorage/HandHolding
//   src/ServerScriptService
//   src/StarterPlayerScripts
//
// Pass explicit paths to check selected files instead:
//   node tools/check-syntax.js src/Path/To/Script.luau
//
// Run with:
//   npm --prefix tools install        (once)
//   node tools/check-syntax.js

const fs = require("fs");
const path = require("path");
const luaparse = require("luaparse");

const root = path.resolve(__dirname, "..", "src");
const DEFAULT_ROOTS = [
	path.join(root, "ReplicatedStorage", "HandHolding"),
	path.join(root, "ServerScriptService"),
	path.join(root, "StarterPlayerScripts"),
];

function collectLuauFiles(dir) {
	const out = [];
	for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
		const full = path.join(dir, entry.name);
		if (entry.isDirectory()) {
			out.push(...collectLuauFiles(full));
		} else if (entry.name.endsWith(".luau")) {
			out.push(full);
		}
	}
	return out;
}

function stripLuauCasts(source) {
	return source
		.replace(/::\s*[\w?]+(?:[\w?]|\.)*/g, "")
		.replace(/::\s*\([^)]*\)/g, "");
}

function resolveTargets(argv) {
	if (argv.length > 0) {
		return argv.map((item) => path.resolve(process.cwd(), item));
	}
	return DEFAULT_ROOTS;
}

let failures = 0;
const targets = resolveTargets(process.argv.slice(2));
const files = [];

for (const target of targets) {
	if (fs.statSync(target).isDirectory()) {
		files.push(...collectLuauFiles(target));
	} else {
		files.push(target);
	}
}

if (files.length === 0) {
	console.error("No .luau files found in the requested locations.");
	process.exit(1);
}

for (const file of files) {
	const source = fs.readFileSync(file, "utf8");
	try {
		luaparse.parse(stripLuauCasts(source), { luaVersion: "5.1" });
		console.log("OK   ", path.relative(process.cwd(), file));
	} catch (err) {
		failures += 1;
		console.error("FAIL ", path.relative(process.cwd(), file));
		console.error("     ", err.message);
	}
}

if (failures > 0) {
	console.error(`\n${failures} file(s) failed the syntax check.`);
	process.exit(1);
}

console.log(`\nAll ${files.length} Luau file(s) parsed successfully.`);
