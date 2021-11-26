# fzy.zig

Rewrite of John Hawthorn's excellent [fzy][] in Zig.

This was mostly done as a learning exercise/out of curiosity. I don't recommend
using it unless you enjoy testing beta software.

[fzy]: https://github.com/jhawthorn/fzy

## Building

Obviously building fzy.zig requires a Zig toolchain. Currently Zig master is
required.

```console
$ git clone --recursive https://github.com/gpanders/fzy.zig
$ zig build
```

This will build an `fzy` binary in `zig-out/bin/`. To install to a different
prefix, use the `-p` flag:

```console
$ zig build -p /usr/local
```

By default, `fzy.zig` is built in `Debug` mode. This is very slow, but will
display useful error messages if the program misbehaves. If you intend to
actually use `fzy`, you should compile in `ReleaseSafe` mode:

```console
$ zig build -Drelease-safe=true
```

`ReleaseSafe` mode is still slower than the original `fzy`. You can compile in
`ReleastFast` mode to disable all runtime safety checks and enable more
optimizations:

```console
$ zig build -Drelease-fast=true
```

## Usage

Usage is the same as the original [fzy][].

## License

[MIT][]

[MIT]: ./LICENSE
