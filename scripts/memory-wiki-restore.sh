#!/bin/bash
# memory-wiki-restore.sh — Restore the Memory Wiki ecosystem from a backup
# Run this on a new machine after installing Hermes
#
# Usage:
#   memory-wiki-restore <backup-file.tar.gz>
#
# Prerequisites:
#   - Hermes agent installed (hermes --version works)
#   - Node.js installed (node --version works)
#   - Git installed

set -euo pipefail

detect_os() {
  case "$(uname -s)" in
    Darwin*) echo "macos" ;;
    Linux*)  echo "linux" ;;
    *)       echo "unknown" ;;
  esac
}

detect_shell_rc() {
  local shell_name
  shell_name="$(basename "${SHELL:-/bin/bash}")"
  case "$shell_name" in
    zsh)  echo "$HOME/.zshrc" ;;
    bash) echo "$HOME/.bashrc" ;;
    *)    echo "$HOME/.profile" ;;
  esac
}

OS=$(detect_os)

if [[ $# -lt 1 ]]; then
    echo "Usage: memory-wiki-restore <backup-file.tar.gz>"
    echo ""
    echo "Prerequisites:"
    echo "  - Hermes agent:  hermes --version"
    echo "  - Node.js:       node --version"
    echo "  - Git:           git --version"
    exit 1
fi

BACKUP_FILE="$1"

if [[ ! -f "$BACKUP_FILE" ]]; then
    echo "Backup file not found: $BACKUP_FILE"
    exit 1
fi

# Check prerequisites
echo "Checking prerequisites..."
command -v hermes >/dev/null 2>&1 || { echo "Hermes not found. Install from https://hermes-agent.nousresearch.com"; exit 1; }
command -v node >/dev/null 2>&1 || { echo "Node.js not found. Install from https://nodejs.org"; exit 1; }
command -v git >/dev/null 2>&1 || {
  if [[ "$OS" == "macos" ]]; then
    echo "Git not found. Install Xcode Command Tools: xcode-select --install"
  elif [[ "$OS" == "linux" ]]; then
    echo "Git not found. Install with package manager, e.g.: sudo apt install git"
  else
    echo "Git not found."
  fi
  exit 1
}
echo "All prerequisites met"

# Extract backup
STAGING=$(mktemp -d)
trap "rm -rf $STAGING" EXIT
echo "Extracting backup..."
tar -xzf "$BACKUP_FILE" -C "$STAGING"

# Read metadata
if [[ -f "$STAGING/BACKUPINFO.json" ]]; then
    echo "Backup info:"
    cat "$STAGING/BACKUPINFO.json" | python3 -m json.tool 2>/dev/null || cat "$STAGING/BACKUPINFO.json"
    echo ""
fi

# --- 1. Restore wiki app ---
WIKI_DIR="$HOME/workspace/memory-wiki"
echo "Setting up wiki app at $WIKI_DIR..."
mkdir -p "$WIKI_DIR"

# Copy app source (merge with existing if present)
if [[ -d "$STAGING/wiki-app/src" ]]; then
    cp -r "$STAGING/wiki-app/src" "$WIKI_DIR/"
fi
if [[ -d "$STAGING/wiki-app/scripts" ]]; then
    cp -r "$STAGING/wiki-app/scripts" "$WIKI_DIR/"
fi
if [[ -d "$STAGING/wiki-app/public" ]]; then
    cp -r "$STAGING/wiki-app/public" "$WIKI_DIR/"
fi
for f in package.json package-lock.json tsconfig.json next.config.ts tailwind.config.ts postcss.config.mjs AGENTS.md; do
    [[ -f "$STAGING/wiki-app/$f" ]] && cp "$STAGING/wiki-app/$f" "$WIKI_DIR/"
done

# Install dependencies
echo "Installing dependencies..."
cd "$WIKI_DIR"
if [[ -f package.json ]]; then
    npm install --silent 2>&1 | tail -3
fi
echo "Wiki app ready"

# --- 2. Restore wiki data ---
echo "Restoring wiki data..."
mkdir -p "$WIKI_DIR/data/sessions"
if [[ -d "$STAGING/wiki-data" ]]; then
    cp -r "$STAGING/wiki-data/"* "$WIKI_DIR/data/" 2>/dev/null || true
fi
SESSION_COUNT=$(ls "$WIKI_DIR/data/sessions/"*.json 2>/dev/null | wc -l)
echo "$SESSION_COUNT sessions restored"

# --- 3. Restore Hermes state.db ---
HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
if [[ -f "$STAGING/state.db" ]]; then
    echo "Restoring Hermes state.db..."
    mkdir -p "$HERMES_HOME"

    if [[ -f "$HERMES_HOME/state.db" ]]; then
        BACKUP_DB="$STAGING/state.db"
        EXISTING_DB="$HERMES_HOME/state.db"

        BACKUP_SESSIONS=$(sqlite3 "$BACKUP_DB" "SELECT COUNT(*) FROM sessions;" 2>/dev/null || echo "0")

        sqlite3 "$EXISTING_DB" << SQL
ATTACH DATABASE '$BACKUP_DB' AS backup;
INSERT OR IGNORE INTO main.sessions SELECT * FROM backup.sessions;
INSERT OR IGNORE INTO main.messages SELECT * FROM backup.messages;
DETACH DATABASE backup;
SQL

        TOTAL=$(sqlite3 "$EXISTING_DB" "SELECT COUNT(*) FROM sessions;")
        echo "State.db merged: $BACKUP_SESSIONS sessions from backup, $TOTAL total"
    else
        cp "$STAGING/state.db" "$HERMES_HOME/state.db"
        echo "State.db restored fresh"
    fi
fi

# --- 4. Restore wiki-context skill ---
echo "Installing wiki-context skill..."
SKILL_DIR="$HERMES_HOME/skills/wiki-context"
mkdir -p "$SKILL_DIR"
if [[ -d "$STAGING/skills/wiki-context" ]]; then
    cp -r "$STAGING/skills/wiki-context/"* "$SKILL_DIR/"
    echo "Skill installed at $SKILL_DIR"
fi

# --- 5. Install convenience CLI ---
echo "Installing memory-wiki CLI..."
mkdir -p "$HOME/bin"
cp "$STAGING/memory-wiki" "$HOME/bin/memory-wiki"
chmod +x "$HOME/bin/memory-wiki"

# Ensure ~/bin is in PATH
SHELL_RC="$(detect_shell_rc)"
if ! echo "$PATH" | grep -q "$HOME/bin"; then
    echo 'export PATH="$HOME/bin:$PATH"' >> "$SHELL_RC"
    echo "Added ~/bin to PATH (restart terminal or: source $SHELL_RC)"
fi

# --- 6. Install service (launch agent or systemd) ---
if [[ "$OS" == "macos" ]]; then
    echo "Installing launch agent..."
    mkdir -p "$HOME/Library/LaunchAgents"

    PLIST_PATH="$HOME/Library/LaunchAgents/com.memory-wiki.plist"

    # Copy from backup (may be .plist or fall back to generating)
    if [[ -f "$STAGING/launch-agent.plist" ]]; then
        cp "$STAGING/launch-agent.plist" "$PLIST_PATH"
    elif [[ -f "$STAGING/memory-wiki.service" ]]; then
        # Cross-platform restore: generate a new plist
        cat > "$PLIST_PATH" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.memory-wiki</string>
    <key>ProgramArguments</key>
    <array>
        <string>$WIKI_DIR/node_modules/.bin/next</string>
        <string>dev</string>
        <string>-p</string>
        <string>9876</string>
    </array>
    <key>WorkingDirectory</key>
    <string>$WIKI_DIR</string>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$WIKI_DIR/.server.log</string>
    <key>StandardErrorPath</key>
    <string>$WIKI_DIR/.server-error.log</string>
</dict>
</plist>
PLIST
    fi

    /usr/libexec/PlistBuddy -c "Set :WorkingDirectory $WIKI_DIR" "$PLIST_PATH" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c "Set :ProgramArguments:0 $WIKI_DIR/node_modules/.bin/next" "$PLIST_PATH" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c "Set :StandardOutPath $WIKI_DIR/.server.log" "$PLIST_PATH" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c "Set :StandardErrorPath $WIKI_DIR/.server-error.log" "$PLIST_PATH" 2>/dev/null || true

    launchctl unload "$PLIST_PATH" 2>/dev/null || true
    sleep 1
    launchctl load "$PLIST_PATH" 2>/dev/null
    echo "Launch agent installed"

elif [[ "$OS" == "linux" ]]; then
    echo "Installing systemd user service..."
    SERVICE_UNIT_DIR="$HOME/.config/systemd/user"
    mkdir -p "$SERVICE_UNIT_DIR"
    SERVICE_UNIT="$SERVICE_UNIT_DIR/memory-wiki.service"

    NEXT_BIN="$WIKI_DIR/node_modules/.bin/next"
    cat > "$SERVICE_UNIT" << UNIT
[Unit]
Description=Hermes Memory Wiki
After=network.target

[Service]
Type=simple
ExecStart=$NEXT_BIN dev -p 9876
WorkingDirectory=$WIKI_DIR
Restart=on-failure
RestartSec=5
StandardOutput=append:$WIKI_DIR/.server.log
StandardError=append:$WIKI_DIR/.server-error.log

[Install]
WantedBy=default.target
UNIT

    systemctl --user daemon-reload
    systemctl --user enable memory-wiki
    systemctl --user restart memory-wiki

    if command -v loginctl &>/dev/null; then
        loginctl enable-linger "$USER" 2>/dev/null && echo "User lingering enabled" || echo "Note: loginctl enable-linger failed — service may not start after reboot without a login session"
    fi
    echo "Systemd service restored"
else
    echo "Unknown OS — skipping service installation"
fi

# --- 7. Create cron job ---
echo "Setting up auto-scan cron job..."
cat > "$WIKI_DIR/scripts/setup-cron.sh" << 'CRONEOF'
#!/bin/bash
echo "Setting up Wiki Auto-Scan cron job..."
hermes cron create "every 1h" --name "Wiki Auto-Scan" --prompt "Run the Memory Wiki auto-scan: cd $HOME/workspace/memory-wiki && python3 scripts/scan_sessions.py --summarize. If new sessions were found, report briefly. Otherwise stay silent. Do NOT deliver a message to the user unless something went wrong." --toolsets "terminal,file"
CRONEOF
chmod +x "$WIKI_DIR/scripts/setup-cron.sh"
echo "Run $WIKI_DIR/scripts/setup-cron.sh to create the Hermes cron job"

echo ""
echo "Memory Wiki ecosystem restored!"
echo ""
echo "Next steps:"
echo "  1. Restart terminal (or: source $SHELL_RC)"
echo "  2. Run: $WIKI_DIR/scripts/setup-cron.sh"
echo "  3. Verify: memory-wiki status"
if [[ "$OS" == "macos" ]]; then
echo "  4. Open:   memory-wiki open"
else
echo "  4. Open:   memory-wiki open"
fi
echo ""
echo "Wiki URL: http://localhost:9876"
