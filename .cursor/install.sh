#!/usr/bin/env bash
# Idempotent Cloud Agent bootstrap for the "Tu Comunidad" Flutter app.
# Installs the pinned Flutter stable SDK (if missing) and fetches dependencies.
set -euo pipefail

# Flutter 3.41.9 is the newest stable that bundles intl 0.20.2 (required by the
# pinned pubspec) while still predating the framework change that marked
# IconData `final` in 3.44.0, which breaks the pinned font_awesome_flutter 10.7.0.
FLUTTER_VERSION="3.41.9"
FLUTTER_HOME="${FLUTTER_HOME:-$HOME/flutter}"
FLUTTER_TARBALL="flutter_linux_${FLUTTER_VERSION}-stable.tar.xz"
FLUTTER_URL="https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/${FLUTTER_TARBALL}"

install_flutter() {
  echo "Installing Flutter ${FLUTTER_VERSION} to ${FLUTTER_HOME} ..."
  rm -rf "${FLUTTER_HOME}"
  local tmp
  tmp="$(mktemp -d)"
  curl -fsSL -o "${tmp}/${FLUTTER_TARBALL}" "${FLUTTER_URL}"
  tar -xf "${tmp}/${FLUTTER_TARBALL}" -C "$(dirname "${FLUTTER_HOME}")"
  rm -rf "${tmp}"
}

current_version() {
  "${FLUTTER_HOME}/bin/flutter" --version 2>/dev/null \
    | sed -n 's/^Flutter \([0-9.]*\).*/\1/p' | head -n1
}

if [ ! -x "${FLUTTER_HOME}/bin/flutter" ] || [ "$(current_version)" != "${FLUTTER_VERSION}" ]; then
  install_flutter
else
  echo "Flutter ${FLUTTER_VERSION} already present at ${FLUTTER_HOME}."
fi

export PATH="${FLUTTER_HOME}/bin:${PATH}"

# Git considers the SDK checkout "unsafe" when owned differently; allow it.
git config --global --add safe.directory "${FLUTTER_HOME}" || true

# Keep setup non-interactive and web enabled.
flutter --disable-analytics >/dev/null 2>&1 || true
flutter config --enable-web --no-cli-animations >/dev/null 2>&1 || true

echo "Flutter version:"
flutter --version

echo "Fetching project dependencies ..."
cd "$(dirname "$0")/.."
flutter pub get

echo "Cloud Agent bootstrap complete."
