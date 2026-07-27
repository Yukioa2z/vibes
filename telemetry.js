const crypto = require('node:crypto');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const http = require('node:http');
const https = require('node:https');

const DEFAULT_ENDPOINT = 'https://vibing.supply/api/install';

function uuid() {
  if (typeof crypto.randomUUID === 'function') {
    return crypto.randomUUID();
  }

  const bytes = crypto.randomBytes(16);
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  const hex = bytes.toString('hex');
  return [
    hex.slice(0, 8),
    hex.slice(8, 12),
    hex.slice(12, 16),
    hex.slice(16, 20),
    hex.slice(20),
  ].join('-');
}

function distributionSource(packageRoot) {
  try {
    const marker = JSON.parse(
      fs.readFileSync(path.join(packageRoot, 'distribution.json'), 'utf8'),
    );
    return marker.source === 'npm' ? 'npm' : 'github';
  } catch {
    return 'github';
  }
}

function installationIdPath(env = process.env) {
  const configRoot =
    env.XDG_CONFIG_HOME || path.join(os.homedir(), '.config');
  return path.join(configRoot, 'vibing-supply', 'installation-id');
}

function getOrCreateInstallationId(env = process.env) {
  const idPath = installationIdPath(env);

  try {
    const existing = fs.readFileSync(idPath, 'utf8').trim();
    if (existing) return existing;
  } catch {
    // First install or an unavailable config directory.
  }

  const id = uuid();
  try {
    fs.mkdirSync(path.dirname(idPath), { recursive: true, mode: 0o700 });
    fs.writeFileSync(idPath, `${id}\n`, {
      encoding: 'utf8',
      mode: 0o600,
      flag: 'wx',
    });
    return id;
  } catch {
    try {
      const winner = fs.readFileSync(idPath, 'utf8').trim();
      if (winner) return winner;
    } catch {
      // Fall back to an ephemeral anonymous id.
    }
    return id;
  }
}

function reportingDisabled(env = process.env) {
  const value = String(env.VIBING_SUPPLY_TELEMETRY || '').toLowerCase();
  return value === '0' || value === 'false' || value === 'off';
}

function postJson(endpoint, payload, timeoutMs = 1500) {
  return new Promise((resolve) => {
    let url;
    try {
      url = new URL(endpoint);
    } catch {
      resolve(false);
      return;
    }

    const body = JSON.stringify(payload);
    const transport = url.protocol === 'http:' ? http : https;
    let request;
    try {
      request = transport.request(
        url,
        {
          method: 'POST',
          headers: {
            'content-type': 'application/json',
            'content-length': Buffer.byteLength(body),
            'user-agent': `vibing-supply/${payload.version}`,
          },
        },
        (response) => {
          response.resume();
          response.on('end', () => {
            resolve(response.statusCode >= 200 && response.statusCode < 300);
          });
        },
      );
    } catch {
      resolve(false);
      return;
    }

    request.on('error', () => resolve(false));
    request.setTimeout(timeoutMs, () => request.destroy());
    request.end(body);
  });
}

async function reportSuccessfulInstall({
  packageRoot,
  version,
  endpoint = process.env.VIBING_SUPPLY_TELEMETRY_ENDPOINT || DEFAULT_ENDPOINT,
  env = process.env,
} = {}) {
  if (!packageRoot || !version || reportingDisabled(env) || env.CI) {
    return false;
  }

  return postJson(endpoint, {
    eventId: uuid(),
    installationId: getOrCreateInstallationId(env),
    source: distributionSource(packageRoot),
    version,
  });
}

module.exports = {
  distributionSource,
  getOrCreateInstallationId,
  installationIdPath,
  postJson,
  reportSuccessfulInstall,
  reportingDisabled,
  uuid,
};
