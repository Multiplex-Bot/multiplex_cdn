import wisp
import gleam/erlang/process
import multiplex_cdn/router.{type ReqMessage, Request, Shutdown}
import glint
import glint/flag
import gleam/list.{at, map, range}
import gleam/otp/actor
import gleam/erlang.{start_arguments}
import gleam/result
import gleam/io
import gleam/string
import gleam/int
import gleam/http
import gleam/http/request
import gleam/bit_array
import gleam/http/response
import gleam/string_builder
import gleam/bytes_builder
import multiplex_cdn/utils.{type Config, Config, path_separator}
import glisten/socket/options.{ActiveMode, Passive}
import glisten/socket
import simplifile
import glisten/tcp

pub fn start(input: glint.CommandInput) {
  wisp.configure_logger()

  let assert Ok(data_dir) = flag.get_string(from: input.flags, for: "data")
  let assert Ok(cores) = flag.get_int(from: input.flags, for: "cores")

  // FIXME: properly save/restore this
  let secret_key_base = wisp.random_string(64)

  let cfg = Config(data_dir)

  let actors =
    range(0, cores - 1)
    |> map(fn(_) {
      let assert Ok(actor) = actor.start([], handle_req_actor)
      actor
    })

  use listener <- result.then(tcp.listen(8080, [ActiveMode(Passive)]))

  event_loop(listener, actors, cfg, 0)
}

fn event_loop(
  listener: socket.ListenSocket,
  actors: List(process.Subject(ReqMessage)),
  cfg: Config,
  idx: Int,
) {
  use socket <- result.then(tcp.accept(listener))
  use msg <- result.then(tcp.receive(socket, 0))
  let str_msg = result.unwrap(bit_array.to_string(msg), "")

  // parse(str_msg, socket)

  let assert Ok(actor) =
    actors
    |> at(idx)

  process.send(actor, Request(str_msg, socket, cfg))

  event_loop(
    listener,
    actors,
    cfg,
    idx + 1
    |> int.clamp(0, list.length(actors) - 1),
  )
}

pub fn handle_req_actor(message: ReqMessage, stack: List(e)) {
  case message {
    Request(msg, socket, cfg) -> {
      //let res = handle_req(req, cfg)
      //process.send(client, Ok(res))
      let req = parse(msg, socket)
      let res = router.handle_req(req, cfg)
      let _ =
        socket
        |> tcp.send(
          case response_to_string(res) {
            String(str) -> bit_array.from_string(str)
            File(bits) -> bits
          }
          |> bytes_builder.from_bit_array(),
        )
      let _ =
        socket
        |> tcp.shutdown()

      actor.continue(stack)
    }
    Shutdown -> actor.Stop(process.Normal)
  }
}

type FinalRes {
  String(String)
  File(BitArray)
}

fn response_to_string(response: response.Response(wisp.Body)) -> FinalRes {
  let initial_res =
    "HTTP/1.1 " <> {
      response.status
      |> int.to_string
    } <> " \r\n" <> {
      response.headers
      |> list.map(fn(x) { x.0 <> ": " <> x.1 })
      |> string.join("\r\n")
    } <> "\r\n"
  case response.body {
    wisp.Text(builder) -> {
      String(
        initial_res <> "\r\n" <> {
          builder
          |> string_builder.to_string()
        },
      )
    }
    wisp.File(path) -> {
      io.debug(path)
      let initial_res = bit_array.from_string(initial_res)
      let assert Ok(content) = simplifile.read_bits(from: path)
      File(bit_array.concat([
        initial_res,
        bit_array.from_string("\r\n"),
        content,
      ]))
    }
    wisp.Empty -> String(initial_res)
  }
}

fn fill_body(
  req: request.Request(String),
  socket: socket.Socket,
  content_length: Int,
  default_content: BitArray,
) -> Result(request.Request(String), Nil) {
  case string.length(req.body) < content_length {
    True -> {
      let msg = result.unwrap(tcp.receive(socket, 0), default_content)
      // let str_msg = result.unwrap(bit_array.to_string(msg), "")
      // let req = request.set_body(req, req.body <> str_msg)

      fill_body(
        req,
        socket,
        content_length + bit_array.byte_size(msg),
        default_content,
      )
    }
    False -> {
      Ok(req)
    }
  }
}

fn parse(str_msg: String, socket: socket.Socket) -> request.Request(String) {
  let #(_, _, req) =
    str_msg
    |> string.split("\r\n")
    |> list.index_fold(
      from: #(
        // is in body
        False,
        // will skip rest of request
        False,
        // the request itself
        request.new(),
      ),
      with: fn(acc, line, idx) {
        let #(_, _, req) = acc
        case idx {
          0 -> {
            let [method, path, _] =
              line
              |> string.split(" ")
            let req =
              request.set_method(
                req,
                result.unwrap(http.parse_method(method), http.Get),
              )
              |> request.set_path(path)
            #(False, False, req)
          }
          _ -> {
            case acc {
              #(True, False, _) -> {
                let req =
                  request.set_body(
                    req,
                    str_msg
                    |> string.split("\r\n")
                    |> list.split(idx)
                    |> fn(a: #(List(String), List(String))) -> List(String) {
                      a.1
                    }
                    |> string.join("\r\n"),
                  )
                #(True, True, req)
              }
              #(False, False, _) -> {
                case line == "" {
                  True -> {
                    #(True, False, req)
                  }
                  False -> {
                    let [key, value] =
                      line
                      |> string.split(": ")
                    let req = request.set_header(req, key, value)
                    #(False, False, req)
                  }
                }
              }
              _ -> {
                acc
              }
            }
          }
        }
      },
    )

  let content_length =
    result.unwrap(request.get_header(req, "Content-Length"), "0")
  let req =
    result.unwrap(
      fill_body(
        req,
        socket,
        content_length
        |> int.parse
        |> result.unwrap(0),
        bit_array.from_string(""),
      ),
      req,
    )

  req
}

fn data_flag() -> flag.FlagBuilder(String) {
  flag.string()
  |> flag.default("." <> path_separator() <> "data")
  |> flag.description("The directory to store data in")
}

fn core_flag() -> flag.FlagBuilder(Int) {
  flag.int()
  |> flag.default(16)
  |> flag.description("The number of actors to spin up")
}

pub fn main() {
  glint.new()
  |> glint.with_name("multiplex-cdn")
  |> glint.with_pretty_help(glint.default_pretty_help())
  |> glint.add(
    at: [],
    do: glint.command(start)
    |> glint.flag("data", data_flag())
    |> glint.flag("cores", core_flag()),
  )
  |> glint.run(start_arguments())
}
