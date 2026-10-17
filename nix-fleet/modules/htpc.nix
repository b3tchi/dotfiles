{ config, pkgs, lib, ... }:
# HTPC layer: boots straight into Kodi (fullscreen Wayland kiosk, no desktop).
# Kodi has priority; background work goes into background.slice at low weight.
let
  nas = "192.168.1.245";
  media = "/mnt/media";
  kodi = pkgs.kodi-wayland.withPackages (p: [ p.inputstream-adaptive ]);
  userdata = "/home/kodi/.kodi/userdata";

  # Declarative sources; Kodi can't edit them from the GUI (symlink into the store).
  # Content type (movies/tv) is set once per source in the GUI and lives in Kodi's DB.
  src = name: path: ''
    <source><name>${name}</name><path pathversion="1">${media}/${path}/</path><allowsharing>true</allowsharing></source>'';
  sources = pkgs.writeText "sources.xml" ''
    <sources>
      <video>
        <default pathversion="1"></default>
        ${src "Movies" "Movies"}
        ${src "Movies BJ" "Movies BJ"}
        ${src "Series" "Series"}
        ${src "Series BJ" "Series BJ"}
        ${src "OfMyOwn" "OfMyOwn"}
      </video>
      <pictures>
        <default pathversion="1"></default>
        ${src "Photos" "Photos"}
      </pictures>
    </sources>
  '';

  # First-boot seed only: Kodi rewrites guisettings.xml itself, so later GUI
  # changes stick. Enables the web server / JSON-RPC for Kore and Yatse.
  seed = pkgs.writeShellScript "kodi-seed" ''
    set -eu
    install -d -o kodi -g users /home/kodi/.kodi ${userdata}
    [ -e ${userdata}/guisettings.xml ] && exit 0
    install -d -m 700 /var/lib/htpc
    [ -s /var/lib/htpc/webserver-password ] \
      || tr -dc 'a-zA-Z0-9' </dev/urandom | head -c 20 > /var/lib/htpc/webserver-password
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
  '';
in {
  users.users.kodi = {
    isNormalUser = true;
    extraGroups = [ "video" "audio" "input" "render" ];
  };

  services.cage = {
    enable = true;
    user = "kodi";
    program = "${kodi}/bin/kodi-standalone";
  };
  systemd.services."cage-tty1" = {
    after = [ "kodi-seed.service" "network-online.target" ];
    wants = [ "kodi-seed.service" "network-online.target" ];
  };
  systemd.services.kodi-seed = {
    description = "Seed Kodi settings on first boot";
    serviceConfig = { Type = "oneshot"; ExecStart = seed; };
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

  # NAS media, read-only, mounted on first access.
  fileSystems.${media} = {
    device = "${nas}:/volume1/Media";
    fsType = "nfs";
    options = [ "ro" "noauto" "x-systemd.automount" "x-systemd.idle-timeout=600" "nfsvers=4" ];
  };

  # Kodi web/JSON-RPC (Kore, Yatse) and event server (remotes).
  networking.firewall = { allowedTCPPorts = [ 8080 9090 ]; allowedUDPPorts = [ 9777 ]; };

  # Background jobs: put services in background.slice (Slice = "background.slice")
  # so playback keeps the CPU and disk. Nix builds run at idle priority too.
  systemd.slices.background.sliceConfig = { CPUWeight = 10; IOWeight = 10; };
  nix.daemonCPUSchedPolicy = "idle";
  nix.daemonIOSchedClass = "idle";
}
