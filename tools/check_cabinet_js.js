const fs = require('node:fs');
const path = process.argv[2];
const html = fs.readFileSync(path, 'utf8');
const scripts = [...html.matchAll(/<script>([\s\S]*?)<\/script>/gi)].map((match) => match[1]);
if (scripts.length !== 1) {
  throw new Error(`Expected exactly one inline script, found ${scripts.length}`);
}
new Function(scripts[0]);
console.log('cabinet inline JavaScript syntax: OK');
