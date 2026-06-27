import { createReadStream, existsSync, statSync } from 'node:fs';
import { createServer } from 'node:http';
import { extname, join, normalize, resolve, sep } from 'node:path';

const root = resolve(process.cwd());
const port = Number(process.argv[2] || process.env.PORT || 5173);

const mimeTypes = new Map([
  ['.html', 'text/html; charset=utf-8'],
  ['.js', 'text/javascript; charset=utf-8'],
  ['.css', 'text/css; charset=utf-8'],
  ['.json', 'application/json; charset=utf-8'],
  ['.mp3', 'audio/mpeg'],
  ['.mp4', 'video/mp4'],
  ['.png', 'image/png'],
  ['.jpg', 'image/jpeg'],
  ['.jpeg', 'image/jpeg'],
  ['.svg', 'image/svg+xml'],
]);

function fileForUrl(url) {
  const pathname = decodeURIComponent(new URL(url, ['http:', '', 'local'].join('/')).pathname);
  const relativePath = pathname === '/' ? 'index.html' : pathname.slice(1);
  const filePath = resolve(root, normalize(relativePath));
  if (filePath !== root && !filePath.startsWith(root + sep)) {
    return null;
  }
  return filePath;
}

function sendFile(req, res, filePath) {
  if (!filePath || !existsSync(filePath) || !statSync(filePath).isFile()) {
    res.writeHead(404, { 'content-type': 'text/plain; charset=utf-8' });
    res.end('Not found');
    return;
  }

  const stats = statSync(filePath);
  const type = mimeTypes.get(extname(filePath).toLowerCase()) || 'application/octet-stream';
  const range = req.headers.range;

  if (range) {
    const match = /^bytes=(\d*)-(\d*)$/.exec(range);
    if (!match) {
      res.writeHead(416, { 'content-range': `bytes */${stats.size}` });
      res.end();
      return;
    }

    const start = match[1] ? Number(match[1]) : 0;
    const end = match[2] ? Number(match[2]) : stats.size - 1;
    if (start > end || end >= stats.size) {
      res.writeHead(416, { 'content-range': `bytes */${stats.size}` });
      res.end();
      return;
    }

    res.writeHead(206, {
      'accept-ranges': 'bytes',
      'content-length': end - start + 1,
      'content-range': `bytes ${start}-${end}/${stats.size}`,
      'content-type': type,
    });
    createReadStream(filePath, { start, end }).pipe(res);
    return;
  }

  res.writeHead(200, {
    'accept-ranges': 'bytes',
    'content-length': stats.size,
    'content-type': type,
  });
  createReadStream(filePath).pipe(res);
}

const server = createServer((req, res) => {
  sendFile(req, res, fileForUrl(req.url || '/'));
});

server.listen(port, () => {
  const address = server.address();
  const resolvedPort = typeof address === 'object' && address ? address.port : port;
  console.log(`Serving ${root} on local port ${resolvedPort}`);
});
