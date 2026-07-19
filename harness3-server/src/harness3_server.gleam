import gleam/erlang/process
import gleam/io
import harness3_server/service
import harness3_server/web

pub fn main() {
  let service = case service.start() {
    Ok(service) -> service
    Error(error) -> {
      io.println("harness3-server failed to initialize: " <> error)
      panic as error
    }
  }
  case web.start(service) {
    Ok(Nil) -> process.sleep_forever()
    Error(error) -> {
      io.println("harness3-server failed to listen: " <> error)
      panic as error
    }
  }
}
