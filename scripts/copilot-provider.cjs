const http = require('node:http');
const https = require('node:https');
const {timingSafeEqual} = require('node:crypto');
const {spawn} = require('node:child_process');

function reportGatewayError(status, body, report = console.error) {
  let error;
  try {
    error = JSON.parse(body)?.error;
  } catch (cause) {
    if (!(cause instanceof SyntaxError)) throw cause;
    return false;
  }
  if (!error || !(
    status === 403 && error.code === 'PII_DETECTED' ||
    status === 503 && error.code === 'PII_INSPECTION_UNAVAILABLE'
  )) return false;

  const details = [];
  if (status === 403 && Array.isArray(error.categories) &&
      error.categories.length > 0 && error.categories.length <= 32 &&
      error.categories.every(value => typeof value === 'string' && /^[A-Z][A-Z0-9_]{0,63}$/.test(value))) {
    details.push(`categories=${error.categories.join(',')}`);
  }
  if (status === 403 && Number.isSafeInteger(error.matchCount) && error.matchCount > 0) {
    details.push(`matchCount=${error.matchCount}`);
  }
  if (typeof error.requestId === 'string' &&
      /^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/i.test(error.requestId)) {
    details.push(`requestId=${error.requestId}`);
  }
  const message = status === 403 ?
    'Request blocked by PII policy, not an API key authentication failure. Remove personal data or secrets from the request context and retry.' :
    'PII inspection unavailable. Request blocked; check the gateway and PII sidecar.';
  report(`[APIM] ${error.code}: ${message}${details.length ? ` ${details.join('; ')}` : ''}`);
  return true;
}

function forwardingHeaders(headers) {
  const result = {...headers};
  const names = ['connection', 'keep-alive', 'proxy-authenticate', 'proxy-authorization',
    'te', 'trailer', 'transfer-encoding', 'upgrade', 'host',
    ...(headers.connection || '').toLowerCase().split(',').map(name => name.trim())];
  for (const name of names) delete result[name];
  return result;
}

async function runCopilot(args) {
  const upstream = new URL(process.env.COPILOT_PROVIDER_BASE_URL);
  if (upstream.username || upstream.password || upstream.search || upstream.hash ||
      !(upstream.protocol === 'https:' ||
        upstream.protocol === 'http:' && ['127.0.0.1', '[::1]'].includes(upstream.hostname))) {
    throw new Error('Expected an HTTPS provider URL (HTTP is allowed only for loopback tests).');
  }
  const key = Buffer.from(process.env.COPILOT_PROVIDER_API_KEY || '');
  if (!key.length) throw new Error('An APIM subscription key is required.');
  const basePath = upstream.pathname.replace(/\/$/, '');
  const server = http.createServer((request, response) => {
    const presented = Buffer.from(request.headers['ocp-apim-subscription-key'] || '');
    if (presented.length !== key.length || !timingSafeEqual(presented, key)) {
      response.writeHead(401).end();
      return;
    }
    if (!request.url.startsWith(`${basePath}/`)) {
      response.writeHead(404).end();
      return;
    }
    const target = (upstream.protocol === 'https:' ? https : http).request({
      protocol: upstream.protocol, hostname: upstream.hostname, port: upstream.port,
      method: request.method, path: request.url, headers: forwardingHeaders(request.headers)
    }, incoming => {
      response.writeHead(incoming.statusCode, forwardingHeaders(incoming.headers));
      if (incoming.statusCode === 403 || incoming.statusCode === 503) {
        const chunks = [];
        let size = 0;
        incoming.on('data', chunk => {
          size += chunk.length;
          if (size <= 65536) chunks.push(chunk);
        });
        incoming.on('end', () => {
          if (size <= 65536) {
            reportGatewayError(incoming.statusCode, Buffer.concat(chunks).toString('utf8'));
          } else {
            console.error(`[APIM] HTTP ${incoming.statusCode}: error response exceeds diagnostic size limit.`);
          }
        });
      }
      incoming.on('error', () => {
        console.error('[APIM] Provider response interrupted.');
        response.destroy();
      });
      incoming.pipe(response);
    });
    target.on('error', () => {
      console.error('[APIM] Provider connection failed. No fallback or retry was performed.');
      if (response.headersSent) response.destroy();
      else response.writeHead(502, {'Content-Type': 'application/json'})
        .end(JSON.stringify({error: {code: 'PROVIDER_CONNECTION_FAILED', message: 'Provider connection failed.'}}));
    });
    request.on('aborted', () => target.destroy());
    request.on('error', () => target.destroy());
    response.on('close', () => target.destroy());
    request.pipe(target);
  });
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', resolve);
  });
  const child = spawn('copilot', args, {
    stdio: 'inherit',
    env: {...process.env,
      COPILOT_PROVIDER_BASE_URL: `http://127.0.0.1:${server.address().port}${basePath}`}
  });
  for (const signal of ['SIGINT', 'SIGTERM']) {
    process.on(signal, () => child.kill(signal));
  }
  child.on('error', () => console.error('[APIM] Could not launch Copilot CLI.'));
  child.on('close', (code, signal) => {
    server.closeAllConnections();
    server.close();
    process.exitCode = code ?? (signal === 'SIGINT' ? 130 : signal === 'SIGTERM' ? 143 : 1);
  });
}

module.exports = {reportGatewayError, runCopilot};
if (require.main === module) {
  runCopilot(process.argv.slice(2)).catch(error => {
    console.error(`[APIM] Could not start provider diagnostics: ${error.message}`);
    process.exitCode = 1;
  });
}
