open Import
open Memo.O

(* This file is licensed under The MIT License *)
(* (c) MINES ParisTech 2018-2019               *)
(* (c) INRIA 2020-2023                         *)
(* Written by: Ali Caglayan                    *)
(* Written by: Emilio Jesús Gallego Arias      *)
(* Written by: Rudi Grinberg                   *)

(* Utilities independent from Coq, they should be eventually moved
   elsewhere; don't mix with the rest of the code. *)
module Util : sig
  val include_flags : Lib.t list -> _ Command.Args.t

  val include_flags_legacy : Coq_lib.Legacy.t list -> _ Command.Args.t

  val ml_pack_files : Lib.t -> Path.t list

  val meta_info :
       loc:Loc.t option
    -> version:int * int
    -> context:Context_name.t
    -> Lib.t
    -> Path.t option

  (** Given a list of library names, we try to resolve them in order, returning
      the first one that exists. *)
  val resolve_first : Lib.DB.t -> string list -> Lib.t Resolve.Memo.t
end = struct
  let include_paths ts =
    Path.Set.of_list_map ts ~f:(fun t ->
        let info = Lib.info t in
        Lib_info.src_dir info)

  let include_flags ts = include_paths ts |> Lib_flags.L.to_iflags

  let include_flags_legacy cps =
    let cmxs_dirs = List.concat_map ~f:Coq_lib.Legacy.cmxs_directories cps in
    let f p = [ Command.Args.A "-I"; Command.Args.Path p ] in
    let l = List.concat_map ~f cmxs_dirs in
    Command.Args.S l

  (* coqdep expects an mlpack file next to the sources otherwise it
   * will omit the cmxs deps *)
  let ml_pack_files lib =
    let plugins =
      let info = Lib.info lib in
      let plugins = Lib_info.plugins info in
      Mode.Dict.get plugins Mode.Native
    in
    let to_mlpack file =
      [ Path.set_extension file ~ext:".mlpack"
      ; Path.set_extension file ~ext:".mllib"
      ]
    in
    List.concat_map plugins ~f:to_mlpack

  let meta_info ~loc ~version ~context (lib : Lib.t) =
    let name = Lib.name lib |> Lib_name.to_string in
    match Lib_info.status (Lib.info lib) with
    | Public (_, pkg) ->
      let package = Package.name pkg in
      let meta_i =
        Path.Build.relative
          (Local_install_path.lib_dir ~context ~package)
          "META"
      in
      Some (Path.build meta_i)
    | Installed -> None
    | Installed_private | Private _ ->
      let is_error = version >= (0, 6) in
      let text = if is_error then "not supported" else "deprecated" in
      User_warning.emit ?loc ~is_error
        [ Pp.textf "Using private library %s as a Coq plugin is %s" name text ];
      None

  (* CR alizter: move this to Lib.DB *)

  (** Given a list of library names, we try to resolve them in order, returning
      the first one that exists. *)
  let rec resolve_first lib_db = function
    | [] -> Code_error.raise "resolve_first: empty list" []
    | [ n ] -> Lib.DB.resolve lib_db (Loc.none, Lib_name.of_string n)
    | n :: l -> (
      let open Memo.O in
      Lib.DB.resolve_when_exists lib_db (Loc.none, Lib_name.of_string n)
      >>= function
      | Some l -> Resolve.Memo.lift l
      | None -> resolve_first lib_db l)
end

let coqc ~loc ~dir ~sctx =
  Super_context.resolve_program sctx "coqc" ~dir ~loc:(Some loc)
    ~hint:"opam install coq"

let select_native_mode ~sctx ~dir (buildable : Coq_stanza.Buildable.t) =
  match buildable.mode with
  | Some x ->
    if
      buildable.coq_lang_version < (0, 7)
      && Profile.is_dev (Super_context.context sctx).profile
    then Memo.return Coq_mode.VoOnly
    else Memo.return x
  | None -> (
    if buildable.coq_lang_version < (0, 3) then Memo.return Coq_mode.Legacy
    else if buildable.coq_lang_version < (0, 7) then Memo.return Coq_mode.VoOnly
    else
      let* coqc = coqc ~sctx ~dir ~loc:buildable.loc in
      let+ config = Coq_config.make_opt ~coqc in
      match config with
      | None -> Coq_mode.VoOnly
      | Some config -> (
        match Coq_config.by_name config "coq_native_compiler_default" with
        | Some (String "yes") | Some (String "ondemand") -> Coq_mode.Native
        | _ -> Coq_mode.VoOnly))

let coq_flags ~dir ~stanza_flags ~expander ~sctx =
  let open Action_builder.O in
  let* standard = Action_builder.of_memo @@ Super_context.coq ~dir sctx in
  Expander.expand_and_eval_set expander stanza_flags ~standard

let theory_coqc_flag lib =
  let name = Coq_lib_name.wrapper (Coq_lib.name lib) in
  let dir = Coq_lib.obj_root lib in
  let binding_flag = if Coq_lib.implicit lib then "-R" else "-Q" in
  Command.Args.S [ A binding_flag; Path dir; A name ]

let theories_flags ~theories_deps =
  Resolve.Memo.args
    (let open Resolve.Memo.O in
    let+ libs = theories_deps in
    Command.Args.S (List.map ~f:theory_coqc_flag libs))

let boot_flags ~coq_lang_version t : _ Command.Args.t =
  let boot_flag = if coq_lang_version >= (0, 8) then [ "-boot" ] else [] in
  match t with
  (* We are compiling the prelude itself
      [should be replaced with (per_file ...) flags] *)
  | `Bootstrap_prelude -> As ("-noinit" :: boot_flag)
  (* No special case *)
  | `No_boot | `Bootstrap _ -> As boot_flag

let coqc_file_flags ~dir ~theories_deps ~wrapper_name ~boot_type ~ml_flags
    ~coq_lang_version : _ Command.Args.t list =
  let file_flags : _ Command.Args.t list =
    [ Dyn (Resolve.Memo.read ml_flags)
    ; theories_flags ~theories_deps
    ; A "-R"
    ; Path (Path.build dir)
    ; A wrapper_name
    ]
  in
  [ boot_flags ~coq_lang_version boot_type; S file_flags ]

let native_includes ~dir =
  let* scope = Scope.DB.find_by_dir dir in
  let lib_db = Scope.libs scope in
  (* We want the cmi files *)
  Resolve.Memo.map ~f:(fun lib ->
      let info = Lib.info lib in
      let obj_dir = Obj_dir.public_cmi_ocaml_dir (Lib_info.obj_dir info) in
      Path.Set.singleton obj_dir)
  @@ Util.resolve_first lib_db [ "coq-core.kernel"; "coq.kernel" ]

let directories_of_lib ~sctx lib =
  let name = Coq_lib.name lib in
  match lib with
  | Coq_lib.Dune lib ->
    let dir = Coq_lib.Dune.src_root lib in
    let* dir_contents = Dir_contents.get sctx ~dir in
    let+ coq_sources = Dir_contents.coq dir_contents in
    Coq_sources.directories coq_sources ~name
  | Coq_lib.Legacy _ ->
    (* TODO: we could return this if we don't restrict ourselves to
       Path.Build.t here.

       EJGA: We need to understand how this interacts with globally
       installed stuff, that's more tricky than it looks actually!

       This fuction is used in order to determine the -nI flags that
       Coq native compiler will pass to OCaml so it can find the .cmxs
       files. For things in user-contrib we don't need to pass these
       flags but only because Coq has a very large hack adding this
       directories on require. *)
    Memo.return []

let setup_native_theory_includes ~sctx ~theories_deps ~theory_dirs =
  Resolve.Memo.bind theories_deps ~f:(fun theories_deps ->
      let+ l =
        Memo.parallel_map theories_deps ~f:(fun lib ->
            let+ theory_dirs = directories_of_lib ~sctx lib in
            Path.Build.Set.of_list theory_dirs)
      in
      Resolve.return (Path.Build.Set.union_all (theory_dirs :: l)))

let coqc_native_flags ~sctx ~dir ~theories_deps ~theory_dirs
    ~(mode : Coq_mode.t) =
  match mode with
  | Legacy -> Command.Args.empty
  | VoOnly ->
    Command.Args.As
      [ "-w"
      ; "-deprecated-native-compiler-option"
      ; "-w"
      ; "-native-compiler-disabled"
      ; "-native-compiler"
      ; "ondemand"
      ]
  | VosOnly ->
    Command.Args.As
      [ "-vos"
      ; "-w"
      ; "-deprecated-native-compiler-option"
      ; "-w"
      ; "-native-compiler-disabled"
      ; "-native-compiler"
      ; "ondemand"
      ]
  | Native ->
    let args =
      let open Action_builder.O in
      let* native_includes = Resolve.Memo.read @@ native_includes ~dir in
      let+ native_theory_includes =
        Resolve.Memo.read
        @@ setup_native_theory_includes ~sctx ~theories_deps ~theory_dirs
      in
      let include_ dir acc = Command.Args.Path dir :: A "-nI" :: acc in
      let native_include_ml_args =
        Path.Set.fold native_includes ~init:[] ~f:include_
      in
      let native_include_theory_output =
        Path.Build.Set.fold native_theory_includes ~init:[] ~f:(fun dir acc ->
            include_ (Path.build dir) acc)
      in
      (* This dir is relative to the file, by default [.coq-native/] *)
      Command.Args.S
        [ Command.Args.As [ "-w"; "-deprecated-native-compiler-option" ]
        ; As [ "-native-output-dir"; "." ]
        ; As [ "-native-compiler"; "on" ]
        ; S (List.rev native_include_ml_args)
        ; S (List.rev native_include_theory_output)
        ]
    in
    Command.Args.Dyn args

(* closure of all the ML libs a theory depends on *)
let libs_of_theory ~lib_db ~theories_deps plugins :
    (Lib.t list * _) Resolve.Memo.t =
  let open Resolve.Memo.O in
  let* libs =
    Resolve.Memo.List.map plugins ~f:(fun (loc, name) ->
        let+ lib = Lib.DB.resolve lib_db (loc, name) in
        (loc, lib))
  in
  let* theories = theories_deps in
  (* Filter dune theories *)
  let f (t : Coq_lib.t) =
    match t with
    | Dune t -> Left t
    | Legacy t -> Right t
  in
  let dune_theories, legacy_theories = List.partition_map ~f theories in
  let* dlibs =
    Resolve.List.concat_map ~f:Coq_lib.Dune.libraries dune_theories
    |> Resolve.Memo.lift
  in
  let libs = libs @ dlibs in
  let+ findlib_libs = Lib.closure ~linking:false (List.map ~f:snd libs) in
  (findlib_libs, legacy_theories)

(* compute include flags and mlpack rules *)
let ml_pack_and_meta_rule ~context ~all_libs
    (buildable : Coq_stanza.Buildable.t) : unit Action_builder.t =
  (* coqdep expects an mlpack file next to the sources otherwise it will
     omit the cmxs deps *)
  let coq_lang_version = buildable.coq_lang_version in
  let plugin_loc = List.hd_opt buildable.plugins |> Option.map ~f:fst in
  let meta_info =
    Util.meta_info ~loc:plugin_loc ~version:coq_lang_version ~context
  in
  (* If the mlpack files don't exist, don't fail *)
  Action_builder.all_unit
    [ Action_builder.paths (List.filter_map ~f:meta_info all_libs)
    ; Action_builder.paths_existing
        (List.concat_map ~f:Util.ml_pack_files all_libs)
    ]

let ml_flags_and_ml_pack_rule ~context ~lib_db ~theories_deps
    (buildable : Coq_stanza.Buildable.t) =
  let res =
    let open Resolve.Memo.O in
    let+ all_libs, legacy_theories =
      libs_of_theory ~lib_db ~theories_deps buildable.plugins
    in
    let findlib_plugin_flags = Util.include_flags all_libs in
    let legacy_plugin_flags = Util.include_flags_legacy legacy_theories in
    let ml_flags =
      Command.Args.S [ findlib_plugin_flags; legacy_plugin_flags ]
    in
    (ml_flags, ml_pack_and_meta_rule ~context ~all_libs buildable)
  in
  let mlpack_rule =
    let open Action_builder.O in
    let* _, mlpack_rule = Resolve.Memo.read res in
    mlpack_rule
  in
  (Resolve.Memo.map ~f:fst res, mlpack_rule)

(* the internal boot flag determines if the Coq "standard library" is being
   built, in case we need to explicitly tell Coq where the build artifacts are
   and add `Init.Prelude.vo` as a dependency; there is a further special case
   when compiling the prelude, in this case we also need to tell Coq not to
   try to load the prelude. *)
let boot_type ~dir ~use_stdlib ~wrapper_name ~coq_lang_version coq_module =
  let* scope = Scope.DB.find_by_dir dir in
  let+ boot_lib =
    scope |> Scope.coq_libs
    |> Coq_lib.DB.resolve_boot ~coq_lang_version
    |> Resolve.Memo.read_memo
  in
  if use_stdlib then
    match boot_lib with
    | None ->
      `No_boot
      (* XXX: use_stdlib + no_boot is
         actually a workspace error, cleanup *)
    | Some (_loc, lib) ->
      (* This is here as an optimization, TODO; replace with per_file flags *)
      let init =
        String.equal (Coq_lib_name.wrapper (Coq_lib.name lib)) wrapper_name
        && Option.equal String.equal
             (List.hd_opt (Coq_module.prefix coq_module))
             (Some "Init")
      in
      if init then `Bootstrap_prelude else `Bootstrap lib
  else `Bootstrap_prelude

let dep_theory_file ~dir ~wrapper_name =
  Path.Build.relative dir ("." ^ wrapper_name)
  |> Path.Build.set_extension ~ext:".theory.d"

let setup_coqdep_for_theory_rule ~sctx ~dir ~loc ~theories_deps ~wrapper_name
    ~use_stdlib ~source_rule ~ml_flags ~mlpack_rule ~coq_lang_version
    coq_modules =
  let* boot_type =
    (* If coq_modules are empty it doesn't really matter, so we take
       the more conservative path and pass -boot, we don't care here
       about -noinit as coqdep ignores it *)
    match coq_modules with
    | [] -> Memo.return `Bootstrap_prelude
    | m :: _ -> boot_type ~dir ~use_stdlib ~wrapper_name ~coq_lang_version m
  in
  (* coqdep needs the full source + plugin's mlpack to be present :( *)
  let sources = List.rev_map ~f:Coq_module.source coq_modules in
  let file_flags =
    [ Command.Args.S
        (coqc_file_flags ~dir ~theories_deps ~wrapper_name ~boot_type ~ml_flags
           ~coq_lang_version)
    ; As [ "-dyndep"; "opt"; "-vos" ]
    ; Deps sources
    ]
  in
  let stdout_to = dep_theory_file ~dir ~wrapper_name in
  let* coqdep =
    Super_context.resolve_program sctx "coqdep" ~dir ~loc:(Some loc)
      ~hint:"opam install coq"
  in
  (* Coqdep has to be called in the stanza's directory *)
  Super_context.add_rule ~loc sctx ~dir
    (let open Action_builder.With_targets.O in
    Action_builder.with_no_targets mlpack_rule
    >>> Action_builder.(with_no_targets (goal source_rule))
    >>> Command.run ~dir:(Path.build dir) ~stdout_to coqdep file_flags)

module Dep_map = Stdune.Map.Make (Path)

let coqdep_invalid phase line =
  Code_error.raise "coqdep returned invalid output"
    [ ("phase", Dyn.string phase); ("line", Dyn.string line) ]

let parse_line ~dir line =
  match String.lsplit2 line ~on:':' with
  | None -> coqdep_invalid "split" line
  | Some (basename, deps) ->
    (* This should always have a file, but let's handle the error
       properly *)
    let target =
      match String.extract_blank_separated_words basename with
      | [] -> coqdep_invalid "target" line
      | vo :: _ -> vo
    in
    (* let depname, ext = Filename.split_extension ff in *)
    let target = Path.relative (Path.build dir) target in
    let deps = String.extract_blank_separated_words deps in
    (* Add prelude deps for when stdlib is in scope and we are not actually
       compiling the prelude *)
    let deps = List.map ~f:(Path.relative (Path.build dir)) deps in
    (target, deps)

let get_dep_map ~dir ~wrapper_name : Path.t list Dep_map.t Action_builder.t =
  let file = dep_theory_file ~dir ~wrapper_name in
  let open Action_builder.O in
  let f = parse_line ~dir in
  Action_builder.lines_of (Path.build file) >>| fun lines ->
  List.map ~f lines |> Dep_map.of_list |> function
  | Ok map -> map
  | Error (k, r1, r2) ->
    Code_error.raise "get_dep_map: duplicate keys"
      [ ("lines", Dyn.list Dyn.string lines)
      ; ("key", Path.to_dyn k)
      ; ("entry 1", Dyn.list Path.to_dyn r1)
      ; ("entry 2", Dyn.list Path.to_dyn r2)
      ]

let deps_of ~dir ~boot_type ~wrapper_name ~mode coq_module =
  let open Action_builder.O in
  let vo_target =
    let ext =
      match mode with
      | Coq_mode.VosOnly -> ".vos"
      | _ -> ".vo"
    in
    Path.set_extension ~ext (Coq_module.source coq_module)
  in
  get_dep_map ~dir ~wrapper_name >>= fun dep_map ->
  match Dep_map.find dep_map vo_target with
  | None ->
    Code_error.raise "Dep_map.find failed for"
      [ ("coq_module", Coq_module.to_dyn coq_module)
      ; ("dep_map", Dep_map.to_dyn (Dyn.list Path.to_dyn) dep_map)
      ]
  | Some deps ->
    (* Inject prelude deps *)
    let deps =
      let prelude = "Init/Prelude.vo" in
      match boot_type with
      | `No_boot | `Bootstrap_prelude -> deps
      | `Bootstrap lib -> Path.relative (Coq_lib.obj_root lib) prelude :: deps
    in
    Action_builder.paths deps

let generic_coq_args ~sctx ~dir ~wrapper_name ~boot_type ~mode ~coq_prog
    ~stanza_flags ~ml_flags ~theories_deps ~theory_dirs ~coq_lang_version
    coq_module =
  let+ coq_stanza_flags =
    let+ expander = Super_context.expander sctx ~dir in
    let coq_flags =
      let coq_flags = coq_flags ~expander ~dir ~stanza_flags ~sctx in
      (* By default we have the -q flag. We don't want to pass this to coqtop to
         allow users to load their .coqrc files for interactive development.
         Therefore we manually scrub the -q setting when passing arguments to
         coqtop. *)
      match coq_prog with
      | `Coqtop ->
        let rec remove_q = function
          | "-q" :: l -> remove_q l
          | x :: l -> x :: remove_q l
          | [] -> []
        in
        let open Action_builder.O in
        coq_flags >>| remove_q
      | _ -> coq_flags
    in
    Command.Args.dyn coq_flags (* stanza flags *)
  in
  let coq_native_flags =
    let mode =
      (* Tweak the modes for coqtop since it has no "-vos" option *)
      match (mode, coq_prog) with
      | Coq_mode.VosOnly, `Coqtop -> Coq_mode.VoOnly
      | _ -> mode
    in
    coqc_native_flags ~sctx ~dir ~theories_deps ~theory_dirs ~mode
  in
  let file_flags =
    coqc_file_flags ~dir ~theories_deps ~wrapper_name ~boot_type ~ml_flags
      ~coq_lang_version
  in
  match coq_prog with
  | `Coqc ->
    [ coq_stanza_flags
    ; coq_native_flags
    ; S file_flags
    ; Dep (Coq_module.source coq_module)
    ]
  | `Coqtop -> [ coq_stanza_flags; coq_native_flags; S file_flags ]

let setup_coqc_rule ~loc ~dir ~sctx ~coqc_dir ~file_targets ~stanza_flags
    ~theories_deps ~mode ~wrapper_name ~use_stdlib ~ml_flags ~theory_dirs
    ~coq_lang_version coq_module =
  (* Process coqdep and generate rules *)
  let* boot_type =
    boot_type ~dir ~use_stdlib ~wrapper_name ~coq_lang_version coq_module
  in
  let* coqc = coqc ~loc ~dir ~sctx in
  let obj_files =
    Coq_module.obj_files ~wrapper_name ~mode ~obj_files_mode:Coq_module.Build
      ~obj_dir:dir coq_module
    |> List.map ~f:fst
  in
  let target_obj_files = Command.Args.Hidden_targets obj_files in
  let* args =
    generic_coq_args ~sctx ~dir ~wrapper_name ~boot_type ~stanza_flags ~ml_flags
      ~theories_deps ~theory_dirs ~mode ~coq_lang_version ~coq_prog:`Coqc
      coq_module
  in
  let deps_of = deps_of ~dir ~boot_type ~wrapper_name ~mode coq_module in
  let open Action_builder.With_targets.O in
  Super_context.add_rule ~loc ~dir sctx
    (Action_builder.with_no_targets deps_of
    >>> Action_builder.With_targets.add ~file_targets
        @@ Command.run ~dir:(Path.build coqc_dir) coqc (target_obj_files :: args)
    (* The way we handle the transitive dependencies of .vo files is not safe for
       sandboxing *)
    >>| Action.Full.add_sandbox Sandbox_config.no_sandboxing)

let coq_modules_of_theory ~sctx lib =
  Action_builder.of_memo
  @@
  let name = Coq_lib.name lib in
  match lib with
  | Coq_lib.Legacy lib -> Memo.return @@ Coq_lib.Legacy.vo lib
  | Coq_lib.Dune lib ->
    let dir = Coq_lib.Dune.src_root lib in
    let* dir_contents = Dir_contents.get sctx ~dir in
    let+ coq_sources = Dir_contents.coq dir_contents in
    Coq_sources.library coq_sources ~name |> List.rev_map ~f:Coq_module.source

let source_rule ~sctx theories =
  (* sources for depending libraries coqdep requires all the files to be in the
     tree to produce correct dependencies, including those of dependencies *)
  Action_builder.dyn_paths_unit
    (let open Action_builder.O in
    let+ l =
      Action_builder.List.map theories ~f:(coq_modules_of_theory ~sctx)
    in
    List.concat l)

let coqdoc_directory ~mode ~obj_dir ~name =
  Path.Build.relative obj_dir
    (Coq_lib_name.to_string name
    ^
    match mode with
    | `Html -> ".html"
    | `Latex -> ".tex")

let coqdoc_directory_targets ~dir:obj_dir (theory : Coq_stanza.Theory.t) =
  let+ (_ : Coq_lib.DB.t) =
    (* We force the creation of the coq_lib db here so that errors there can
       appear before any errors to do with directory targets from coqdoc. *)
    let+ scope = Scope.DB.find_by_dir obj_dir in
    Scope.coq_libs scope
  in
  let loc = theory.buildable.loc in
  let name = snd theory.name in
  Path.Build.Map.of_list_exn
    [ (coqdoc_directory ~mode:`Html ~obj_dir ~name, loc)
    ; (coqdoc_directory ~mode:`Latex ~obj_dir ~name, loc)
    ]

let setup_coqdoc_rules ~sctx ~dir ~theories_deps (s : Coq_stanza.Theory.t)
    coq_modules =
  let loc, name = (s.buildable.loc, snd s.name) in
  let rule =
    let file_flags =
      (* BUG: We need to pass --coqlib depending on the boot_type otherwise
         coqdoc will not work. *)
      [ theories_flags ~theories_deps
      ; A "-R"
      ; Path (Path.build dir)
      ; A (Coq_lib_name.wrapper (snd s.name))
      ]
    in
    fun mode ->
      let* () =
        let* coqdoc =
          Super_context.resolve_program sctx "coqdoc" ~dir ~loc:(Some loc)
            ~hint:"opam install coq"
        in
        (let doc_dir = coqdoc_directory ~mode ~obj_dir:dir ~name in
         let file_flags =
           let globs =
             let open Action_builder.O in
             let* theories_deps = Resolve.Memo.read theories_deps in
             Action_builder.of_memo
             @@
             let open Memo.O in
             let+ deps =
               Memo.parallel_map theories_deps ~f:(fun theory ->
                   let+ theory_dirs = directories_of_lib ~sctx theory in
                   Dep.Set.of_list_map theory_dirs ~f:(fun dir ->
                       (* TODO *)
                       Glob.of_string_exn Loc.none "*.glob"
                       |> File_selector.of_glob ~dir:(Path.build dir)
                       |> Dep.file_selector))
             in
             Command.Args.Hidden_deps (Dep.Set.union_all deps)
           in
           let mode_flag =
             match mode with
             | `Html -> "--html"
             | `Latex -> "--latex"
           in
           let extra_coqdoc_flags =
             (* Standard flags for coqdoc *)
             let standard = Action_builder.return [ "--toc" ] in
             let open Action_builder.O in
             let* expander =
               Action_builder.of_memo @@ Super_context.expander sctx ~dir
             in
             Expander.expand_and_eval_set expander s.coqdoc_flags ~standard
           in
           [ Command.Args.S file_flags
           ; Command.Args.dyn extra_coqdoc_flags
           ; A mode_flag
           ; A "-d"
           ; Path (Path.build doc_dir)
           ; Deps (List.map ~f:Coq_module.source coq_modules)
           ; Dyn globs
           ; Hidden_deps
               (Dep.Set.of_files @@ List.map ~f:Path.build
               @@ List.map ~f:(Coq_module.glob_file ~obj_dir:dir) coq_modules)
           ]
         in
         Command.run ~sandbox:Sandbox_config.needs_sandboxing
           ~dir:(Path.build dir) coqdoc file_flags
         |> Action_builder.With_targets.map
              ~f:
                (Action.Full.map ~f:(fun coqdoc ->
                     Action.Progn [ Action.mkdir doc_dir; coqdoc ]))
         |> Action_builder.With_targets.add_directories
              ~directory_targets:[ doc_dir ])
        |> Super_context.add_rule ~loc ~dir sctx
      in
      let alias =
        match mode with
        | `Html -> Alias.doc ~dir
        | `Latex -> Alias.make (Alias.Name.of_string "doc-latex") ~dir
      in
      coqdoc_directory ~mode ~obj_dir:dir ~name
      |> Path.build |> Action_builder.path
      |> Rules.Produce.Alias.add_deps alias ~loc
  in
  rule `Html >>> rule `Latex

(* Common context for a theory, deps and rules *)
let theory_context ~context ~scope ~coq_lang_version ~name buildable =
  let theory =
    let coq_lib_db = Scope.coq_libs scope in
    Coq_lib.DB.resolve coq_lib_db ~coq_lang_version name
  in
  let theories_deps =
    Resolve.Memo.bind theory ~f:(fun theory ->
        Resolve.Memo.lift @@ Coq_lib.theories_closure theory)
  in
  (* ML-level flags for depending libraries *)
  let ml_flags, mlpack_rule =
    let lib_db = Scope.libs scope in
    ml_flags_and_ml_pack_rule ~context ~theories_deps ~lib_db buildable
  in
  (theory, theories_deps, ml_flags, mlpack_rule)

(* Common context for extraction, almost the same than above *)
let extraction_context ~context ~scope ~coq_lang_version
    (buildable : Coq_stanza.Buildable.t) =
  let coq_lib_db = Scope.coq_libs scope in
  let theories_deps =
    Resolve.Memo.List.map buildable.theories
      ~f:(Coq_lib.DB.resolve coq_lib_db ~coq_lang_version)
  in
  (* Extraction requires a boot library so we do this unconditionally
     for now. We must do this because it can happne that
     s.buildable.theories is empty *)
  let boot = Coq_lib.DB.resolve_boot ~coq_lang_version coq_lib_db in
  let theories_deps =
    let open Resolve.Memo.O in
    let+ boot = boot
    and+ theories_deps = theories_deps in
    match boot with
    | None -> theories_deps
    | Some (_, boot) -> boot :: theories_deps
  in
  let ml_flags, mlpack_rule =
    let lib_db = Scope.libs scope in
    ml_flags_and_ml_pack_rule ~context ~theories_deps ~lib_db buildable
  in
  (theories_deps, ml_flags, mlpack_rule)

let setup_theory_rules ~sctx ~dir ~dir_contents (s : Coq_stanza.Theory.t) =
  let* scope = Scope.DB.find_by_dir dir in
  let coq_lang_version = s.buildable.coq_lang_version in
  let name = s.name in
  let theory, theories_deps, ml_flags, mlpack_rule =
    let context = Super_context.context sctx |> Context.name in
    theory_context ~context ~scope ~coq_lang_version ~name s.buildable
  in
  let wrapper_name = Coq_lib_name.wrapper (snd s.name) in
  let use_stdlib = s.buildable.use_stdlib in
  let name = snd s.name in
  let loc = s.buildable.loc in
  let stanza_flags = s.buildable.flags in
  let* coq_dir_contents = Dir_contents.coq dir_contents in
  let theory_dirs =
    Coq_sources.directories coq_dir_contents ~name |> Path.Build.Set.of_list
  in
  let coq_modules = Coq_sources.library coq_dir_contents ~name in
  let source_rule =
    let theories =
      let open Resolve.Memo.O in
      let+ theory = theory
      and+ theories = theories_deps in
      theory :: theories
    in
    let open Action_builder.O in
    let* theories = Resolve.Memo.read theories in
    source_rule ~sctx theories
  in
  let coqc_dir = (Super_context.context sctx).build_dir in
  let* mode = select_native_mode ~sctx ~dir s.buildable in
  (* First we setup the rule calling coqdep *)
  setup_coqdep_for_theory_rule ~sctx ~dir ~loc ~theories_deps ~wrapper_name
    ~use_stdlib ~source_rule ~ml_flags ~mlpack_rule ~coq_lang_version
    coq_modules
  >>> Memo.parallel_iter coq_modules
        ~f:
          (setup_coqc_rule ~loc ~dir ~sctx ~file_targets:[] ~stanza_flags
             ~coqc_dir ~theories_deps ~mode ~wrapper_name ~use_stdlib ~ml_flags
             ~coq_lang_version ~theory_dirs)
  (* And finally the coqdoc rules *)
  >>> setup_coqdoc_rules ~sctx ~dir ~theories_deps s coq_modules

let coqtop_args_theory ~sctx ~dir ~dir_contents (s : Coq_stanza.Theory.t)
    coq_module =
  let* scope = Scope.DB.find_by_dir dir in
  let coq_lang_version = s.buildable.coq_lang_version in
  let name = s.name in
  let _theory, theories_deps, ml_flags, _mlpack_rule =
    let context = Super_context.context sctx |> Context.name in
    theory_context ~context ~scope ~coq_lang_version ~name s.buildable
  in
  let wrapper_name = Coq_lib_name.wrapper (snd s.name) in
  let* mode = select_native_mode ~sctx ~dir s.buildable in
  let name = snd s.name in
  let use_stdlib = s.buildable.use_stdlib in
  let* boot_type =
    boot_type ~dir ~use_stdlib ~wrapper_name ~coq_lang_version coq_module
  in
  let* coq_dir_contents = Dir_contents.coq dir_contents in
  let theory_dirs =
    Coq_sources.directories coq_dir_contents ~name |> Path.Build.Set.of_list
  in
  generic_coq_args ~sctx ~dir ~wrapper_name ~boot_type ~mode ~coq_prog:`Coqtop
    ~stanza_flags:s.buildable.flags ~ml_flags ~theories_deps ~theory_dirs
    ~coq_lang_version coq_module

(******************************************************************************)
(* Install rules *)
(******************************************************************************)

(* This is here for compatibility with Coq < 8.11, which expects plugin files to
   be in the folder containing the `.vo` files *)
let coq_plugins_install_rules ~scope ~package ~dst_dir (s : Coq_stanza.Theory.t)
    =
  let lib_db = Scope.libs scope in
  let+ ml_libs =
    (* get_libraries from Coq's ML dependencies *)
    Resolve.Memo.read_memo
      (Resolve.Memo.List.map ~f:(Lib.DB.resolve lib_db) s.buildable.plugins)
  in
  let rules_for_lib lib =
    let info = Lib.info lib in
    (* Don't install libraries that don't belong to this package *)
    if
      let name = Package.name package in
      Option.equal Package.Name.equal (Lib_info.package info) (Some name)
    then
      let loc = Lib_info.loc info in
      let plugins = Lib_info.plugins info in
      Mode.Dict.get plugins Native
      |> List.map ~f:(fun plugin_file ->
             (* Safe because all coq libraries are local for now *)
             let plugin_file = Path.as_in_build_dir_exn plugin_file in
             let plugin_file_basename = Path.Build.basename plugin_file in
             let dst =
               Path.Local.(to_string (relative dst_dir plugin_file_basename))
             in
             let entry =
               (* TODO this [loc] should come from [s.buildable.libraries] *)
               Install.Entry.make Section.Lib_root ~dst ~kind:`File plugin_file
             in
             Install.Entry.Sourced.create ~loc entry)
    else []
  in
  List.concat_map ~f:rules_for_lib ml_libs

let install_rules ~sctx ~dir s =
  match s with
  | { Coq_stanza.Theory.package = None; _ } -> Memo.return []
  | { Coq_stanza.Theory.package = Some package; buildable; _ } ->
    let loc = s.buildable.loc in
    let* mode = select_native_mode ~sctx ~dir buildable in
    let* scope = Scope.DB.find_by_dir dir in
    (* We force the coq scope for this DB as to fail early in case of
       some library conflicts that would also generate conflicting
       install rules. This is needed as now install rules less lazy
       than the theory rules. *)
    let _ = Scope.coq_libs scope in
    let* dir_contents = Dir_contents.get sctx ~dir in
    let name = snd s.name in
    (* This must match the wrapper prefix for now to remain compatible *)
    let dst_suffix = Coq_lib_name.dir name in
    (* These are the rules for now, coq lang 2.0 will make this uniform *)
    let dst_dir =
      if s.boot then
        (* We drop the "Coq" prefix (!) *)
        Path.Local.of_string "coq/theories"
      else
        let coq_root = Path.Local.of_string "coq/user-contrib" in
        Path.Local.relative coq_root dst_suffix
    in
    (* Also, stdlib plugins are handled in a hardcoded way, so no compat install
       is needed *)
    let* coq_plugins_install_rules =
      if s.boot then Memo.return []
      else coq_plugins_install_rules ~scope ~package ~dst_dir s
    in
    let wrapper_name = Coq_lib_name.wrapper name in
    let to_path f = Path.reach ~from:(Path.build dir) (Path.build f) in
    let to_dst f = Path.Local.to_string @@ Path.Local.relative dst_dir f in
    let make_entry (orig_file : Path.Build.t) (dst_file : string) =
      let entry =
        Install.Entry.make Section.Lib_root ~dst:(to_dst dst_file) orig_file
          ~kind:`File
      in
      Install.Entry.Sourced.create ~loc entry
    in
    let+ coq_sources = Dir_contents.coq dir_contents in
    coq_sources |> Coq_sources.library ~name
    |> List.concat_map ~f:(fun (vfile : Coq_module.t) ->
           let obj_files =
             Coq_module.obj_files ~wrapper_name ~mode ~obj_dir:dir
               ~obj_files_mode:Coq_module.Install vfile
             |> List.map
                  ~f:(fun ((vo_file : Path.Build.t), (install_vo_file : string))
                     -> make_entry vo_file install_vo_file)
           in
           let vfile = Coq_module.source vfile |> Path.as_in_build_dir_exn in
           let vfile_dst = to_path vfile in
           make_entry vfile vfile_dst :: obj_files)
    |> List.rev_append coq_plugins_install_rules

let setup_coqpp_rules ~sctx ~dir ({ loc; modules } : Coq_stanza.Coqpp.t) =
  let* coqpp =
    Super_context.resolve_program sctx "coqpp" ~dir ~loc:(Some loc)
      ~hint:"opam install coq"
  and* mlg_files = Coq_sources.mlg_files ~sctx ~dir ~modules in
  let mlg_rule m =
    let source = Path.build m in
    let target = Path.Build.set_extension m ~ext:".ml" in
    let args = [ Command.Args.Dep source; Hidden_targets [ target ] ] in
    let build_dir = (Super_context.context sctx).build_dir in
    Command.run ~dir:(Path.build build_dir) coqpp args
  in
  List.rev_map ~f:mlg_rule mlg_files |> Super_context.add_rules ~loc ~dir sctx

let setup_extraction_rules ~sctx ~dir ~dir_contents
    (s : Coq_stanza.Extraction.t) =
  let wrapper_name = "DuneExtraction" in
  let* coq_module =
    let+ coq = Dir_contents.coq dir_contents in
    Coq_sources.extract coq s
  in
  let file_targets =
    Coq_stanza.Extraction.ml_target_fnames s
    |> List.map ~f:(Path.Build.relative dir)
  in
  let loc = s.buildable.loc in
  let use_stdlib = s.buildable.use_stdlib in
  let coq_lang_version = s.buildable.coq_lang_version in
  let* scope = Scope.DB.find_by_dir dir in
  let theories_deps, ml_flags, mlpack_rule =
    let context = Super_context.context sctx |> Context.name in
    extraction_context ~context ~scope ~coq_lang_version s.buildable
  in
  let source_rule =
    let open Action_builder.O in
    let* theories_deps = Resolve.Memo.read theories_deps in
    source_rule ~sctx theories_deps
    >>> Action_builder.path (Coq_module.source coq_module)
  in
  let* mode = select_native_mode ~sctx ~dir s.buildable in
  setup_coqdep_for_theory_rule ~sctx ~dir ~loc ~theories_deps ~wrapper_name
    ~use_stdlib ~source_rule ~ml_flags ~mlpack_rule ~coq_lang_version
    [ coq_module ]
  >>> setup_coqc_rule ~file_targets ~stanza_flags:s.buildable.flags ~sctx ~loc
        ~coqc_dir:dir coq_module ~dir ~theories_deps ~mode ~wrapper_name
        ~use_stdlib:s.buildable.use_stdlib ~ml_flags ~coq_lang_version
        ~theory_dirs:Path.Build.Set.empty

let coqtop_args_extraction ~sctx ~dir (s : Coq_stanza.Extraction.t) coq_module =
  let use_stdlib = s.buildable.use_stdlib in
  let coq_lang_version = s.buildable.coq_lang_version in
  let* scope = Scope.DB.find_by_dir dir in
  let theories_deps, ml_flags, _mlpack_rule =
    let context = Super_context.context sctx |> Context.name in
    extraction_context ~context ~scope ~coq_lang_version s.buildable
  in
  let wrapper_name = "DuneExtraction" in
  let* boot_type =
    boot_type ~dir ~use_stdlib ~wrapper_name ~coq_lang_version coq_module
  in
  let* mode = select_native_mode ~sctx ~dir s.buildable in
  generic_coq_args ~sctx ~dir ~wrapper_name ~boot_type ~mode ~coq_prog:`Coqtop
    ~stanza_flags:s.buildable.flags ~ml_flags ~theories_deps
    ~theory_dirs:Path.Build.Set.empty ~coq_lang_version coq_module

(* Version for export *)
let deps_of ~dir ~use_stdlib ~wrapper_name ~mode ~coq_lang_version coq_module =
  let open Action_builder.O in
  let* boot_type =
    Action_builder.of_memo
      (boot_type ~dir ~use_stdlib ~wrapper_name ~coq_lang_version coq_module)
  in
  deps_of ~dir ~boot_type ~wrapper_name ~mode coq_module
