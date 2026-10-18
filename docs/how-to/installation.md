# Installation

Install Rubik from RubyGems for normal use, or from a source checkout when you
want to work on the repository. Rubik requires Ruby 3.4 or later; the required
Ruby version is declared in [`rubik.gemspec`](../../rubik.gemspec).

## Install the gem

```sh
gem install rubik
rubik --help
```

The gem installs a `rubik` executable. Start an interactive session in the
workspace you want to use:

```sh
rubik
```

On Windows, the `tree_sitter_language_pack` dependency has no prebuilt package
in the repository's CI environment and is compiled from source. The CI workflow
uses the Rust GNU toolchain and sets `RUST_TARGET=x86_64-pc-windows-gnu` plus
`BINDGEN_EXTRA_CLANG_ARGS`; see the [Windows setup steps in CI](https://github.com/ozgurulukir/rubik/blob/main/.github/workflows/ci.yml).

## Run from a source checkout

Install Git and Ruby 3.4 or later, then fetch the repository and dependencies:

```sh
git clone https://github.com/ozgurulukir/rubik.git
cd rubik
bundle install
```

On Linux or macOS, launch the checked-out executable from the repository root:

```sh
./bin/rubik
```

On Windows, launch one of the checked-in wrappers or invoke Ruby directly:

```powershell
.\bin\rubik.ps1
```

```bat
bin\rubik.cmd
```

```sh
ruby bin/rubik
```

The source checkout and an installed gem can coexist. The POSIX launcher
resolves the library from its own checkout; on Windows, the first `bin` directory
on `PATH` determines which executable runs.

## CI-tested platforms

The package specification supports Ruby 3.4 and later. The CI test matrix covers
Ubuntu with Ruby 3.4 and 4.0, and macOS and Windows with Ruby 4.0. This is a
bounded matrix, not a claim that every Ruby and operating-system combination is
tested. The same workflow builds and installs the gem in an isolated directory
and checks `rubik --version` and `require "rubik"`.

---

Return to the [documentation index](../index.md) or the [README](../../README.md).
