{ lib, buildGoModule }:
# lens-lite: Go, Lens-addon-compatible server (tdpr/server in b3tchi/tdpr).
# Source is a tarball made by ./lens-lite-src.sh (private repo, no GitHub on
# revo); lens-lite.rev records the tdpr commit it holds. Pure Go (modernc
# sqlite), so no cgo. Needs `git` on PATH at runtime: see lens.nix.
buildGoModule {
  pname = "lens-lite";
  version = "0-unstable-${builtins.substring 0 7 (lib.removeSuffix "\n" (builtins.readFile ./lens-lite.rev))}";

  src = ./lens-lite-src.tar.gz;
  sourceRoot = "lens-lite";
  # Fixed-output fetch of the module graph from proxy.golang.org (vendoring
  # the modules into the tarball would add ~45 MB). Update on go.mod/go.sum change.
  vendorHash = "sha256-Z8fJNIplYMZz5dPGs3x1uIw95jFjlJ6IdOPeSwuLVI4=";

  subPackages = [ "cmd/lens-lite" ];
  env.CGO_ENABLED = "0";
  ldflags = [ "-s" "-w" ];
  doCheck = false;               # the suite shells out to git and is run in tdpr CI/dev

  meta.mainProgram = "lens-lite";
}
