{ config, lib, pkgs, ... }: {
  networking.hostName = "bootstrap";

  services.openssh.hostKeys = [{
    path = "/etc/ssh/ssh_host_ed25519_key";
    type = "ed25519";
  }];

  users.users.nixos.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAiAKU7x1o6NPI/7AqwCaC8edvl80//2LgyVSV/3tIfb tie@xhyve"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFOq52CJ77uZJ7lDpRgODDMaO22PeHi1GB+rRyj7j+o1 tie@goro"
  ];
}
