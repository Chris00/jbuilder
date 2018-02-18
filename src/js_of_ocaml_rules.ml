open Import
open! No_io
open Build.O

module Atom = Sexp.Atom
module SC = Super_context

let separate_compilation_enabled () = !Clflags.dev_mode

let pretty    () = if !Clflags.dev_mode then ["--pretty"           ] else []
let sourcemap () = if !Clflags.dev_mode then ["--source-map-inline"] else []

let standard () = pretty () @ sourcemap ()

let install_jsoo_hint = "opam install js_of_ocaml-compiler"

let in_build_dir ~ctx =
  let init = Path.relative ctx.Context.build_dir ".js" in
  List.fold_left ~init ~f:Path.relative

let runtime_file ~sctx ~dir fname =
  match
    Artifacts.file_of_lib (SC.artifacts sctx) ~from:dir
      ~lib:(Atom.unsafe_of_string "js_of_ocaml-compiler") ~file:fname
  with
  | Error _ ->
    Arg_spec.Dyn (fun _ ->
      Utils.library_not_found ~context:(SC.context sctx).name ~hint:install_jsoo_hint
        "js_of_ocaml-compiler")
  | Ok f -> Arg_spec.Dep f

let js_of_ocaml_rule ~sctx ~dir ~flags ~spec ~target =
  let jsoo = SC.resolve_program sctx ~hint:install_jsoo_hint "js_of_ocaml" in
  let runtime = runtime_file ~sctx ~dir "runtime.js" in
  Build.run ~context:(SC.context sctx) ~dir
    jsoo
    [ Arg_spec.Dyn flags
    ; Arg_spec.A "-o"; Target target
    ; Arg_spec.A "--no-runtime"; runtime
    ; spec
    ]

let standalone_runtime_rule ~sctx ~dir ~javascript_files ~target =
  let spec =
    Arg_spec.S
      [ Arg_spec.Dyn (fun ((libs,_),_) -> Arg_spec.Deps (Lib.jsoo_runtime_files libs))
      ; Arg_spec.Deps javascript_files
      ]
  in
  Build.arr (fun (libs_and_cm,flags) -> (libs_and_cm, "--runtime-only" :: flags))
  >>>
  js_of_ocaml_rule ~sctx ~dir ~flags:(fun (_,flags) -> As flags) ~target ~spec

let exe_rule ~sctx ~dir ~javascript_files ~src ~target =
  let spec =
    Arg_spec.S
      [ Arg_spec.Dyn (fun ((libs,_),_) -> Arg_spec.Deps (Lib.jsoo_runtime_files libs))
      ; Arg_spec.Deps javascript_files
      ; Arg_spec.Dep src
      ]
  in
  js_of_ocaml_rule ~sctx ~dir ~flags:(fun (_,flags) -> As flags) ~spec ~target

let link_rule ~sctx ~dir ~runtime ~target =
  let ctx = SC.context sctx in
  let get_all ((libs,cm),_) =
    (* Special case for the stdlib because it is not referenced in the META *)
    let stdlib = Lib.external_ (Findlib.stdlib_with_archives ctx.findlib) in
    let all_libs =
      List.concat_map (stdlib :: libs) ~f:(fun (lib : Lib.t) ->
        let jsoo_archives = Lib.jsoo_archives lib in
        if Lib.is_local lib then (
          jsoo_archives
        ) else (
          let lib_name = Option.value_exn (Lib.public_name lib) in
          List.map ~f:(fun js ->
              in_build_dir ~ctx [Atom.to_string lib_name ; Path.basename js])
            jsoo_archives
        )
      )
    in
    let all_other_modules =
      List.map cm ~f:(fun m -> Path.extend_basename m ~suffix:".js")
    in
    Arg_spec.Deps (List.concat [all_libs;all_other_modules])
  in
  let jsoo_link = SC.resolve_program sctx ~hint:install_jsoo_hint "jsoo_link" in
  Build.run ~context:(SC.context sctx) ~dir
    jsoo_link
    [ Arg_spec.A "-o"; Target target
    ; Arg_spec.Dep runtime
    ; Arg_spec.As (sourcemap ())
    ; Arg_spec.Dyn get_all
    ]

let build_cm sctx ~scope ~dir ~js_of_ocaml ~src ~target =
  if separate_compilation_enabled ()
  then
    let itarget = Path.extend_basename src ~suffix:".js" in
    let spec = Arg_spec.Dep src in
    let flags =
      SC.expand_and_eval_set sctx ~scope ~dir js_of_ocaml.Jbuild.Js_of_ocaml.flags
        ~standard:(standard ())
    in
    [ flags
      >>>
      js_of_ocaml_rule ~sctx ~dir ~flags:(fun flags -> As flags) ~spec ~target:itarget ]
    @ (if target = itarget then [] else [Build.symlink ~src:itarget ~dst:target])
  else []

let setup_separate_compilation_rules sctx components =
  if separate_compilation_enabled ()
  then
    match components with
    | [] | _ :: _ :: _ -> ()
    | [pkg] ->
      let ctx = SC.context sctx in
      match Findlib.find ctx.findlib pkg ~required_by:[] with
      | Error _ -> ()
      | Ok pkg ->
        let pkg =
          (* Special case for the stdlib because it is not referenced in the META *)
          match Findlib.Package.name pkg with
          | A "stdlib" -> Findlib.stdlib_with_archives ctx.findlib
          | _ -> pkg
        in
        let archives = Findlib.Package.archives pkg Byte in
        List.iter archives ~f:(fun fn ->
          let name = Path.basename fn in
          let src = Path.relative (Findlib.Package.dir pkg) name in
          let target =
            in_build_dir ~ctx [ Atom.to_string(Findlib.Package.name pkg);
                                sprintf "%s.js" name]
          in
          let dir =
            in_build_dir ~ctx [ Atom.to_string(Findlib.Package.name pkg )] in
          let spec = Arg_spec.Dep src in
          SC.add_rule sctx
            (Build.return (standard ())
             >>>
             js_of_ocaml_rule ~sctx ~dir ~flags:(fun flags -> As flags) ~spec ~target)
        )

let build_exe sctx ~dir ~js_of_ocaml ~src =
  let {Jbuild.Js_of_ocaml.javascript_files; _} = js_of_ocaml in
  let javascript_files = List.map javascript_files ~f:(Path.relative dir) in
  let mk_target ext = Path.extend_basename src ~suffix:ext in
  let target = mk_target ".js" in
  let standalone_runtime = mk_target ".runtime.js" in
  if separate_compilation_enabled () then
    [ link_rule ~sctx ~dir ~runtime:standalone_runtime ~target
    ; standalone_runtime_rule ~sctx ~dir ~javascript_files
        ~target:standalone_runtime
    ]
  else
    [ exe_rule ~sctx ~dir ~javascript_files ~src ~target ]
