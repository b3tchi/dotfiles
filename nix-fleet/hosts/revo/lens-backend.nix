{ lib, buildNpmPackage, fetchFromGitHub, nodejs }:
# Ondsel Lens backend (FreeCAD/Ondsel-Server) as plain Node, no docker.
# package.json "files" only lists lib/, so npm's own install would ship no src:
# copy the whole tree instead.
buildNpmPackage {
  pname = "lens-backend";
  version = "0-unstable-2026-08-23";

  src = fetchFromGitHub {
    owner = "FreeCAD";
    repo = "Ondsel-Server";
    rev = "4d7e86e002490301f6b9d74bb078bdcdf10d16b1";
    hash = "sha256-You0WZw1UCx874dx97M+Yt214VlsSTvUnGhIb91bGqU=";
  };
  sourceRoot = "source/backend";
  npmDepsHash = "sha256-RK0ReOKuX27bU/ZigqbF3quEhJfC9IwUaKyBDwI0nQE=";

  inherit nodejs;
  dontNpmBuild = true;        # plain ESM, "start" is just `node src`

  # Keep devDependencies: src imports axios, which upstream lists only as dev
  # (their docker image runs a full `npm ci`, so it never notices).
  installPhase = ''
    runHook preInstall
    mkdir -p $out
    cp -r package.json src config public node_modules $out/
    runHook postInstall
  '';
}
