-- Allows in-band registration only for user names starting with "reg-", so
-- tests can create throwaway accounts without opening the server further.

module:hook("user-registering", function(event)
  if not event.username:match("^reg%-") then
    event.allowed = false;
    event.reason = "Only reg-* names can register";
  end
end);
