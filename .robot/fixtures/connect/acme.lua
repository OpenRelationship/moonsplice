-- providers/acme/acme.lua in the directory e2e.lua lays out: a service for the connect suite: the fixture server (server.py) answers it on 127.0.0.1, and checks its key.
return {
  provider = "acme", name = "Acme", base = "http://{host}/api",
  auth = { kind = "key", header = "x-acme-key", format = "{token}", env = "ACME_TOKEN" },
  config = { host = "ACME_HOST" }, headers = { accept = "application/json" },
  operations = {
    ["acme.tickets_list"] = { method = "GET", url = "http://{host}/api/tickets", query = { "state" } },
    ["acme.tickets_create"] = { method = "POST", url = "http://{host}/api/tickets", body = { "title", "body" } },
  },
}
