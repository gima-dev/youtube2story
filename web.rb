require "webrick"
require "webrick/https"

server = WEBrick::HTTPServer.new(
  Port: 443,
  SSLEnable: true,
  SSLCertName: [["CN", "gima.dedyn.io"]]
)

server.mount_proc "/" do |_req, res|
  res.status = 200
  res["Content-Type"] = "text/plain"
  res.body = "hello world"
end

trap("INT") { server.shutdown }

server.start
