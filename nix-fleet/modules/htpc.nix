{ config, pkgs, lib, ... }:
# HTPC layer: boots straight into Kodi, drawn directly on the GPU (GBM, like
# LibreELEC; Kodi under the cage compositor rendered black on the 705 G2's
# Radeon R6). Kodi has priority; background work goes into background.slice.
let
  nas = "nas";      # DNS name from the router (DHCP reservation)
  media = "/mnt/media";
  kodi = pkgs.kodi-gbm.withPackages (p: [
    p.inputstream-adaptive
    (p.buildKodiAddon rec {
      pname = "resource-language-cs_cz";
      namespace = "resource.language.cs_cz";
      version = "11.0.103";
      src = pkgs.fetchzip {
        url = "https://mirrors.kodi.tv/addons/omega/${namespace}/${namespace}-${version}.zip";
        hash = "sha256-dKYCkS3vbZ+JhEvuGmZ8HTz6fihYfmC0+tN+2TtPMIc=";
      };
    })
  ]);

  # Enforced before every Kodi start (Kodi rewrites these files on exit).
  gui = {
    "locale.language" = "resource.language.cs_cz";
    "lookandfeel.skincolors" = "pink";        # Estuary's closest to magenta
  };
  hiddenMenu = [ "TV" "Radio" "Games" "Pictures" "Fav" "Weather" "Music" "MusicVideo" ];
  userdata = "/home/kodi/.kodi/userdata";
  db = "${userdata}/Database/MyVideos131.db";   # Kodi 21 video DB

  # Only these NAS folders are mounted and shown. Content type and scraper
  # live in Kodi's DB, so kodi-setup writes them there (Kodi stopped).
  libs = [
    # metadata.local = "Local information only": names, .nfo and art next to the files, no online lookups.
    { name = "Movies"; content = "movies";  scraper = "metadata.local"; recursive = 2147483647; }
    { name = "Series"; content = "tvshows"; scraper = "metadata.local"; recursive = 0; }
  ];

  # Declarative sources; Kodi can't edit them from the GUI (symlink into the store).
  sources = pkgs.writeText "sources.xml" ''
    <sources>
      <video>
        <default pathversion="1"></default>
        ${lib.concatMapStrings (l: ''
          <source><name>${l.name}</name><path pathversion="1">${media}/${l.name}/</path><allowsharing>true</allowsharing></source>
        '') libs}
      </video>
    </sources>
  '';

  addPath = l: ''
    INSERT INTO path (strPath, strContent, strScraper, scanRecursive, useFolderNames,
                      strSettings, noUpdate, exclude, allAudio, dateAdded)
      SELECT '${media}/${l.name}/', '${l.content}', '${l.scraper}', ${toString l.recursive}, 0, ''', 0, 0, 0, datetime('now')
      WHERE NOT EXISTS (SELECT 1 FROM path WHERE strPath = '${media}/${l.name}/');
    UPDATE path SET strContent = '${l.content}', strScraper = '${l.scraper}', scanRecursive = ${toString l.recursive}
      WHERE strPath = '${media}/${l.name}/'
        AND (strContent IS NOT '${l.content}' OR strScraper IS NOT '${l.scraper}');
  '';

  # Runs before Kodi on every boot; each step only acts when something is missing.
  # guisettings.xml is seeded once (Kodi rewrites it, so GUI changes stick):
  # web server / JSON-RPC for Kore and Yatse with a generated password.
  setup = pkgs.writeShellScript "kodi-setup" ''
    set -eu
    install -d -o kodi -g users /home/kodi/.kodi ${userdata}
    install -d -m 700 /var/lib/htpc
    [ -s /var/lib/htpc/webserver-password ] \
      || tr -dc 'a-zA-Z0-9' </dev/urandom | head -c 20 > /var/lib/htpc/webserver-password
    if [ ! -e ${userdata}/guisettings.xml ]; then
      pw=$(cat /var/lib/htpc/webserver-password)
      cat > ${userdata}/guisettings.xml <<EOF
    <settings version="2">
      <setting id="services.webserver">true</setting>
      <setting id="services.webserverport">8080</setting>
      <setting id="services.webserverauthentication">true</setting>
      <setting id="services.webserverusername">kodi</setting>
      <setting id="services.webserverpassword">$pw</setting>
      <setting id="services.esenabled">true</setting>
      <setting id="services.esallinterfaces">true</setting>
      <setting id="services.zeroconf">true</setting>
    </settings>
    EOF
      chown kodi:users ${userdata}/guisettings.xml
      chmod 600 ${userdata}/guisettings.xml
    fi
    # set <file> <id> <xml line>: replace the setting's line or add it before </settings>
    set_xml() {
      grep -q "id=\"$2\"" "$1" \
        && sed -i "s|.*id=\"$2\".*|    $3|" "$1" \
        || sed -i "s|</settings>|    $3\n</settings>|" "$1"
    }
    ${lib.concatStrings (lib.mapAttrsToList (id: v: ''
      set_xml ${userdata}/guisettings.xml ${id} '<setting id="${id}">${v}</setting>'
    '') gui)}
    skin=${userdata}/addon_data/skin.estuary
    install -d -o kodi -g users ${userdata}/addon_data $skin
    [ -e $skin/settings.xml ] || printf '<settings>\n</settings>\n' > $skin/settings.xml
    ${lib.concatMapStrings (b: let id = lib.toLower "HomeMenuNo${b}Button"; in ''
      set_xml $skin/settings.xml ${id} '<setting id="${id}" type="bool">true</setting>'
    '') hiddenMenu}
    chown -R kodi:users ${userdata}/addon_data

    # Kodi creates its DB on first start; content types land on the next boot.
    if [ -e ${db} ]; then
      n=$(${pkgs.sqlite}/bin/sqlite3 ${db} "${lib.concatMapStrings addPath libs} SELECT total_changes();")
      [ "$n" -gt 0 ] && touch /var/lib/htpc/scan-needed
    fi
    exit 0
  '';

  # After new library paths: ask the running Kodi to scan them.
  scan = pkgs.writeShellScript "kodi-scan" ''
    [ -e /var/lib/htpc/scan-needed ] || exit 0
    pw=$(cat /var/lib/htpc/webserver-password)
    for i in $(seq 60); do
      ${pkgs.curl}/bin/curl -sf -u kodi:$pw -H 'Content-Type: application/json' \
        -d '{"jsonrpc":"2.0","id":1,"method":"VideoLibrary.Scan"}' \
        http://127.0.0.1:8080/jsonrpc >/dev/null && { rm /var/lib/htpc/scan-needed; exit 0; }
      sleep 5
    done
    echo "Kodi did not answer; scan stays pending"; exit 1
  '';
in {
  users.users.kodi = {
    isNormalUser = true;
    extraGroups = [ "video" "audio" "input" "render" ];
  };

  systemd.services.kodi = {
    description = "Kodi on tty1 (GBM)";
    wantedBy = [ "multi-user.target" ];
    after = [ "systemd-user-sessions.service" "kodi-setup.service" "network-online.target" ];
    wants = [ "kodi-setup.service" "network-online.target" ];
    conflicts = [ "getty@tty1.service" ];
    # Never restart Kodi from an update (it would stop playback); changes apply at next boot.
    restartIfChanged = false;
    serviceConfig = {
      User = "kodi";
      Group = "users";
      SupplementaryGroups = [ "video" "render" "input" "audio" ];
      PAMName = "login";          # logind session: DRM master, input, user pipewire
      TTYPath = "/dev/tty1";
      StandardInput = "tty";
      StandardOutput = "journal";
      StandardError = "journal";
      ExecStart = "${kodi}/bin/kodi-standalone";
      Restart = "always";
      RestartSec = 5;
      TimeoutStopSec = 20;
    };
  };
  systemd.services.kodi-setup = {
    description = "Prepare Kodi settings and library paths";
    serviceConfig = { Type = "oneshot"; ExecStart = setup; };
  };
  systemd.services.kodi-scan = {
    description = "Scan newly added Kodi library paths";
    wantedBy = [ "kodi.service" ];
    after = [ "kodi.service" ];
    restartIfChanged = false;
    serviceConfig = { Type = "oneshot"; ExecStart = scan; };
  };
  systemd.tmpfiles.rules = [
    "d /home/kodi/.kodi 0750 kodi users -"
    "d ${userdata} 0750 kodi users -"
    "L+ ${userdata}/sources.xml - - - - ${sources}"
  ];

  hardware.graphics.enable = true;
  security.rtkit.enable = true;
  services.pipewire = { enable = true; alsa.enable = true; pulse.enable = true; };
  services.avahi = { enable = true; nssmdns4 = true; publish = { enable = true; userServices = true; }; };

  # Only the listed NAS folders, read-only, mounted on first access.
  fileSystems = lib.listToAttrs (map (l: lib.nameValuePair "${media}/${l.name}" {
    device = "${nas}:/volume1/Media/${l.name}";
    fsType = "nfs";
    options = [ "ro" "noauto" "x-systemd.automount" "x-systemd.idle-timeout=600" "nfsvers=4" ];
  }) libs);

  # Kodi web/JSON-RPC (Kore, Yatse) and event server (remotes).
  networking.firewall = { allowedTCPPorts = [ 8080 9090 ]; allowedUDPPorts = [ 9777 ]; };

  # Background jobs: put services in background.slice (Slice = "background.slice")
  # so playback keeps the CPU and disk. Nix builds run at idle priority too.
  systemd.slices.background.sliceConfig = { CPUWeight = 10; IOWeight = 10; };
  nix.daemonCPUSchedPolicy = "idle";
  nix.daemonIOSchedClass = "idle";
}
