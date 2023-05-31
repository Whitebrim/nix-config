{ self, ... }:
{ pkgs, config, ... }: {
  imports = [
    self.nixosModules.nix-flakes
    self.nixosModules.jellyfin-ipv6
  ];

  environment.systemPackages = with pkgs; [
    ripgrep
    fd
    file
    tree
    htop
    btop
    vim
  ];

  networking.firewall.logRefusedConnections = false;

  security.polkit.enable = true;

  users = {
    mutableUsers = false;
    users.nixos = {
      uid = 1000;
      isNormalUser = true;
      extraGroups = with config.users.groups;
        [ wheel.name disk.name ];
      openssh.authorizedKeys.keys = with self.lib.sshKeys;
        github-actions ++ tie ++ brim;
    };
  };

  services = {
    getty.autologinUser = config.users.users.nixos.name;

    openssh = {
      enable = true;
      startWhenNeeded = true;
      settings = {
        PasswordAuthentication = false;
        KbdInteractiveAuthentication = false;
      };
      extraConfig = ''
        LoginGraceTime 15s
        RekeyLimit default 30m
      '';
    };
  };
}
