#!/usr/bin/env node
'use strict';

/**
 * luau.js — shared, dependency-light helpers for analysing BRINE's Luau source
 * from Node. Zero dependencies (no luaparse required for these heuristics).
 *
 * The analysis is *lexical/pattern based*, not a full semantic pass. It is
 * deliberately conservative and reports its own confidence so a future AI can
 * trust the *findings* without mistaking heuristics for a compiler.
 *
 * Every helper returns data, never throws on malformed source. All functions
 * preserve line/column structure of the original so results line up with the
 * file as a human sees it.
 */

const fs = require('fs');
const path = require('path');

/**
 * Replace comments (-- line, --[[ block ]], --[==[ block ]==]) and string
 * literals with spaces, preserving newlines so line numbers stay valid.
 * Backtick Luau interpolated strings and quoted strings are masked too.
 */
// Given a position i at an opening long-bracket delimiter, return the index just
// past the matching close (or source.length if not found). `quote` is the number
// of '=' separating the two brackets. Handles `[[`, `[=[`, `[==[`, etc.
function findLongBracketEnd(source, i, quote, n) {
	const close = ']' + '='.repeat(quote) + ']';
	const end = source.indexOf(close, i);
	return end === -1 ? n : end + close.length;
}

function stripCommentsAndStrings(source) {
	let out = '';
	let i = 0;
	const n = source.length;
	while (i < n) {
		const c = source[i];
		const next = source[i + 1];

		// Long bracket comment OR string boundary: `--[[`, `--[=[`, `[[`, `[=[`, ...
		// A long bracket is `[` + zero-or-more `=` + `[`. Detect it generically.
		if (c === '[' && (next === '[' || next === '=')) {
			let j = i + 1;
			let equals = '';
			while (source[j] === '=') { equals += '='; j++; }
			if (source[j] === '[') {
				const stop = findLongBracketEnd(source, j + 1, equals.length, n);
				out += source.slice(i, stop).replace(/[^\n]/g, ' ');
				i = stop;
				continue; // (this is a string, not a comment; but both are masked)
			}
		}

		// `--` comment: either a line comment or a `--[[ ... ]]` block comment.
		// IMPORTANT: check the long-bracket comment form BEFORE the line comment so
		// multi-line `--[[ ]]` blocks are fully masked (not just to the newline).
		if (c === '-' && next === '-') {
			// Could be `--[[ ... ]]` / `--[=[ ... ]=]`.
			let k = i + 2;
			if (source[k] === '[') {
				let eq = '';
				let q = k + 1;
				while (source[q] === '=') { eq += '='; q++; }
				if (source[q] === '[') {
					const stop = findLongBracketEnd(source, q + 1, eq.length, n);
					out += source.slice(i, stop).replace(/[^\n]/g, ' ');
					i = stop;
					continue;
				}
			}
			// Otherwise it's a line comment.
			let j = i;
			while (j < n && source[j] !== '\n') j++;
			out += source.slice(i, j).replace(/[^\n]/g, ' ');
			i = j;
			continue;
		}

		// Single, double, or backtick string.
		if (c === '"' || c === "'" || c === '`') {
			const quote = c;
			let j = i + 1;
			while (j < n) {
				if (source[j] === '\\') { j += 2; continue; }
				if (source[j] === quote) { j++; break; }
				j++;
			}
			const stop = Math.min(j, n);
			out += source.slice(i, stop).replace(/[^\n]/g, ' ');
			i = stop;
			continue;
		}

		out += c;
		i++;
	}
	return out;
}

/** Robustly extract the right-hand "name" from a require(...) argument. */
function lastPathSegment(arg) {
	// Match the final identifier or quoted string in a path expression, e.g.
	//   script.Parent.Settings      -> Settings
	//   RS.Gerstner.Helper          -> Helper
	//   RS:WaitForChild('Octree')   -> Octree
	//   script.Parent               -> Parent (unresolvable; caller skips)
	const m = arg.match(/([_A-Za-z][_A-Za-z0-9]*)\s*$/);
	if (m) return m[1];
	const str = arg.match(/'([^']+)'|"([^"]+)"/);
	if (str) return str[1] || str[2];
	return null;
}

/**
 * Return the "instance name" a module on disk maps to under Rojo:
 *   - `<dir>/init.luau`  -> the parent directory's name
 *   - `<dir>/<name>.luau`-> <name>
 * Used to know the Roblox instance/module table name.
 */
function moduleInstanceName(filePath) {
	const base = path.basename(filePath);
	if (base === 'init.luau' || base === 'init.server.luau' || base === 'init.client.luau') {
		return path.basename(path.dirname(filePath));
	}
	return base.replace(/\.(init\.)?(server|client)?\.luau$/, '').replace(/\.luau$/, '');
}

/** Recursively collect every .luau file under a directory (skips hidden/.git). */
function collectLuauFiles(dir, acc = []) {
	if (!fs.existsSync(dir)) return acc;
	for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
		if (entry.name.startsWith('.')) continue;
		const full = path.join(dir, entry.name);
		if (entry.isDirectory()) collectLuauFiles(full, acc);
		else if (entry.name.endsWith('.luau')) acc.push(full);
	}
	return acc;
}

/**
 * Extract exported functions/methods and plain local functions from masked
 * source. Returns [{ namespace, name, kind, line }].
 *   - `Helper.GetFrustumPlanes`  -> { namespace:'Helper', name:'GetFrustumPlanes', kind:'static' }
 *   - `function ZoneManager:InsertZone` -> { namespace:'ZoneManager', name:'InsertZone', kind:'method' }
 *   - `Setup.GetBlankVertexKey = function` -> { namespace:'Setup', name:'GetBlankVertexKey', kind:'static' }
 *   - `local function foo()` -> { namespace:null, name:'foo', kind:'local' }
 */
	function extractDefinitions(masked) {
	const defs = [];
	const lines = masked.split('\n');
	// Luau generics may appear between a name and its parameter list:
	//   `function Octree:CreateNode<T>(...)`   -> optional <T>
	//   `function Setup.GetBlankVertexKey(...)` -> plain
	for (let ln = 0; ln < lines.length; ln++) {
		const line = lines[ln];
		// `function NS.name(` or `function NS:name(` (allow optional generics)
		let m = line.match(/function\s+([_A-Za-z][_A-Za-z0-9]*)\s*([.:])\s*([_A-Za-z][_A-Za-z0-9]*)\s*(?:<[^>]*>)?\s*\(/);
		if (m) {
			defs.push({ namespace: m[1], name: m[3], kind: m[2] === ':' ? 'method' : 'static', line: ln + 1 });
			continue;
		}
		// `function name(` (plain local/global)
		m = line.match(/function\s+([_A-Za-z][_A-Za-z0-9]*)\s*(?:<[^>]*>)?\s*\(/);
		if (m) {
			defs.push({ namespace: null, name: m[1], kind: 'local', line: ln + 1 });
			continue;
		}
		// `NS.name = function(` or `NS:name = function(`
		m = line.match(/([_A-Za-z][_A-Za-z0-9]*)\s*([.:])\s*([_A-Za-z][_A-Za-z0-9]*)\s*=\s*function\s*(?:<[^>]*>)?\s*\(/);
		if (m) {
			defs.push({ namespace: m[1], name: m[3], kind: m[2] === ':' ? 'method' : 'static', line: ln + 1 });
		}
	}
	return defs;
}

/**
 * Extract `local Alias = require(...)` bindings.
 * Returns [{ alias, target (last path segment), line }].
 */
function extractRequires(masked) {
	const reqs = [];
	const lines = masked.split('\n');
	for (let ln = 0; ln < lines.length; ln++) {
		const m = lines[ln].match(/local\s+([_A-Za-z][_A-Za-z0-9]*)\s*=\s*require\s*\(\s*([^)]*)\)/);
		if (m) {
			const target = lastPathSegment(m[2]);
			if (target) reqs.push({ alias: m[1], target, line: ln + 1 });
		}
	}
	return reqs;
}

/**
 * Extract namespace references from masked source, e.g. `Helper.GetFrustumPlanes`,
 * `ZoneManager:InsertZone`, `GerstnerModule.ComputeTransform`. Returns unique
 * [{ namespace, name }].
 */
function extractReferences(masked, knownNamespaces) {
	const refs = new Set();
	const known = new Set(knownNamespaces);
	const lineRe = /([_A-Za-z][_A-Za-z0-9]*)\s*([.:])\s*([_A-Za-z][_A-Za-z0-9]*)/g;
	let m;
	// We run on the whole masked source, so a reference's left-hand identifier is
	// only treated as a *namespace* if it matches a known module table name. This
	// avoids treating arbitrary `a.b` pairs (x.Y, pos.X) as module references.
	while ((m = lineRe.exec(masked))) {
		if (known.has(m[1])) refs.add(`${m[1]}::${m[3]}`);
		else refs.add(`${m[1]}~${m[3]}`);
	}
	// Also accept the alias form where the alias maps to a known namespace:
	// handled by the caller by passing knownNamespaces = aliases + module names.
	return [...refs].map((s) => {
		if (s.includes('::')) {
			const [ns, name] = s.split('::');
			return { namespace: ns, name };
		}
		const [ns, name] = s.split('~');
		return { namespace: ns, name, uncertain: true };
	});
}

/**
 * Recognise the common "instance method" pattern where a module constructor is
 * stored in a local and its methods are called on that local:
 *
 *   local ZONE_TREE = OctreeModule.new()
 *   ZONE_TREE:CreateNode(...)            -> Octree::CreateNode
 *
 * Given the masked source and a map `varName -> moduleName` (built from
 * `local X = <module>.<ctor>(...)` patterns), return the instance-method
 * references as { namespace, name } resolved to the module.
 */
function extractInstanceRefs(masked, instanceVarMap) {
	const refs = new Set();
	for (const [varName, moduleName] of Object.entries(instanceVarMap)) {
		const re = new RegExp(`(?:^|[^\\w])${varName}\\s*[:.]\\s*([_A-Za-z][_A-Za-z0-9]*)\\s*\\(`, 'g');
		let m;
		while ((m = re.exec(masked))) {
			refs.add(`${moduleName}::${m[1]}`);
		}
	}
	return [...refs].map((s) => {
		const [namespace, name] = s.split('::');
		return { namespace, name };
	});
}

/**
 * Build a varName -> moduleName map for the common `local X = Mod.new(...)`
 * / `local X = Mod.new` constructor pattern, so instance-method calls on X can
 * be attributed to Mod. `resolveNamespace(name)` maps a namespace token (module
 * instanceName or a `require(...)` alias) to a module instanceName, or returns
 * null if unknown (e.g. `Part.new`, `Instance.new`, `Vector3.new`).
 */
function buildInstanceVarMap(masked, resolveNamespace) {
	const map = {};
	// Matches `local X = <something>.new(...)` or `local X = <something>.new`
	// but NOT `local X = Instance.new(...)`/`Part.new`/`Vector3.new` — those are
	// filtered when resolveNamespace returns null.
	const re = /local\s+([_A-Za-z][_A-Za-z0-9]*)\s*=\s*([_A-Za-z][_A-Za-z0-9]*)\s*\.\s*new\s*\(?/g;
	let m;
	while ((m = re.exec(masked))) {
		const varName = m[1];
		const ns = m[2];
		const resolved = resolveNamespace(ns);
		if (resolved && resolved !== varName) map[varName] = resolved;
	}
	return map;
}

/** Load a file, mask it, extract defs + requires in one pass. */
function analyseFile(filePath) {
	const source = fs.readFileSync(filePath, 'utf8');
	const masked = stripCommentsAndStrings(source);
	return {
		file: filePath,
		instanceName: moduleInstanceName(filePath),
		definitions: extractDefinitions(masked),
		requires: extractRequires(masked),
		sourceLength: source.length,
	};
}

module.exports = {
	stripCommentsAndStrings,
	lastPathSegment,
	moduleInstanceName,
	collectLuauFiles,
	extractDefinitions,
	extractRequires,
	extractReferences,
	extractInstanceRefs,
	buildInstanceVarMap,
	analyseFile,
};
