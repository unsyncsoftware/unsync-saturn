import { closeSync, existsSync, openSync, readFileSync, readSync, statSync } from 'node:fs';
import { extname, isAbsolute, join } from 'node:path';

const siteRoot = process.argv[2] || process.cwd();
const expectedKind = process.argv[3] || 'media';
const expectedExt = expectedKind === 'video' ? '.mp4' : '.mp3';
const expectedMime = expectedKind === 'video' ? 'video/mp4' : 'audio/mpeg';
const playlistPath = join(siteRoot, 'playlist.json');

function fail(message) {
  console.error(`verify failed: ${message}`);
  process.exitCode = 1;
}

function isRelativeMeshPath(value) {
  return (
    typeof value === 'string' &&
    value.length > 0 &&
    !value.startsWith('/') &&
    !isAbsolute(value) &&
    !/^[a-z][a-z0-9+.-]*:/i.test(value) &&
    !value.includes('..')
  );
}

if (!existsSync(playlistPath)) {
  fail(`missing ${playlistPath}`);
  process.exit();
}

let playlist;
try {
  playlist = JSON.parse(readFileSync(playlistPath, 'utf8'));
} catch (error) {
  fail(`playlist.json is not valid JSON: ${error.message}`);
  process.exit();
}

if (!Array.isArray(playlist) || playlist.length === 0) {
  fail('playlist.json must be a non-empty array');
  process.exit();
}

console.log(`playlist entries: ${playlist.length}`);
console.log(`expected MIME: ${expectedMime}`);

for (const entry of playlist) {
  if (!isRelativeMeshPath(entry)) {
    fail(`path is not mesh-compatible relative: ${entry}`);
    continue;
  }

  if (extname(entry).toLowerCase() !== expectedExt) {
    fail(`unexpected media extension for ${entry}; expected ${expectedExt}`);
  }

  const mediaPath = join(siteRoot, entry);
  if (!existsSync(mediaPath)) {
    fail(`missing media file: ${entry}`);
    continue;
  }

  const stats = statSync(mediaPath);
  if (!stats.isFile() || stats.size === 0) {
    fail(`media file is empty or not a regular file: ${entry}`);
    continue;
  }

  if (expectedKind === 'video') {
    const fd = openSync(mediaPath, 'r');
    const buffer = Buffer.alloc(12);
    readSync(fd, buffer, 0, buffer.length, 0);
    closeSync(fd);
    const header = buffer.subarray(4, 12).toString('ascii');
    if (!header.includes('ftyp')) {
      fail(`MP4 header does not expose an ftyp box near the start: ${entry}`);
    }
  }

  console.log(`ok: ${entry} (${stats.size} bytes)`);
}
