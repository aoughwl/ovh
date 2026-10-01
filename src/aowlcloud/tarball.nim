## Minimal deterministic ustar writer. Windows' tar and Git Bash's tar
## disagree on modes and line endings; this one writes exactly the bytes and
## modes we choose, so a bundle's hash means the same thing everywhere.

import std/[os, strutils, algorithm]

type TarEntry* = tuple[path, data: string, mode: int]

proc octal(n: int64, width: int): string =
  result = toOct(n, width - 1) & "\0"

proc header(path: string, size: int64, mode: int): string =
  if path.len > 99: raise newException(ValueError, "tar path too long: " & path)
  var h = newString(512)   # zero-filled
  template put(off: int, s: string) =
    let v = s
    for i, c in v: h[off + i] = c
  put(0, path)
  put(100, octal(mode, 8))
  put(108, octal(0, 8))
  put(116, octal(0, 8))
  put(124, octal(size, 12))
  put(136, octal(0, 12))          # mtime 0: deterministic
  put(148, "        ")            # checksum placeholder
  put(156, "0")
  put(257, "ustar\x0000")
  var sum = 0
  for c in h: sum += ord(c)
  put(148, toOct(sum, 6) & "\0 ")
  h

proc tar*(entries: seq[TarEntry]): string =
  var es = entries
  es.sort(proc (a, b: TarEntry): int = cmp(a.path, b.path))
  for e in es:
    result.add header(e.path, e.data.len, e.mode)
    result.add e.data
    let pad = (512 - e.data.len mod 512) mod 512
    result.add repeat('\0', pad)
  result.add repeat('\0', 1024)

proc tarDir*(root: string): string =
  ## A project directory as a docker build context.
  var es: seq[TarEntry]
  for f in walkDirRec(root, relative = true):
    let rel = f.replace('\\', '/')
    if rel.startsWith(".git/"): continue
    es.add (rel, readFile(root / f), 0o644)
  tar(es)
