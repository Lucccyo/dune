ppx artifacts installed for rewriters

  $ dune build --root ppx
  Entering directory 'ppx'
  File "ppx-old/jbuild", line 1, characters 0-0:
  Warning: jbuild files are deprecated, please convert this file to a dune file
  instead.
  Note: You can use "dune upgrade" to convert your project to dune.
  File "_build/default/.ppx/foo.ppx_rewriter_jbuild/ppx.exe", line 1, characters 0-0:
  Error: Failed to create on-demand ppx rewriter for foo.ppx_rewriter_jbuild;
  no ppx driver were found. It seems that foo.ppx_rewriter_jbuild is not
  compatible with Dune. Examples of ppx rewriters that are compatible with Dune
  are ones using ocaml-migrate-parsetree, ppxlib or ppx_driver.
  [1]

stubs and js files installed

  $ dune build --root stubs
  Entering directory 'stubs'
  lib: [
    "_build/install/default/lib/foo/META"
    "_build/install/default/lib/foo/cfoo.h"
    "_build/install/default/lib/foo/dune-package"
    "_build/install/default/lib/foo/foo$ext_lib"
    "_build/install/default/lib/foo/foo.cma"
    "_build/install/default/lib/foo/foo.cmi"
    "_build/install/default/lib/foo/foo.cmt"
    "_build/install/default/lib/foo/foo.cmx"
    "_build/install/default/lib/foo/foo.cmxa"
    "_build/install/default/lib/foo/foo.cmxs"
    "_build/install/default/lib/foo/foo.js"
    "_build/install/default/lib/foo/foo.ml"
    "_build/install/default/lib/foo/libfoo_stubs$ext_lib"
    "_build/install/default/lib/foo/opam"
  ]
  stublibs: [
    "_build/install/default/lib/stublibs/dllfoo_stubs$ext_dll"
  ]

install stanza is respected

  $ dune build --root install-stanza
  Entering directory 'install-stanza'
  lib: [
    "_build/install/default/lib/foo/META"
    "_build/install/default/lib/foo/dune-package"
    "_build/install/default/lib/foo/opam"
  ]
  share: [
    "_build/install/default/share/foo/foobar"
    "_build/install/default/share/foo/share1"
  ]

public exes are installed

  $ dune build --root exe
  Entering directory 'exe'
  lib: [
    "_build/install/default/lib/foo/META"
    "_build/install/default/lib/foo/dune-package"
    "_build/install/default/lib/foo/opam"
  ]
  bin: [
    "_build/install/default/bin/bar"
  ]

mld files are installed

  $ dune build --root mld
  Entering directory 'mld'
  lib: [
    "_build/install/default/lib/foo/META"
    "_build/install/default/lib/foo/dune-package"
    "_build/install/default/lib/foo/opam"
  ]
  doc: [
    "_build/install/default/doc/foo/odoc-pages/doc.mld" {"odoc-pages/doc.mld"}
  ]

unwrapped libraries have the correct artifacts

  $ dune build --root lib-unwrapped
  Entering directory 'lib-unwrapped'
  lib: [
    "_build/install/default/lib/foo/META"
    "_build/install/default/lib/foo/dune-package"
    "_build/install/default/lib/foo/foo$ext_lib"
    "_build/install/default/lib/foo/foo.cma"
    "_build/install/default/lib/foo/foo.cmi"
    "_build/install/default/lib/foo/foo.cmt"
    "_build/install/default/lib/foo/foo.cmti"
    "_build/install/default/lib/foo/foo.cmx"
    "_build/install/default/lib/foo/foo.cmxa"
    "_build/install/default/lib/foo/foo.cmxs"
    "_build/install/default/lib/foo/foo.ml"
    "_build/install/default/lib/foo/foo.mli"
    "_build/install/default/lib/foo/opam"
  ]

wrapped lib with lib interface module

  $ dune build --root lib-wrapped-alias
  Entering directory 'lib-wrapped-alias'
  lib: [
    "_build/install/default/lib/foo/META"
    "_build/install/default/lib/foo/bar.ml"
    "_build/install/default/lib/foo/bar.mli"
    "_build/install/default/lib/foo/dune-package"
    "_build/install/default/lib/foo/foo$ext_lib"
    "_build/install/default/lib/foo/foo.cma"
    "_build/install/default/lib/foo/foo.cmi"
    "_build/install/default/lib/foo/foo.cmt"
    "_build/install/default/lib/foo/foo.cmx"
    "_build/install/default/lib/foo/foo.cmxa"
    "_build/install/default/lib/foo/foo.cmxs"
    "_build/install/default/lib/foo/foo.ml"
    "_build/install/default/lib/foo/foo__.cmi"
    "_build/install/default/lib/foo/foo__.cmt"
    "_build/install/default/lib/foo/foo__.cmx"
    "_build/install/default/lib/foo/foo__.ml"
    "_build/install/default/lib/foo/foo__Bar.cmi"
    "_build/install/default/lib/foo/foo__Bar.cmt"
    "_build/install/default/lib/foo/foo__Bar.cmti"
    "_build/install/default/lib/foo/foo__Bar.cmx"
    "_build/install/default/lib/foo/opam"
  ]

wrapped lib without lib interface module

  $ dune build --root lib-wrapped-no-alias
  Entering directory 'lib-wrapped-no-alias'
  lib: [
    "_build/install/default/lib/foo/META"
    "_build/install/default/lib/foo/bar.ml"
    "_build/install/default/lib/foo/bar.mli"
    "_build/install/default/lib/foo/dune-package"
    "_build/install/default/lib/foo/foo$ext_lib"
    "_build/install/default/lib/foo/foo.cma"
    "_build/install/default/lib/foo/foo.cmi"
    "_build/install/default/lib/foo/foo.cmt"
    "_build/install/default/lib/foo/foo.cmx"
    "_build/install/default/lib/foo/foo.cmxa"
    "_build/install/default/lib/foo/foo.cmxs"
    "_build/install/default/lib/foo/foo.ml"
    "_build/install/default/lib/foo/foo__Bar.cmi"
    "_build/install/default/lib/foo/foo__Bar.cmt"
    "_build/install/default/lib/foo/foo__Bar.cmti"
    "_build/install/default/lib/foo/foo__Bar.cmx"
    "_build/install/default/lib/foo/opam"
  ]
