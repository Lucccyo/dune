Testing composition of theories across a dune workspace with a boot library. A
boot library must have the following:

- Under the module prefix "Coq"
- Have a file Init/Prelude.v

When composing with a (boot) library, every library must have -boot passed to
coqdep and coqc.

  $ dune build A
  Warning: Coq Language Versions lower than 0.8 have been deprecated in Dune
  3.8 and will be removed in an upcoming Dune version.
  Module
  Prelude
  := Struct Inductive BootType : Set :=  boot : BootType | type : BootType. End
  
  Hello
       : Set

We can even have a secondary private boot library in another scope and only the
private boot library will be loaded implicitly.

  $ cat > B/Coq/dune << EOF
  > (include_subdirs qualified)
  > (coq.theory
  >  (name Coq)
  >  (boot))
  > EOF

  $ dune build B
  Warning: Coq Language Versions lower than 0.8 have been deprecated in Dune
  3.8 and will be removed in an upcoming Dune version.
  private_boot
       : PrivateBootType

However if this boot library is public Dune will complain

  $ cat > B/Coq/dune << EOF
  > (include_subdirs qualified)
  > (coq.theory
  >  (name Coq)
  >  (package Foo)
  >  (boot))
  > EOF

  $ dune build B
  Warning: Coq Language Versions lower than 0.8 have been deprecated in Dune
  3.8 and will be removed in an upcoming Dune version.
  Error: Cannot have more than one boot theory in scope:
  - Coq at Coq/dune:1
  - Coq at B/Coq/dune:2
  -> required by _build/default/B/Foo.dune-package
  -> required by alias B/all
  -> required by alias B/default
  [1]
