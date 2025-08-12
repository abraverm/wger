{
  pkgs,
  self,
  system,
}:
pkgs.nixosTest {
  name = "wger-module";

  nodes.server = {
    config,
    lib,
    ...
  }: {
    imports = [self.nixosModules.wger];

    networking.hostName = "server";

    # Keep it simple: Postgres yes, Redis off
    services.wger = {
      enable = true;
      package = self.packages.${system}.default;
      configurePostgres = true;
      configureRedis = false;
      address = "127.0.0.1";
      port = 28391;
      djangoSettings = {
        DEBUG = false;
        SECRET_KEY = "supersecret";
        ALLOWED_HOSTS = ["127.0.0.1" "localhost"];
      };
      wgerSettings = {
        ALLOW_REGISTRATION = false;
        ALLOW_GUEST_USERS = false;
      };
      # Add environment file for secrets
      environmentFile = pkgs.writeText "wger.env" ''
        SECRET_KEY=supersecret
      '';
    };

    environment.systemPackages = [pkgs.curl];
  };

  testScript = ''
    start_all()
    server.wait_for_unit("postgresql.service")
    server.wait_for_unit("wger.service")
    server.wait_for_open_port(28391)

    # Basic reachability and content check
    server.succeed("curl -sS http://127.0.0.1:28391/ | grep -i -E 'wger|login|html'")
  '';
}
