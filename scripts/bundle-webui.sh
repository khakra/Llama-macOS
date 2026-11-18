#!/bin/sh
# FORK: localchat. Xcode build phase "FORK: Bundle localchat web UI".
# Copies the prebuilt web UI (llama.cpp/ui/apps/chat/dist, a sibling clone) into Contents/Resources/WebUI.
# It does not run npm: build the UI first (scripts/release.sh in khakra/localchat does both).
set -eu

SRC="$SRCROOT/../llama.cpp/ui/apps/chat/dist"
DEST="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/WebUI"

if [ ! -f "$SRC/index.html" ]; then
  if [ "$CONFIGURATION" = "Release" ] && [ "${LOCALCHAT_ALLOW_NO_WEBUI:-NO}" != "YES" ]; then
    echo "error: no web UI build at $SRC. Run 'npm ci && npm run build' in llama.cpp/ui/apps/chat, or pass LOCALCHAT_ALLOW_NO_WEBUI=YES to ship the engine's built-in UI."
    exit 1
  fi
  echo "warning: no web UI build at $SRC, so the app will serve the engine's built-in UI."
  rm -rf "$DEST"
  exit 0
fi

mkdir -p "$DEST"
rsync -a --delete "$SRC/" "$DEST/"

# Build provenance, passed in by scripts/release.sh. Served at /localchat.json.
if [ -n "${LOCALCHAT_APP_COMMIT:-}" ]; then
  cat > "$DEST/localchat.json" <<JSON
{"app_commit":"$LOCALCHAT_APP_COMMIT","ui_commit":"${LOCALCHAT_UI_COMMIT:-}","engine":"${LOCALCHAT_ENGINE:-}"}
JSON
fi

echo "Bundled web UI from $SRC"
