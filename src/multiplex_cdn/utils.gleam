import gleam/erlang/os

pub fn path_separator() -> String {
  case os.family() {
    os.WindowsNt -> "\\"
    _ -> "/"
  }
  "/"
}

pub type Config {
  Config(data_dir: String)
}
