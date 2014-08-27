#!/usr/bin/env node

optimist = require('optimist')
    .usage('Build modules and dependencies for app in current dir.\nUsage: -b -p -c -f file -o out/')
    .boolean(['b','p','c', 'q'])
    .alias('b', 'build')
    .alias('p', 'packagejson')
    .alias('c', 'copy')
    .alias('f', 'fuse')
    .alias('q', 'quiet')
    .string("fuselib")
    .string('f')
    .string("o")
    .describe('b', 'build app, same as -p -c together')
    .describe('p', 'write module dependencies to package.json')
    .describe('c', 'copy depended external modules to local node_modules dir')
    .describe('f', 'generate a single executable js file, see doc.')
    .describe('fuselib', 'fuse to a library to export modules, see doc.')
    .describe("o", 'place fused files in this dir. Optional, default is ./')
    .describe("q", 'quite mode. No warnings')
;
argv =  optimist.argv;

bna = require("../lib/bna");
fs = require("fs");
path = require("path");

if (!(argv.b || argv.p || argv.c || argv.f || argv.fuselib))
    console.log(optimist.help());
    if (fs.existsSync(path.join(process.cwd(), "package.json")))
        bna.dir.npmDependencies(process.cwd(), (err, deps)->
            if (err) then console.log(err);
            else
                console.log("Module dependencies are:")
                console.log(deps);
            bna.dir.externDependModules(process.cwd(), (err, deps)->
                if (err) then console.log(err);
                else
                    console.log("Extern modules (node_modules located outside of current dir):")
                    console.log(deps.slice(1));
            )
        )

if argv.quiet then bna.quiet = true

if (argv.p)
    bna.writePackageJson(process.cwd(), (err, removedPackages)->
        if (err) then console.log(err.stack);
        else
          if removedPackages.length then console.log("Removd unused packages: " + removedPackages);
          console.log("package.json dependencies updated");
    )
else if (argv.c)
    bna.copyExternDependModules(process.cwd(), (msg)->
        console.log(msg);
    , (err)->
        if (err) then console.log(err.stack);
        else console.log("copying finished");
    )
else if (argv.b)
    bna.writePackageJson(process.cwd(), (err, removedPackages)->
        if (err) then console.log(err.stack);
        else
          if removedPackages.length then console.log("Removd unused packages: " + removedPackages);
          else
            console.log("package.json dependencies updated");
            bna.copyExternDependModules(process.cwd(), (msg)->
                console.log(msg);
            , (err)->
                if (err) then console.log(err.stack);
                else console.log("copying finished");
            )
    )
else if argv.f or argv.fuselib
  resolver    = require("resolve");
  ddir = "."
  if argv.f == true or argv.fuselib == true
    fpath = bna.mainFile(path.resolve("."))
    if not fpath
      console.log "Nothing to fuse, are you in a module folder?  See help below\n"
      console.log optimist.help()
      process.exit(1)
    console.log "Fusing detected file #{path.relative('.',fpath)}"
  else
    fpath = path.resolve(argv.f || argv.fuselib)

  if argv.o
    dstfile = null
    ddir = path.resolve(argv.o)
    if path.extname(ddir).toLowerCase() == ".js"
      dstfile = path.basename(ddir)
      ddir = path.dirname(ddir)

  if (argv.fuselib? and fs.statSync(fpath).isDirectory())
    bna.fuseDirTo(fpath, ddir, {verbose: true, aslib: true, dstfile: dstfile });
  else
    bna.fuseTo(fpath, ddir, {verbose: true, aslib: argv.fuselib?, dstfile: dstfile})

  console.log("""
  Finished
  """)
