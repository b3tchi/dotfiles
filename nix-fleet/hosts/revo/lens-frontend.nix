{ lib, buildNpmPackage, fetchFromGitHub, apiUrl }:
# Ondsel Lens web UI as static files. Upstream bakes __VITE_*__ placeholders
# and seds them at container start; here the real values go into vite build.
# Matomo and Stripe stay unset (only a console error for matomo.js).
buildNpmPackage {
  pname = "lens-frontend";
  version = "0-unstable-2026-08-23";

  src = fetchFromGitHub {
    owner = "FreeCAD";
    repo = "Ondsel-Server";
    rev = "4d7e86e002490301f6b9d74bb078bdcdf10d16b1";
    hash = "sha256-You0WZw1UCx874dx97M+Yt214VlsSTvUnGhIb91bGqU=";
  };
  sourceRoot = "source/frontend";
  npmDepsHash = "sha256-NuotBlMjqSlUyTjpJNwQgSfxPdhX3u8VyUSSL7XYl+Q=";
  # Offline `npm ci` otherwise asks the registry for vue to check peer ranges.
  npmFlags = [ "--legacy-peer-deps" ];

  VITE_APP_API_URL = apiUrl;     # must end in "/": src appends paths directly

  installPhase = ''
    runHook preInstall
    cp -r dist $out
    runHook postInstall
  '';
}
