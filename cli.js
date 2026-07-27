#!/usr/bin/env node
// vibing-supply — installer dispatcher for the music skill.
// Thin wrapper that hands off to skills/music/{install,uninstall}.sh
// so users can run `npx vibing-supply install` (or via GitHub:
// `npx Yukioa2z/vibes install`) without cloning the repo themselves.

const { spawnSync } = require('node:child_process');
const path = require('node:path');
const fs = require('node:fs');
const packageJson = require('./package.json');
const { reportSuccessfulInstall } = require('./telemetry');

const SKILL_DIR = path.join(__dirname, 'skills', 'music');
const BIN_DIR = path.join(SKILL_DIR, 'bin');

// command → [interpreter, scriptPath]
const COMMANDS = {
  install:         ['bash',    path.join(SKILL_DIR, 'install.sh')],
  uninstall:       ['bash',    path.join(SKILL_DIR, 'uninstall.sh')],
  'spotify-setup': ['python3', path.join(BIN_DIR,   'music-spotify-setup.py')],
  capabilities:    ['bash',    path.join(BIN_DIR,   'music-capabilities.sh')],
  sync:            ['bash',    path.join(BIN_DIR,   'music-history-sync.sh')],
};

const cmd = process.argv[2];

function usage(exitCode = 0) {
  process.stdout.write(
    'vibing-supply — music-synced session vibe for Claude Code (macOS)\n' +
    '\n' +
    'Usage:\n' +
    '  npx vibing-supply install                   install the music skill (tier 0 — works alone)\n' +
    '  npx vibing-supply uninstall                 reverse the install\n' +
    '  npx vibing-supply spotify-setup <client_id> one-time Spotify OAuth — bring your own app\n' +
    '                                              (https://developer.spotify.com/dashboard)\n' +
    '  npx vibing-supply sync all                  seed taste profile from Spotify history\n' +
    '  npx vibing-supply capabilities              show what tier this install is on\n' +
    '\n' +
    'GitHub-direct alternative (no npm publish required):\n' +
    '  npx github:Yukioa2z/vibes install\n'
  );
  process.exit(exitCode);
}

async function main() {
  if (!cmd || cmd === '--help' || cmd === '-h' || cmd === 'help') {
    usage(0);
  }

  const entry = COMMANDS[cmd];
  if (!entry) {
    process.stderr.write(`unknown command: ${cmd}\n\n`);
    usage(2);
  }

  const [interpreter, scriptPath] = entry;
  if (!fs.existsSync(scriptPath)) {
    process.stderr.write(`script missing: ${scriptPath}\n`);
    process.exitCode = 1;
    return;
  }

  // Forward any extra args past the subcommand (e.g. spotify-setup <client_id>).
  const extraArgs = process.argv.slice(3);
  const result = spawnSync(interpreter, [scriptPath, ...extraArgs], {
    stdio: 'inherit',
  });
  const exitCode = result.status ?? 1;

  // Count completed installs, not attempts. Reporting is anonymous,
  // best-effort, and never changes the install result.
  if (cmd === 'install' && exitCode === 0) {
    try {
      await reportSuccessfulInstall({
        packageRoot: __dirname,
        version: packageJson.version,
      });
    } catch {
      // Ignore analytics failures so a completed install remains successful.
    }
  }

  process.exitCode = exitCode;
}

main().catch(() => {
  process.exitCode = 1;
});
