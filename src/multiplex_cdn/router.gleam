import wisp.{type Body, type Response}
import gleam/http.{Get, Put}
import gleam/http/request
import gleam/string_builder
import gleam/list.{contains}
import gleam/dynamic.{type Dynamic}
import gleam/result
import gleam/erlang/process.{type Subject}
import gleam/otp/actor
import gleam/io
import gleam/bit_array.{base64_decode}
import gleam/json
import simplifile
import glisten/socket
import multiplex_cdn/utils.{type Config, path_separator}

const reserved_filenames = ["favicon.ico"]

pub type File {
  File(body: String, mime_type: String)
}

fn decode_file(json: String) -> Result(File, json.DecodeError) {
  let decoder =
    dynamic.decode2(
      File,
      dynamic.field("body", dynamic.string),
      dynamic.field("mime_type", dynamic.string),
    )

  json.decode(from: json, using: decoder)
}

pub fn handle_req(req: request.Request(String), cfg: Config) -> Response {
  // basic middleware
  // routes
  case wisp.path_segments(req) {
    [] -> index(req)

    // reserved filenames
    ["favicon.ico"] -> wisp.response(404)

    // basic stats page
    [filename] -> {
      case req.method {
        // GET /file
        Get -> get_file(filename, cfg.data_dir)

        // PUT /file
        Put -> put_file(filename, cfg.data_dir, req)

        _ -> wisp.method_not_allowed([Get, Put])
      }
    }
  }
  |> wisp.set_header("Server", "Wisp/v0.6.0 (Gleam/v0.32.4)")
}

pub type ReqMessage {
  Request(str_msg: String, socket: socket.Socket, cfg: Config)
  Shutdown
}

fn index(req: request.Request(String)) -> Response {
  use <- wisp.require_method(req, Get)
  wisp.ok()
  |> wisp.html_body(string_builder.from_string(
    "<html lang=\"en\">
    <head>
        <title>Multiplex CDN</title>
    </head>
    <body>
        <h1>Leave.</h1>
    </body>
</html>",
  ))
}

/// Handle GET /[filename]
fn get_file(filename: String, data_dir: String) -> Response {
  let path = data_dir <> path_separator() <> filename
  case simplifile.is_file(path) {
    True ->
      wisp.ok()
      |> wisp.set_body(wisp.File(path))
    False -> wisp.response(404)
  }
}

/// Handle PUT /[filename]
fn put_file(
  filename: String,
  data_dir: String,
  req: request.Request(String),
) -> Response {
  let path = data_dir <> path_separator() <> filename

  let json = req.body

  case
    reserved_filenames
    |> contains(any: filename)
  {
    False -> {
      let assert Ok(file) = decode_file(json)
      let assert Ok(bits) = base64_decode(file.body)
      let assert Ok(Nil) = simplifile.write_bits(bits, to: path)
      wisp.ok()
    }
    True -> wisp.response(400)
  }
}
