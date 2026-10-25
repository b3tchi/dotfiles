{ pkgs, ... }:
let
  apiUrl = "http://revo.lan:3030/";
  uiUrl = "http://revo.lan";
  lens = pkgs.callPackage ./lens-backend.nix { };
  lensUi = pkgs.callPackage ./lens-frontend.nix { inherit apiUrl; };
  migrations = [                    # same list as upstream backend/entry.sh
    "addInitialTosPp" "createDefaultSiteConfig" "addOauthToSiteConfig"
    "addOidcProviderToSiteConfig" "addFooterToSiteConfig"
    "addDefaultAdminUser" "createDefaultPublisherEntries"
  ];
in {
  # Ondsel Lens: API on :3030, web UI on :80 (no FC-Worker or S3).
  # Mongo 5+ needs AVX, which the E-450 lacks: FerretDB 1.x on SQLite stands in.
  # FerretDB 1.x has no update arrayFilters, so file thumbnails and share links
  # fail; login, upload, versions and download work.
  services.ferretdb.enable = true;  # sqlite handler, listens on 127.0.0.1:27017

  systemd.services.lens-backend = {
    description = "Ondsel Lens backend";
    after = [ "ferretdb.service" ];
    requires = [ "ferretdb.service" ];
    wantedBy = [ "multi-user.target" ];
    path = [ pkgs.nodejs pkgs.openssl ];
    environment = {
      NODE_ENV = "production";
      NODE_CONFIG_DIR = "${lens}/config";
      PORT = "3030";
      DB_URL = "mongodb://127.0.0.1:27017/backend-db";
      VITE_APP_API_URL = apiUrl;    # base of signed download URLs
      FRONTEND_URL = uiUrl;
      # The UI talks socket.io, whose CORS list (config "origins") has no env
      # mapping; node-config takes it from NODE_CONFIG instead.
      NODE_CONFIG = builtins.toJSON { origins = [ uiUrl ]; };
    };
    script = ''
      # Secrets are made once on this host: never in the store or the NAS share.
      if [ ! -f secrets.env ]; then
        umask 077
        { echo "FEATHERS_SECRET=$(openssl rand -hex 32)"
          echo "LOCAL_SIGNED_URL_SECRET=$(openssl rand -hex 32)"
          echo "DEFAULT_ADMIN_PASSWORD=$(openssl rand -hex 12)"; } > secrets.env
      fi
      set -a; . ./secrets.env; set +a
      # The backend resolves package.json, public/ and uploads/ against its cwd.
      ln -sfn ${lens}/package.json package.json
      ln -sfn ${lens}/public public
      mkdir -p uploads
      node ${lens}/src/migrations/run-migration.js ${toString migrations}
      exec node ${lens}/src
    '';
    serviceConfig = {
      DynamicUser = true;
      StateDirectory = "lens";
      WorkingDirectory = "/var/lib/lens";
      Restart = "on-failure";
      RestartSec = 5;
    };
  };

  # Static UI. Upstream's openresty Lua blocks (share-link previews, sitemaps,
  # pretty download URLs) are left out; the SPA fallback is all the UI needs.
  services.nginx = {
    enable = true;
    virtualHosts.lens = {
      default = true;
      root = lensUi;
      locations."/".tryFiles = "$uri $uri/ /index.html";
    };
  };

  networking.firewall.allowedTCPPorts = [ 80 3030 ];
}
