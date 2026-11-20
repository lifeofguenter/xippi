-- Prosody test server for Xippi integration tests. Local use only: the
-- passwords and the TURN secret below are public.
--
-- Accounts (created by dev/prosody/entrypoint.sh at every start):
--   alice, bob, carol, admin @prosody.test, password xippi-test
-- In-band registration is open for names starting with "reg-".

admins = { "admin@prosody.test" }

plugin_paths = { "/etc/prosody/modules" }

modules_enabled = {
  -- Stream and session
  "disco";
  "roster";
  "saslauth";
  "tls";
  "smacks";
  "csi_simple";
  "ping";
  "time";
  "uptime";
  "version";
  "limits";

  -- Messaging
  "carbons";
  "mam";
  "blocklist";

  -- PEP and profiles
  "pep";
  "private";
  "bookmarks";
  "vcard4";
  "vcard_legacy";

  -- Registration
  "register";
  "xippi_register_prefix";

  -- Calls
  "turn_external";

  -- Admin
  "admin_adhoc";
  "admin_shell";
}

modules_disabled = { "s2s" }

log = { info = "*console" }

authentication = "internal_hashed"
storage = "internal"

-- TLS: the certificate from dev/make-certs.sh covers prosody.test, its
-- components and localhost, on every port.
tls_profile = "modern"
ssl = {
  certificate = "/etc/prosody/certs/server.pem";
  key = "/etc/prosody/certs/server.key";
}
c2s_require_encryption = true

c2s_ports = { 5222 }
c2s_direct_tls_ports = { 5223 }
http_ports = {}
https_ports = { 5281 }

-- Short enough for the ghost-occupant integration test.
smacks_hibernation_time = 60

allow_registration = true

archive_expires_after = "1w"

turn_external_host = "localhost"
turn_external_port = 3478
turn_external_secret = "xippi-test-turn-secret"

VirtualHost "prosody.test"

Component "conference.prosody.test" "muc"
  modules_enabled = { "muc_mam" }
  restrict_room_creation = false

Component "upload.prosody.test" "http_file_share"
  -- The client reaches the upload service through the published port.
  http_host = "localhost"
