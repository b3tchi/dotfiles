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
    # Keep the audio device open (stream silence). Reopening it through PipeWire
    # froze the menu for seconds; LibreELEC opened ALSA directly and never noticed.
    "audiooutput.streamsilence" = "-1";
    # Suspend after 30 idle minutes in the menu (never during playback).
    # Kodi's PowerState enum: 3 = suspend. A running system update holds a
    # sleep inhibitor (common.nix), so logind refuses until it finishes.
    "powermanagement.shutdowntime" = "30";
    "powermanagement.shutdownstate" = "3";
    # Test: decode in software. With VAAPI every episode logged decoder resets
    # and "OutputPicture - timeout waiting for buffer" before the hangs.
    "videoplayer.usevaapi" = "false";
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

  # Kodi 21.3 can hang mid-playback and then leak until the box thrashes to
  # death (Oct 22 and Oct 31; same as LibreELEC forum thread 30435). These
  # scripts notice the hang and restart Kodi long before that.
  rpcLib = ''
    pw=$(cat /var/lib/htpc/webserver-password)
    rpc() {
      ${pkgs.curl}/bin/curl -sf -m 10 -u "kodi:$pw" -H 'Content-Type: application/json' \
        -d "$1" http://127.0.0.1:8080/jsonrpc
    }
    # Speed and time of the video player, or nothing when nothing plays.
    playing() {
      rpc '{"jsonrpc":"2.0","id":1,"method":"Player.GetActivePlayers"}' \
        | ${pkgs.jq}/bin/jq -e '.result | map(select(.type == "video")) | length > 0' >/dev/null || return 1
      rpc '{"jsonrpc":"2.0","id":1,"method":"Player.GetProperties","params":{"playerid":1,"properties":["speed","time"]}}' \
        | ${pkgs.jq}/bin/jq -r '.result | "\(.speed) \(.time.hours):\(.time.minutes):\(.time.seconds).\(.time.milliseconds)"'
    }
    # kodi.bin lives in the kodi login session, not in kodi.service, so stopping
    # the service alone could leave it running. End the session, then start fresh.
    restart_kodi() {
      echo "restarting Kodi: $1"
      ${pkgs.systemd}/bin/systemctl stop kodi.service     # no Restart=always race
      ${pkgs.systemd}/bin/loginctl terminate-user kodi || true
      for _ in $(seq 15); do ${pkgs.procps}/bin/pgrep -u kodi -x kodi.bin >/dev/null || break; sleep 1; done
      ${pkgs.systemd}/bin/loginctl kill-user kodi -s KILL 2>/dev/null || true
      ${pkgs.systemd}/bin/systemctl start kodi.service
    }
  '';

  # Every minute: Kodi must answer (GetInfoLabels waits for the GUI thread),
  # and playback that isn't paused must move. Three misses in a row → restart.
  # A video paused for 30 min is stopped: Kodi counts paused as playing, so it
  # never idle-suspends, and the hangs began after hours paused (see Kodi
  # issue 30259). Stopping keeps the resume point; Kodi then sleeps after its
  # usual 30 idle minutes in the menu.
  pauseLimit = 30 * 60;
  watchdog = pkgs.writeShellScript "kodi-watchdog" ''
    set -u
    ${rpcLib}
    ${pkgs.systemd}/bin/systemctl -q is-active kodi.service || exit 0
    st=/run/kodi-watchdog; mkdir -p $st
    fails=$(cat $st/fails 2>/dev/null || echo 0)
    ok=1
    rpc '{"jsonrpc":"2.0","id":1,"method":"XBMC.GetInfoLabels","params":{"labels":["System.Time"]}}' >/dev/null || ok=0
    if [ $ok = 1 ] && p=$(playing); then
      speed=''${p%% *}; pos=''${p#* }
      [ "$speed" != 0 ] && [ "$pos" = "$(cat $st/pos 2>/dev/null)" ] && ok=0
      echo "$pos" > $st/pos
      if [ "$speed" = 0 ]; then
        [ -s $st/paused ] || date +%s > $st/paused
        if [ $(( $(date +%s) - $(cat $st/paused) )) -ge ${toString pauseLimit} ]; then
          echo "paused for ${toString (pauseLimit / 60)} min: stopping playback (resume point kept)"
          rpc '{"jsonrpc":"2.0","id":1,"method":"Player.Stop","params":{"playerid":1}}' >/dev/null \
            || echo "Player.Stop got no answer"
          rm -f $st/paused $st/pos
        fi
      else
        rm -f $st/paused
      fi
    else
      rm -f $st/pos $st/paused
    fi
    if [ $ok = 1 ]; then echo 0 > $st/fails; exit 0; fi
    fails=$((fails + 1)); echo $fails > $st/fails
    echo "Kodi check failed ($fails/3)"
    [ $fails -ge 3 ] || exit 0
    echo 0 > $st/fails; rm -f $st/pos
    restart_kodi "no answer or playback stuck for 3 minutes"
  '';

  # A healthy idle box is asleep at 04:00 (30 min idle suspend), so this only
  # catches a Kodi that stayed up all night. Skips while something plays.
  nightly = pkgs.writeShellScript "kodi-nightly-restart" ''
    set -u
    ${rpcLib}
    ${pkgs.systemd}/bin/systemctl -q is-active kodi.service || exit 0
    if p=$(playing) && [ "''${p%% *}" != 0 ]; then echo "playing, skipped"; exit 0; fi
    restart_kodi "nightly"
  '';
in {
  users.users.kodi = {
    isNormalUser = true;
    uid = 1000;                   # pinned: the memory cap below names user-1000.slice
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
  # A leaking Kodi once filled RAM and thrashed the box for 35 min (fan at max,
  # no ssh). PAMName moves kodi.bin into the user's session scope, so the cap
  # sits on the user slice, not kodi.service: over it the kernel kills Kodi
  # and the service restarts it.
  # The cap alone didn't save the box on Oct 31: at the limit the kernel
  # reclaims instead of killing, and the thrash took the whole system down.
  # systemd-oomd kills the worst cgroup once the slice stalls on memory.
  systemd.slices."user-1000".sliceConfig = {
    MemoryMax = "5G"; MemorySwapMax = "512M";
    ManagedOOMMemoryPressure = "kill";
    ManagedOOMMemoryPressureLimit = "50%";
  };
  systemd.oomd.enable = true;

  systemd.services.kodi-watchdog = {
    description = "Restart Kodi when it stops answering or playback is stuck";
    serviceConfig = { Type = "oneshot"; ExecStart = watchdog; };
  };
  systemd.timers.kodi-watchdog = {
    wantedBy = [ "timers.target" ];
    timerConfig = { OnBootSec = "3min"; OnUnitActiveSec = "1min"; AccuracySec = "10s"; };
  };
  systemd.services.kodi-nightly-restart = {
    description = "Restart Kodi if it was left running overnight";
    serviceConfig = { Type = "oneshot"; ExecStart = nightly; };
  };
  systemd.timers.kodi-nightly-restart = {
    wantedBy = [ "timers.target" ];
    # Not Persistent: firing on wake-up would restart Kodi just as someone starts it.
    timerConfig = { OnCalendar = "*-*-* 04:00:00"; };
  };

  # Last resort: if the whole system stops (PID 1 can't feed the watchdog),
  # the SP5100 TCO chip reboots the box instead of leaving it dead for a day.
  systemd.settings.Manager.RuntimeWatchdogSec = "2min";
  # tty1 belongs to Kodi: a getty there (e.g. started by an update) would push Kodi off.
  systemd.services."getty@tty1".enable = false;
  systemd.services."autovt@tty1".enable = false;
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
  services.pipewire = {
    enable = true; alsa.enable = true; pulse.enable = true;
    # Don't suspend idle outputs: waking the USB sound card stalls Kodi.
    wireplumber.extraConfig."51-htpc-no-suspend"."monitor.alsa.rules" = [{
      matches = [{ "node.name" = "~alsa_output.*"; }];
      actions.update-props."session.suspend-timeout-seconds" = 0;
    }];
  };
  services.avahi = { enable = true; nssmdns4 = true; publish = { enable = true; userServices = true; }; };

  # Only the listed NAS folders, read-only, mounted on first access.
  fileSystems = lib.listToAttrs (map (l: lib.nameValuePair "${media}/${l.name}" {
    device = "${nas}:/volume1/Media/${l.name}";
    fsType = "nfs";
    options = [ "ro" "noauto" "x-systemd.automount" "x-systemd.idle-timeout=600" "nfsvers=4" ];
  }) libs);

  # Kodi suspends through logind; allow it even if its session isn't "active".
  security.polkit.enable = true;
  security.polkit.extraConfig = ''
    polkit.addRule(function(action, subject) {
      if (subject.user == "kodi" && action.id.indexOf("org.freedesktop.login1.suspend") == 0)
        return polkit.Result.YES;
    });
  '';
  # Wake from suspend by magic packet (Kore/Yatse "Wake up"); USB remote/keyboard
  # wakes it too. Every wired NIC, so no interface name in the config.
  services.udev.extraRules = ''
    ACTION=="add", SUBSYSTEM=="net", KERNEL=="en*", RUN+="${pkgs.ethtool}/bin/ethtool -s $name wol g"
  '';

  # Kodi web/JSON-RPC (Kore, Yatse) and event server (remotes).
  networking.firewall = { allowedTCPPorts = [ 8080 9090 ]; allowedUDPPorts = [ 9777 ]; };

  # Background jobs: put services in background.slice (Slice = "background.slice")
  # so playback keeps the CPU and disk. Nix builds run at idle priority too.
  systemd.slices.background.sliceConfig = { CPUWeight = 10; IOWeight = 10; };
  nix.daemonCPUSchedPolicy = "idle";
  nix.daemonIOSchedClass = "idle";
}
