#!/usr/bin/env coffee

optimist = require('optimist')
    .usage('Build modules and dependencies for app in the current dir.\nUsage: -b -p -c -f file -o out/')
    .boolean(['b','p','c', 'q', 'w', 'l'])
    .alias('b', 'build')
    .alias('p', 'packagejson')
    .alias('c', 'copy')
    .alias('f', 'fuse')
    .alias('q', 'quiet')
    .alias('l', 'line')
    .string("fuselib")
    .string('f')
    .string("o")
    .describe('b', 'build app, same as -p -c together')
    .describe('p', 'write module dependencies to package.json')
    .describe('c', 'copy depended external modules to local node_modules dir')
    .describe('f', 'generate a single executable js file, see doc.')
    .describe('fuselib', 'fuse to a library to export modules, see doc.')
    .describe("o", 'specify output file or dir for fuse. Optional, default is ./')
    .describe("q", 'quite mode. No warnings')
    .describe('w', 'watch file: fuse on change')
    .describe('l', 'parse line info')
;
argv = optimist.argv
bna = require("../lib/bna");
fs = require("fs");
path = require("path");
_ = require("underscore")


if argv.quiet then bna.quiet = true

if (argv.line) then bna.locations = true

if (!(argv.b || argv.p || argv.c || argv.f || argv.fuselib))

  [targetPath] = argv._
  if not targetPath
    console.log(optimist.help());
    if (fs.existsSync(path.join(process.cwd(), "package.json")))
      targetPath = process.cwd()
  else
    targetPath = path.resolve(targetPath)
  if (targetPath and fs.existsSync(targetPath))
    if fs.lstatSync(targetPath).isDirectory()
      console.log("Analyzing directory...")
      bna.dir.npmDependencies(targetPath, (err, deps, externDeps)->
          if (err) then console.log(err);
          else
              console.log("Module dependencies are:")
              console.log(deps);
              if externDeps
                  console.log("Extern modules (node_modules located outside of current dir):")
                  console.log(externDeps);
      )
    else
      console.log("Analyzing file...")
      deps = ("#{k}@#{v}" for k,v of bna.fileDep(targetPath)[0])
      console.log("Dependencies are:")
      console.log deps.sort()

else if (argv.p)
    bna.writePackageJson(process.cwd(), (err, removedPackages)->
        if (err) then console.log(err.stack);
        else
          if removedPackages.length then console.log("Removed unused packages: " + removedPackages);
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
    fpath = path.resolve(".")
  else
    fpath = path.resolve(argv.f || argv.fuselib)

  if (fs.statSync(fpath).isDirectory())
    mfile = bna.mainFile(fpath)
    if argv.fuselib? and not mfile then # leave fpath, fuselib works on a non-module directory
    else fpath = mfile    # fuse the main file

  if not fpath
    console.log "Nothing to fuse, are you in a module folder?  See help below\n"
    console.log optimist.help()
    process.exit(1)

  console.log "Fusing file #{path.relative('.',fpath)}"

  if argv.o
    dstfile = null
    ddir = path.resolve(argv.o)
    if path.extname(ddir).toLowerCase() == ".js"
      dstfile = path.basename(ddir)
      ddir = path.dirname(ddir)

  isDir = fs.statSync(fpath).isDirectory()
  dofuse = (cb)=>
    if (isDir)
      bna.fuseDirTo(fpath, ddir, {aslib: argv.fuselib?, dstfile: dstfile }, cb);
    else
      process.nextTick ()=>
        units = bna.fuseTo(fpath, ddir, {aslib: argv.fuselib?, dstfile: dstfile})
        if (cb) then cb(units)


  if argv.w
    # in case of spurious events, call fuse with 1 second delay/throttle
    callFuseThrottleSec = if typeof argv.w == 'string' then parseInt(argv.w) else 2
    do()=>  # create stack
      onChange = do()=>
        doChange = _.throttle( () =>
          dofuse (units)=>watch(units)
        , callFuseThrottleSec * 1000, {leading: true})   # call fuse throttled
        return (e, fp)=>         # the change function
          console.log "#{path.relative('.', fp)} changed"
          doChange()

      watch = do()=>  # file watchers are installed dynamically
        watchers = {}
        return (units)=>
          newWatchers = {}
          for unit in units
            if unit.fpath of watchers
              newWatchers[unit.fpath] = watchers[unit.fpath]
              delete watchers[unit.fpath]
            else do(unit)=>
              console.log "Begin watching #{path.relative('.', unit.fpath)}"
              #newWatchers[unit.fpath] = (fs.watch unit.fpath, (e)=> onChange(e, unit.fpath))
              newWatchers[unit.fpath] = (fs.watchFile unit.fpath, (e)=> onChange(e, unit.fpath))
          for fp,watcher of watchers
            console.log "Stop watching  #{path.relative('.', fp)}"
            #watcher.close()
            fs.unwatchFile fp
          watchers = newWatchers

      # the initial fuse, then start watching!
      dofuse (units)=>
        watch(units, onChange)
  else
    dofuse()
