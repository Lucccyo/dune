open Stdune
module Process = Dune_engine.Process
module Display = Dune_engine.Display

module Fiber_job = struct
  let run (command : OpamProcess.command) =
    let open Fiber.O in
    let prefix = "dune-source-fetch" in
    let stderr_file = Temp.create File ~prefix ~suffix:"stderr" in
    let stdout_file =
      match command.cmd_stdout with
      | None -> Temp.create File ~prefix ~suffix:"stdout"
      | Some path -> path |> Path.External.of_string |> Path.external_
    in
    let stderr_to = Process.Io.file stderr_file Out in
    let stdout_to = Process.Io.file stdout_file Out in
    let* times =
      let prog = command.cmd |> Path.External.of_string |> Path.external_ in
      let args = command.args in
      let stdin_from =
        match command.cmd_stdin with
        | Some true -> Some Process.Io.stdin
        | None | Some false -> None
      in
      let dir =
        command.cmd_dir
        |> Option.map ~f:(fun path ->
               path |> Path.Outside_build_dir.of_string
               |> Path.outside_build_dir)
      in
      let env = command.cmd_env |> Option.map ~f:Env.of_unix in
      Process.run_with_times ~display:Quiet ?dir ?env ?stdin_from ~stderr_to
        ~stdout_to prog args
    in
    let result : OpamProcess.result =
      let r_stdout = Io.lines_of_file stdout_file in
      let r_stderr = Io.lines_of_file stderr_file in
      Temp.destroy File stderr_file;
      Temp.destroy File stdout_file;
      (* Process.run_with_times forces Strict failure-mode, so the return code is 0 *)
      let r_code = 0 in
      let r_duration = times.elapsed_time in
      { r_code
      ; r_signal = None
      ; r_duration
      ; r_info = []
      ; r_stdout
      ; r_stderr
      ; r_cleanup = []
      }
    in
    Fiber.return result

  let run =
    let open Fiber.O in
    let rec run1 = function
      | OpamProcess.Job.Op.Done x -> Fiber.return x
      | Run (cmd, cont) ->
        let* r = run cmd in
        let k = cont r in
        run1 k
    in
    run1
end

let fetch loc url ~target =
  let open Fiber.O in
  let path = Path.to_string target in
  let fname = OpamFilename.of_string path in
  let hashes = [] in
  let label = "dune-fetch" in
  let job = OpamRepository.pull_file label fname hashes [ url ] in
  let+ downloaded = Fiber_job.run job in
  match downloaded with
  | Up_to_date () | Result () -> ()
  | Not_available (normal, _verbose) ->
    User_error.raise ~loc
      ([ Pp.textf "%s not available" (OpamUrl.to_string url) ]
      @
      match normal with
      | None -> []
      | Some normal -> [ Pp.text normal ])
